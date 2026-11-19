-- Jira Interno TROBBU v17.27.0
-- Stable Helpdesk live UX: private Broadcast + non-destructive reconciliation + internal-only tags.

begin;

-- Fast reconciliation for Helpdesk list fallback.
create index if not exists ix_helpdesk_tickets_workspace_updated
  on public.helpdesk_tickets(workspace_id, updated_at desc);

-- Private Broadcast authorization.
drop policy if exists jira_helpdesk_workspace_broadcast_select on realtime.messages;
create policy jira_helpdesk_workspace_broadcast_select
on realtime.messages for select to authenticated
using (
  realtime.messages.extension='broadcast'
  and exists (
    select 1 from public.workspace_members wm
    where wm.user_id=(select auth.uid()) and wm.active=true
      and ('workspace:' || wm.workspace_id::text || ':helpdesk')=(select realtime.topic())
      and private.has_workspace_permission(wm.workspace_id,'manage_helpdesk')
  )
);

drop policy if exists jira_helpdesk_ticket_broadcast_select on realtime.messages;
create policy jira_helpdesk_ticket_broadcast_select
on realtime.messages for select to authenticated
using (
  realtime.messages.extension='broadcast'
  and exists (
    select 1 from public.helpdesk_tickets h
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

drop policy if exists jira_helpdesk_user_broadcast_select on realtime.messages;
create policy jira_helpdesk_user_broadcast_select
on realtime.messages for select to authenticated
using (
  realtime.messages.extension='broadcast'
  and (select realtime.topic())=('user:' || (select auth.uid())::text || ':helpdesk')
);

create or replace function private.broadcast_helpdesk_ticket_change()
returns trigger language plpgsql security definer set search_path='' as $$
declare
  v_row jsonb; v_workspace uuid; v_ticket uuid; v_operation text:=lower(tg_op);
  v_payload jsonb; v_requester uuid; v_assignee uuid; v_old_assignee uuid;
begin
  if tg_op='DELETE' then
    v_row:=to_jsonb(old); v_workspace:=old.workspace_id; v_ticket:=old.id;
    v_requester:=old.requester_user_id; v_assignee:=old.assigned_to; v_old_assignee:=old.assigned_to;
  else
    v_row:=to_jsonb(new); v_workspace:=new.workspace_id; v_ticket:=new.id;
    v_requester:=new.requester_user_id; v_assignee:=new.assigned_to;
    v_old_assignee:=case when tg_op='UPDATE' then old.assigned_to else null end;
  end if;

  v_payload:=jsonb_build_object('workspace_id',v_workspace,'ticket_id',v_ticket,'entity','ticket','operation',v_operation,'row',v_row,'changed_at',clock_timestamp());

  perform realtime.send(v_payload,'helpdesk_changed','workspace:' || v_workspace::text || ':helpdesk',true);
  perform realtime.send(v_payload,'helpdesk_changed','helpdesk-ticket:' || v_ticket::text,true);

  if v_requester is not null then
    perform realtime.send(v_payload,'helpdesk_changed','user:' || v_requester::text || ':helpdesk',true);
  end if;
  if v_assignee is not null and v_assignee is distinct from v_requester then
    perform realtime.send(v_payload,'helpdesk_changed','user:' || v_assignee::text || ':helpdesk',true);
  end if;
  if tg_op='UPDATE' and v_old_assignee is not null and v_old_assignee is distinct from v_assignee and v_old_assignee is distinct from v_requester then
    perform realtime.send(
      jsonb_build_object('workspace_id',v_workspace,'ticket_id',v_ticket,'entity','ticket_scope','operation','reconcile','changed_at',clock_timestamp()),
      'helpdesk_changed','user:' || v_old_assignee::text || ':helpdesk',true
    );
  end if;
  if tg_op='DELETE' then return old; end if; return new;
end $$;
revoke all on function private.broadcast_helpdesk_ticket_change() from public,anon,authenticated;

create or replace function private.broadcast_helpdesk_detail_change()
returns trigger language plpgsql security definer set search_path='' as $$
declare
  v_row jsonb; v_ticket uuid; v_workspace uuid; v_operation text:=lower(tg_op); v_payload jsonb;
begin
  if tg_op='DELETE' then v_row:=to_jsonb(old);v_ticket:=old.helpdesk_ticket_id;
  else v_row:=to_jsonb(new);v_ticket:=new.helpdesk_ticket_id; end if;
  select h.workspace_id into v_workspace from public.helpdesk_tickets h where h.id=v_ticket;
  if v_workspace is null then if tg_op='DELETE' then return old; end if; return new; end if;
  v_payload:=jsonb_build_object(
    'workspace_id',v_workspace,'ticket_id',v_ticket,
    'entity',case tg_table_name when 'helpdesk_comments' then 'comment' when 'helpdesk_activity' then 'activity' when 'helpdesk_attachments' then 'attachment' else tg_table_name end,
    'operation',v_operation,'row',v_row,'changed_at',clock_timestamp()
  );
  perform realtime.send(v_payload,'helpdesk_changed','helpdesk-ticket:' || v_ticket::text,true);
  if tg_op='DELETE' then return old; end if; return new;
end $$;
revoke all on function private.broadcast_helpdesk_detail_change() from public,anon,authenticated;

create or replace function private.broadcast_helpdesk_mention_change()
returns trigger language plpgsql security definer set search_path='' as $$
declare v_user uuid;v_workspace uuid;v_ticket uuid;v_row jsonb;v_operation text:=lower(tg_op);
begin
  if tg_op='DELETE' then v_user:=old.user_id;v_workspace:=old.workspace_id;v_ticket:=old.helpdesk_ticket_id;v_row:=to_jsonb(old);
  else v_user:=new.user_id;v_workspace:=new.workspace_id;v_ticket:=new.helpdesk_ticket_id;v_row:=to_jsonb(new); end if;
  if v_user is not null then
    perform realtime.send(
      jsonb_build_object('workspace_id',v_workspace,'ticket_id',v_ticket,'entity','mention','operation',v_operation,'row',v_row,'changed_at',clock_timestamp()),
      'helpdesk_changed','user:' || v_user::text || ':helpdesk',true
    );
  end if;
  if tg_op='DELETE' then return old; end if; return new;
end $$;
revoke all on function private.broadcast_helpdesk_mention_change() from public,anon,authenticated;

drop trigger if exists trg_90_helpdesk_ticket_broadcast on public.helpdesk_tickets;
create trigger trg_90_helpdesk_ticket_broadcast after insert or update or delete on public.helpdesk_tickets for each row execute function private.broadcast_helpdesk_ticket_change();
drop trigger if exists trg_90_helpdesk_comments_broadcast on public.helpdesk_comments;
create trigger trg_90_helpdesk_comments_broadcast after insert or update or delete on public.helpdesk_comments for each row execute function private.broadcast_helpdesk_detail_change();
drop trigger if exists trg_90_helpdesk_activity_broadcast on public.helpdesk_activity;
create trigger trg_90_helpdesk_activity_broadcast after insert or update or delete on public.helpdesk_activity for each row execute function private.broadcast_helpdesk_detail_change();
drop trigger if exists trg_90_helpdesk_attachments_broadcast on public.helpdesk_attachments;
create trigger trg_90_helpdesk_attachments_broadcast after insert or update or delete on public.helpdesk_attachments for each row execute function private.broadcast_helpdesk_detail_change();
drop trigger if exists trg_90_helpdesk_mentions_broadcast on public.helpdesk_mentions;
create trigger trg_90_helpdesk_mentions_broadcast after insert or update or delete on public.helpdesk_mentions for each row execute function private.broadcast_helpdesk_mention_change();

-- Internal-only Helpdesk tags. They are not exposed to Helpdesk requester roles by RLS.
create table if not exists public.helpdesk_internal_tags (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces(id) on delete cascade,
  name text not null,
  color text not null default '#D97706',
  active boolean not null default true,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index if not exists ux_helpdesk_internal_tags_workspace_name on public.helpdesk_internal_tags(workspace_id,lower(name));
create index if not exists ix_helpdesk_internal_tags_workspace_active on public.helpdesk_internal_tags(workspace_id,active,name);

create table if not exists public.helpdesk_ticket_internal_tags (
  workspace_id uuid not null references public.workspaces(id) on delete cascade,
  helpdesk_ticket_id uuid not null references public.helpdesk_tickets(id) on delete cascade,
  tag_id uuid not null references public.helpdesk_internal_tags(id) on delete cascade,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  primary key(workspace_id,helpdesk_ticket_id,tag_id)
);
create index if not exists ix_helpdesk_ticket_internal_tags_ticket on public.helpdesk_ticket_internal_tags(helpdesk_ticket_id,tag_id);
create index if not exists ix_helpdesk_ticket_internal_tags_tag on public.helpdesk_ticket_internal_tags(tag_id,helpdesk_ticket_id);

alter table public.helpdesk_internal_tags enable row level security;
alter table public.helpdesk_ticket_internal_tags enable row level security;

drop policy if exists helpdesk_internal_tags_select on public.helpdesk_internal_tags;
create policy helpdesk_internal_tags_select on public.helpdesk_internal_tags for select to authenticated using (private.has_workspace_role(workspace_id,array['dev','pm','admin','superadmin']::public.app_role[]));
drop policy if exists helpdesk_internal_tags_insert on public.helpdesk_internal_tags;
create policy helpdesk_internal_tags_insert on public.helpdesk_internal_tags for insert to authenticated with check (private.has_workspace_role(workspace_id,array['dev','pm','admin','superadmin']::public.app_role[]));
drop policy if exists helpdesk_internal_tags_update on public.helpdesk_internal_tags;
create policy helpdesk_internal_tags_update on public.helpdesk_internal_tags for update to authenticated using (private.has_workspace_role(workspace_id,array['dev','pm','admin','superadmin']::public.app_role[])) with check (private.has_workspace_role(workspace_id,array['dev','pm','admin','superadmin']::public.app_role[]));
drop policy if exists helpdesk_internal_tags_delete on public.helpdesk_internal_tags;
create policy helpdesk_internal_tags_delete on public.helpdesk_internal_tags for delete to authenticated using (private.has_workspace_role(workspace_id,array['pm','admin','superadmin']::public.app_role[]));

drop policy if exists helpdesk_ticket_internal_tags_select on public.helpdesk_ticket_internal_tags;
create policy helpdesk_ticket_internal_tags_select on public.helpdesk_ticket_internal_tags for select to authenticated using (
  private.has_workspace_role(workspace_id,array['dev','pm','admin','superadmin']::public.app_role[])
  and exists(select 1 from public.helpdesk_tickets h where h.id=helpdesk_ticket_id and h.workspace_id=workspace_id)
);
drop policy if exists helpdesk_ticket_internal_tags_insert on public.helpdesk_ticket_internal_tags;
create policy helpdesk_ticket_internal_tags_insert on public.helpdesk_ticket_internal_tags for insert to authenticated with check (
  private.has_workspace_role(workspace_id,array['dev','pm','admin','superadmin']::public.app_role[])
  and exists(select 1 from public.helpdesk_tickets h where h.id=helpdesk_ticket_id and h.workspace_id=workspace_id)
);
drop policy if exists helpdesk_ticket_internal_tags_delete on public.helpdesk_ticket_internal_tags;
create policy helpdesk_ticket_internal_tags_delete on public.helpdesk_ticket_internal_tags for delete to authenticated using (
  private.has_workspace_role(workspace_id,array['dev','pm','admin','superadmin']::public.app_role[])
  and exists(select 1 from public.helpdesk_tickets h where h.id=helpdesk_ticket_id and h.workspace_id=workspace_id)
);

grant select,insert,update,delete on public.helpdesk_internal_tags to authenticated;
grant select,insert,delete on public.helpdesk_ticket_internal_tags to authenticated;

create or replace function private.validate_helpdesk_internal_tag_link()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
declare v_ticket_workspace uuid;v_tag_workspace uuid;
begin
  select workspace_id into v_ticket_workspace from public.helpdesk_tickets where id=new.helpdesk_ticket_id;
  select workspace_id into v_tag_workspace from public.helpdesk_internal_tags where id=new.tag_id;
  if v_ticket_workspace is null or v_tag_workspace is null or new.workspace_id is distinct from v_ticket_workspace or new.workspace_id is distinct from v_tag_workspace then
    raise exception 'La tag interna y la solicitud deben pertenecer al mismo workspace.';
  end if;
  return new;
end $$;
revoke all on function private.validate_helpdesk_internal_tag_link() from public,anon,authenticated;
drop trigger if exists trg_validate_helpdesk_internal_tag_link on public.helpdesk_ticket_internal_tags;
create trigger trg_validate_helpdesk_internal_tag_link before insert or update on public.helpdesk_ticket_internal_tags for each row execute function private.validate_helpdesk_internal_tag_link();
drop trigger if exists trg_helpdesk_internal_tags_updated on public.helpdesk_internal_tags;
create trigger trg_helpdesk_internal_tags_updated before update on public.helpdesk_internal_tags for each row execute function public.set_updated_at();

create or replace function private.broadcast_helpdesk_internal_tag_change()
returns trigger language plpgsql security definer set search_path='' as $$
declare v_row jsonb;v_workspace uuid;v_ticket uuid;v_operation text:=lower(tg_op);rec record;v_payload jsonb;
begin
  if tg_op='DELETE' then v_row:=to_jsonb(old);v_workspace:=old.workspace_id;v_ticket:=old.helpdesk_ticket_id;
  else v_row:=to_jsonb(new);v_workspace:=new.workspace_id;v_ticket:=new.helpdesk_ticket_id;end if;
  v_payload:=jsonb_build_object('workspace_id',v_workspace,'ticket_id',v_ticket,'entity','internal_tag','operation',v_operation,'row',v_row,'changed_at',clock_timestamp());
  perform realtime.send(v_payload,'helpdesk_changed','workspace:' || v_workspace::text || ':helpdesk',true);
  for rec in select wm.user_id from public.workspace_members wm where wm.workspace_id=v_workspace and wm.active=true and wm.role in ('dev','pm','admin','superadmin') loop
    perform realtime.send(v_payload,'helpdesk_changed','user:' || rec.user_id::text || ':helpdesk',true);
  end loop;
  if tg_op='DELETE' then return old; end if;return new;
end $$;
revoke all on function private.broadcast_helpdesk_internal_tag_change() from public,anon,authenticated;
drop trigger if exists trg_90_helpdesk_internal_tag_links_broadcast on public.helpdesk_ticket_internal_tags;
create trigger trg_90_helpdesk_internal_tag_links_broadcast after insert or delete on public.helpdesk_ticket_internal_tags for each row execute function private.broadcast_helpdesk_internal_tag_change();

insert into public.helpdesk_internal_tags(workspace_id,name,color,active)
select w.id,'Área de oportunidad','#D97706',true from public.workspaces w
on conflict (workspace_id,lower(name)) do nothing;

-- Helpdesk uses Broadcast now; keep it out of Postgres Changes fan-out.
do $$
begin
  if exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='helpdesk_mentions') then alter publication supabase_realtime drop table public.helpdesk_mentions; end if;
  if exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='helpdesk_tickets') then alter publication supabase_realtime drop table public.helpdesk_tickets; end if;
  if exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='helpdesk_comments') then alter publication supabase_realtime drop table public.helpdesk_comments; end if;
  if exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='helpdesk_activity') then alter publication supabase_realtime drop table public.helpdesk_activity; end if;
  if exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='helpdesk_attachments') then alter publication supabase_realtime drop table public.helpdesk_attachments; end if;
end $$;

notify pgrst,'reload schema';
commit;
