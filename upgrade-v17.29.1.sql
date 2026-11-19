-- Jira TROBBU v17.29.2 - Helpdesk Realtime Stabilization
-- Applied to Supabase project: Jira Interno Trobbu
-- Purpose: remove duplicate detail invalidations, touch list freshness for evidence,
-- and harden exposed Helpdesk table grants.

begin;

revoke all on table public.helpdesk_tickets, public.helpdesk_comments, public.helpdesk_activity, public.helpdesk_attachments from anon;

revoke all on table public.helpdesk_tickets from authenticated;
grant select, insert, update, delete on table public.helpdesk_tickets to authenticated;

revoke all on table public.helpdesk_comments from authenticated;
grant select, insert, update, delete on table public.helpdesk_comments to authenticated;

revoke all on table public.helpdesk_activity from authenticated;
grant select on table public.helpdesk_activity to authenticated;

revoke all on table public.helpdesk_attachments from authenticated;
grant select, insert, delete on table public.helpdesk_attachments to authenticated;

create or replace function private.broadcast_helpdesk_detail_change()
returns trigger
language plpgsql
security definer
set search_path=''
as $function$
declare
  v_row jsonb;
  v_ticket uuid;
  v_workspace uuid;
  v_operation text:=lower(tg_op);
  v_payload jsonb;
begin
  if tg_op='DELETE' then
    v_row:=to_jsonb(old);
    v_ticket:=old.helpdesk_ticket_id;
  else
    v_row:=to_jsonb(new);
    v_ticket:=new.helpdesk_ticket_id;
  end if;

  select h.workspace_id into v_workspace
  from public.helpdesk_tickets h
  where h.id=v_ticket;

  if v_workspace is null then
    if tg_op='DELETE' then return old; end if;
    return new;
  end if;

  v_payload:=jsonb_build_object(
    'workspace_id',v_workspace,
    'ticket_id',v_ticket,
    'entity',case tg_table_name
      when 'helpdesk_comments' then 'comment'
      when 'helpdesk_attachments' then 'attachment'
      else tg_table_name
    end,
    'operation',v_operation,
    'row',v_row,
    'changed_at',clock_timestamp()
  );

  perform realtime.send(
    v_payload,
    'helpdesk_changed',
    'helpdesk-ticket:' || v_ticket::text,
    true
  );

  if tg_op='DELETE' then return old; end if;
  return new;
end
$function$;

create or replace function private.broadcast_helpdesk_ticket_change()
returns trigger
language plpgsql
security definer
set search_path=''
as $function$
declare
  v_row jsonb;
  v_workspace uuid;
  v_ticket uuid;
  v_operation text:=lower(tg_op);
  v_payload jsonb;
  v_requester uuid;
  v_assignee uuid;
  v_old_assignee uuid;
  v_touch_only boolean:=false;
begin
  if tg_op='DELETE' then
    v_row:=to_jsonb(old);
    v_workspace:=old.workspace_id;
    v_ticket:=old.id;
    v_requester:=old.requester_user_id;
    v_assignee:=old.assigned_to;
    v_old_assignee:=old.assigned_to;
  else
    v_row:=to_jsonb(new);
    v_workspace:=new.workspace_id;
    v_ticket:=new.id;
    v_requester:=new.requester_user_id;
    v_assignee:=new.assigned_to;
    v_old_assignee:=case when tg_op='UPDATE' then old.assigned_to else null end;

    if tg_op='UPDATE' then
      v_touch_only := (to_jsonb(new)-'updated_at') = (to_jsonb(old)-'updated_at');
    end if;
  end if;

  v_payload:=jsonb_build_object(
    'workspace_id',v_workspace,
    'ticket_id',v_ticket,
    'entity','ticket',
    'operation',v_operation,
    'row',v_row,
    'touch_only',v_touch_only,
    'changed_at',clock_timestamp()
  );

  perform realtime.send(
    v_payload,'helpdesk_changed',
    'workspace:' || v_workspace::text || ':helpdesk',true
  );

  if not v_touch_only then
    perform realtime.send(
      v_payload,'helpdesk_changed',
      'helpdesk-ticket:' || v_ticket::text,true
    );
  end if;

  if v_requester is not null then
    perform realtime.send(
      v_payload,'helpdesk_changed',
      'user:' || v_requester::text || ':helpdesk',true
    );
  end if;

  if v_assignee is not null and v_assignee is distinct from v_requester then
    perform realtime.send(
      v_payload,'helpdesk_changed',
      'user:' || v_assignee::text || ':helpdesk',true
    );
  end if;

  if tg_op='UPDATE'
     and v_old_assignee is not null
     and v_old_assignee is distinct from v_assignee
     and v_old_assignee is distinct from v_requester then
    perform realtime.send(
      jsonb_build_object(
        'workspace_id',v_workspace,
        'ticket_id',v_ticket,
        'entity','ticket_scope',
        'operation','reconcile',
        'changed_at',clock_timestamp()
      ),
      'helpdesk_changed',
      'user:' || v_old_assignee::text || ':helpdesk',
      true
    );
  end if;

  if tg_op='DELETE' then return old; end if;
  return new;
end
$function$;

create or replace function private.touch_helpdesk_ticket_from_detail()
returns trigger
language plpgsql
security definer
set search_path=''
as $function$
declare
  v_ticket uuid;
begin
  v_ticket:=case when tg_op='DELETE' then old.helpdesk_ticket_id else new.helpdesk_ticket_id end;

  update public.helpdesk_tickets
  set updated_at=clock_timestamp()
  where id=v_ticket;

  if tg_op='DELETE' then return old; end if;
  return new;
end
$function$;

drop trigger if exists trg_90_helpdesk_activity_broadcast on public.helpdesk_activity;

drop trigger if exists trg_95_helpdesk_comment_touch_ticket on public.helpdesk_comments;
create trigger trg_95_helpdesk_comment_touch_ticket
after insert or update or delete on public.helpdesk_comments
for each row execute function private.touch_helpdesk_ticket_from_detail();

drop trigger if exists trg_95_helpdesk_attachment_touch_ticket on public.helpdesk_attachments;
create trigger trg_95_helpdesk_attachment_touch_ticket
after insert or update or delete on public.helpdesk_attachments
for each row execute function private.touch_helpdesk_ticket_from_detail();

drop function if exists private.touch_helpdesk_ticket_from_comment();

commit;
