-- Jira Interno TROBBU v17.26.0
-- Helpdesk scalable sync: private Broadcast channels, optimistic UI and resilient fallback.
begin;

drop policy if exists jira_helpdesk_workspace_broadcast_select on realtime.messages;
create policy jira_helpdesk_workspace_broadcast_select
on realtime.messages
for select
to authenticated
using (
  realtime.messages.extension='broadcast'
  and exists (
    select 1
    from public.workspace_members wm
    where wm.user_id=(select auth.uid())
      and wm.active=true
      and ('workspace:' || wm.workspace_id::text || ':helpdesk')=(select realtime.topic())
      and private.has_workspace_permission(wm.workspace_id,'manage_helpdesk')
  )
);

drop policy if exists jira_helpdesk_ticket_broadcast_select on realtime.messages;
create policy jira_helpdesk_ticket_broadcast_select
on realtime.messages
for select
to authenticated
using (
  realtime.messages.extension='broadcast'
  and exists (
    select 1
    from public.helpdesk_tickets h
    where ('helpdesk-ticket:' || h.id::text)=(select realtime.topic())
      and private.is_workspace_member(h.workspace_id)
      and (
        private.has_workspace_permission(h.workspace_id,'manage_helpdesk')
        or h.requester_user_id=(select auth.uid())
        or h.assigned_to=(select auth.uid())
        or private.is_helpdesk_mentioned(h.id)
      )
  )
);

create or replace function private.broadcast_helpdesk_ticket_change()
returns trigger
language plpgsql
security definer
set search_path=''
as $$
declare
  v_row jsonb;
  v_workspace uuid;
  v_ticket uuid;
  v_operation text:=lower(tg_op);
  v_payload jsonb;
begin
  if tg_op='DELETE' then
    v_row:=to_jsonb(old); v_workspace:=old.workspace_id; v_ticket:=old.id;
  else
    v_row:=to_jsonb(new); v_workspace:=new.workspace_id; v_ticket:=new.id;
  end if;
  v_payload:=jsonb_build_object('workspace_id',v_workspace,'ticket_id',v_ticket,'entity','ticket','operation',v_operation,'row',v_row,'changed_at',clock_timestamp());
  perform realtime.send(payload=>v_payload,event=>'helpdesk_changed',topic=>'workspace:' || v_workspace::text || ':helpdesk',private=>true);
  perform realtime.send(payload=>v_payload,event=>'helpdesk_changed',topic=>'helpdesk-ticket:' || v_ticket::text,private=>true);
  if tg_op='DELETE' then return old; end if;
  return new;
end $$;
revoke all on function private.broadcast_helpdesk_ticket_change() from public,anon,authenticated;

create or replace function private.broadcast_helpdesk_detail_change()
returns trigger
language plpgsql
security definer
set search_path=''
as $$
declare
  v_row jsonb;
  v_ticket uuid;
  v_workspace uuid;
  v_operation text:=lower(tg_op);
  v_payload jsonb;
begin
  if tg_op='DELETE' then v_row:=to_jsonb(old); v_ticket:=old.helpdesk_ticket_id;
  else v_row:=to_jsonb(new); v_ticket:=new.helpdesk_ticket_id;
  end if;
  select h.workspace_id into v_workspace from public.helpdesk_tickets h where h.id=v_ticket;
  if v_workspace is null then
    if tg_op='DELETE' then return old; end if;
    return new;
  end if;
  v_payload:=jsonb_build_object(
    'workspace_id',v_workspace,'ticket_id',v_ticket,
    'entity',case tg_table_name when 'helpdesk_comments' then 'comment' when 'helpdesk_activity' then 'activity' when 'helpdesk_attachments' then 'attachment' else tg_table_name end,
    'operation',v_operation,'row',v_row,'changed_at',clock_timestamp()
  );
  perform realtime.send(payload=>v_payload,event=>'helpdesk_changed',topic=>'helpdesk-ticket:' || v_ticket::text,private=>true);
  if tg_op='DELETE' then return old; end if;
  return new;
end $$;
revoke all on function private.broadcast_helpdesk_detail_change() from public,anon,authenticated;

drop trigger if exists trg_90_helpdesk_ticket_broadcast on public.helpdesk_tickets;
create trigger trg_90_helpdesk_ticket_broadcast after insert or update or delete on public.helpdesk_tickets for each row execute function private.broadcast_helpdesk_ticket_change();
drop trigger if exists trg_90_helpdesk_comments_broadcast on public.helpdesk_comments;
create trigger trg_90_helpdesk_comments_broadcast after insert or update or delete on public.helpdesk_comments for each row execute function private.broadcast_helpdesk_detail_change();
drop trigger if exists trg_90_helpdesk_activity_broadcast on public.helpdesk_activity;
create trigger trg_90_helpdesk_activity_broadcast after insert or update or delete on public.helpdesk_activity for each row execute function private.broadcast_helpdesk_detail_change();
drop trigger if exists trg_90_helpdesk_attachments_broadcast on public.helpdesk_attachments;
create trigger trg_90_helpdesk_attachments_broadcast after insert or update or delete on public.helpdesk_attachments for each row execute function private.broadcast_helpdesk_detail_change();

notify pgrst,'reload schema';
commit;

-- v17.26.0 · Helpdesk user-scoped Broadcast for requester/assignee/mentioned UX
drop policy if exists jira_helpdesk_user_broadcast_select on realtime.messages;
create policy jira_helpdesk_user_broadcast_select
on realtime.messages
for select
to authenticated
using (
  realtime.messages.extension='broadcast'
  and (select realtime.topic()) = ('user:' || (select auth.uid())::text || ':helpdesk')
);

create or replace function private.broadcast_helpdesk_ticket_change()
returns trigger
language plpgsql
security definer
set search_path=''
as $$
declare
  v_new jsonb;
  v_old jsonb;
  v_workspace uuid;
  v_ticket uuid;
  v_operation text:=lower(tg_op);
  v_payload jsonb;
  v_requester uuid;
  v_assignee uuid;
  v_old_assignee uuid;
begin
  if tg_op='DELETE' then
    v_old:=to_jsonb(old);
    v_new:=v_old;
    v_workspace:=old.workspace_id;
    v_ticket:=old.id;
    v_requester:=old.requester_user_id;
    v_assignee:=old.assigned_to;
    v_old_assignee:=old.assigned_to;
  else
    v_new:=to_jsonb(new);
    v_old:=case when tg_op='UPDATE' then to_jsonb(old) else null end;
    v_workspace:=new.workspace_id;
    v_ticket:=new.id;
    v_requester:=new.requester_user_id;
    v_assignee:=new.assigned_to;
    v_old_assignee:=case when tg_op='UPDATE' then old.assigned_to else null end;
  end if;

  v_payload:=jsonb_build_object(
    'workspace_id',v_workspace,
    'ticket_id',v_ticket,
    'entity','ticket',
    'operation',v_operation,
    'row',v_new,
    'changed_at',clock_timestamp()
  );

  perform realtime.send(payload=>v_payload,event=>'helpdesk_changed',topic=>'workspace:' || v_workspace::text || ':helpdesk',private=>true);
  perform realtime.send(payload=>v_payload,event=>'helpdesk_changed',topic=>'helpdesk-ticket:' || v_ticket::text,private=>true);

  if v_requester is not null then
    perform realtime.send(payload=>v_payload,event=>'helpdesk_changed',topic=>'user:' || v_requester::text || ':helpdesk',private=>true);
  end if;

  if v_assignee is not null and v_assignee is distinct from v_requester then
    perform realtime.send(payload=>v_payload,event=>'helpdesk_changed',topic=>'user:' || v_assignee::text || ':helpdesk',private=>true);
  end if;

  if tg_op='UPDATE' and v_old_assignee is not null and v_old_assignee is distinct from v_assignee and v_old_assignee is distinct from v_requester then
    perform realtime.send(
      payload=>jsonb_build_object('workspace_id',v_workspace,'ticket_id',v_ticket,'entity','ticket_scope','operation','reconcile','changed_at',clock_timestamp()),
      event=>'helpdesk_changed',topic=>'user:' || v_old_assignee::text || ':helpdesk',private=>true
    );
  end if;

  if tg_op='DELETE' then return old; end if;
  return new;
end $$;
revoke all on function private.broadcast_helpdesk_ticket_change() from public,anon,authenticated;

create or replace function private.broadcast_helpdesk_mention_change()
returns trigger
language plpgsql
security definer
set search_path=''
as $$
declare
  v_user uuid;
  v_workspace uuid;
  v_ticket uuid;
begin
  if tg_op='DELETE' then
    v_user:=old.user_id; v_workspace:=old.workspace_id; v_ticket:=old.helpdesk_ticket_id;
  else
    v_user:=new.user_id; v_workspace:=new.workspace_id; v_ticket:=new.helpdesk_ticket_id;
  end if;

  if v_user is not null then
    perform realtime.send(
      payload=>jsonb_build_object('workspace_id',v_workspace,'ticket_id',v_ticket,'entity','mention','operation','reconcile','changed_at',clock_timestamp()),
      event=>'helpdesk_changed',topic=>'user:' || v_user::text || ':helpdesk',private=>true
    );
  end if;

  if tg_op='DELETE' then return old; end if;
  return new;
end $$;
revoke all on function private.broadcast_helpdesk_mention_change() from public,anon,authenticated;

drop trigger if exists trg_90_helpdesk_mentions_broadcast on public.helpdesk_mentions;
create trigger trg_90_helpdesk_mentions_broadcast
after insert or update or delete on public.helpdesk_mentions
for each row execute function private.broadcast_helpdesk_mention_change();

-- Helpdesk reconciliation/index tuning for high concurrency
create index if not exists ix_helpdesk_tickets_workspace_updated
  on public.helpdesk_tickets(workspace_id, updated_at desc);
drop index if exists public.ix_helpdesk_attachments_ticket_created;
