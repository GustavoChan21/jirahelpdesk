-- Jira Interno TROBBU v17.29.23
-- Self-healing catalogs, consolidated Helpdesk realtime and responsive-safe backend contract.
-- Safe to run after v17.29.21+; intentionally idempotent so skipped v17.29.22 schema can repair itself.

begin;

-- ============================================================
-- 1) Reusable Staff job-title catalog
-- ============================================================
create table if not exists public.staff_job_titles (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces(id) on delete cascade,
  name text not null,
  description text,
  icon text not null default 'lucide:briefcase-business',
  active boolean not null default true,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (char_length(btrim(name)) between 1 and 120),
  check (description is null or char_length(description) <= 600)
);

create unique index if not exists ux_staff_job_titles_workspace_name
  on public.staff_job_titles(workspace_id,lower(btrim(name)));
create index if not exists ix_staff_job_titles_workspace_active
  on public.staff_job_titles(workspace_id,active,name);
create index if not exists ix_staff_job_titles_created_by
  on public.staff_job_titles(created_by);


alter table public.workspace_members
  add column if not exists job_title_id uuid;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname='workspace_members_job_title_id_fkey'
      and conrelid='public.workspace_members'::regclass
  ) then
    alter table public.workspace_members
      add constraint workspace_members_job_title_id_fkey
      foreign key(job_title_id) references public.staff_job_titles(id) on delete set null;
  end if;
end $$;

create index if not exists ix_workspace_members_workspace_job_title
  on public.workspace_members(workspace_id,job_title_id);
create index if not exists ix_workspace_members_job_title_id
  on public.workspace_members(job_title_id);


alter table public.staff_job_titles enable row level security;

drop policy if exists staff_job_titles_select on public.staff_job_titles;
create policy staff_job_titles_select
on public.staff_job_titles for select to authenticated
using (private.is_workspace_member(workspace_id));

drop policy if exists staff_job_titles_insert on public.staff_job_titles;
create policy staff_job_titles_insert
on public.staff_job_titles for insert to authenticated
with check (private.has_workspace_permission(workspace_id,'manage_staff'));

drop policy if exists staff_job_titles_update on public.staff_job_titles;
create policy staff_job_titles_update
on public.staff_job_titles for update to authenticated
using (private.has_workspace_permission(workspace_id,'manage_staff'))
with check (private.has_workspace_permission(workspace_id,'manage_staff'));

drop policy if exists staff_job_titles_delete on public.staff_job_titles;
create policy staff_job_titles_delete
on public.staff_job_titles for delete to authenticated
using (private.has_workspace_permission(workspace_id,'manage_staff'));

grant select,insert,update,delete on public.staff_job_titles to authenticated;

drop trigger if exists trg_staff_job_titles_updated on public.staff_job_titles;
create trigger trg_staff_job_titles_updated
before update on public.staff_job_titles
for each row execute function public.set_updated_at();

create or replace function private.validate_workspace_member_job_title()
returns trigger
language plpgsql
security definer
set search_path=public,pg_temp
as $$
begin
  if new.job_title_id is not null and not exists (
    select 1
    from public.staff_job_titles jt
    where jt.id=new.job_title_id
      and jt.workspace_id=new.workspace_id
  ) then
    raise exception 'El puesto seleccionado no pertenece a este workspace.';
  end if;
  return new;
end
$$;
revoke all on function private.validate_workspace_member_job_title() from public,anon,authenticated;

drop trigger if exists trg_validate_workspace_member_job_title on public.workspace_members;
create trigger trg_validate_workspace_member_job_title
before insert or update of workspace_id,job_title_id on public.workspace_members
for each row execute function private.validate_workspace_member_job_title();

-- Preserve current free-text positions by converting them into reusable catalog rows.
insert into public.staff_job_titles(workspace_id,name,active)
select distinct wm.workspace_id,btrim(p.job_title),true
from public.workspace_members wm
join public.profiles p on p.id=wm.user_id
where nullif(btrim(coalesce(p.job_title,'')),'') is not null
on conflict do nothing;

update public.workspace_members wm
set job_title_id=jt.id
from public.profiles p
join public.staff_job_titles jt on lower(btrim(jt.name))=lower(btrim(p.job_title))
where p.id=wm.user_id
  and jt.workspace_id=wm.workspace_id
  and wm.job_title_id is null
  and nullif(btrim(coalesce(p.job_title,'')),'') is not null;

-- Helpdesk routing now prefers the workspace-specific reusable position.
create or replace function private.helpdesk_member_context(p_workspace uuid,p_user uuid)
returns text
language sql
stable
security definer
set search_path=public,pg_temp
as $$
  select concat_ws(' ',
    wm.helpdesk_routing_description,
    coalesce(jt.name,p.job_title),
    jt.description,
    wr.name,
    wr.description,
    wm.role::text
  )
  from public.workspace_members wm
  left join public.profiles p on p.id=wm.user_id
  left join public.staff_job_titles jt on jt.id=wm.job_title_id and jt.workspace_id=wm.workspace_id
  left join public.workspace_roles wr on wr.id=wm.role_id and wr.workspace_id=wm.workspace_id
  where wm.workspace_id=p_workspace and wm.user_id=p_user
$$;
revoke all on function private.helpdesk_member_context(uuid,uuid) from public,anon,authenticated;

-- Add the new catalog to Postgres Changes exactly once.
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname='supabase_realtime'
      and schemaname='public'
      and tablename='staff_job_titles'
  ) then
    alter publication supabase_realtime add table public.staff_job_titles;
  end if;
end $$;

-- ============================================================
-- 2) Internal Helpdesk classification catalog permissions
-- ============================================================
-- Support custom roles through effective permissions instead of hard-coding only
-- enum roles. Catalog administration is allowed to Helpdesk/Settings managers.
drop policy if exists helpdesk_internal_tags_select on public.helpdesk_internal_tags;
create policy helpdesk_internal_tags_select
on public.helpdesk_internal_tags for select to authenticated
using (
  private.is_workspace_member(workspace_id)
  and (
    private.has_workspace_permission(workspace_id,'manage_helpdesk')
    or private.has_workspace_permission(workspace_id,'manage_settings')
    or private.has_workspace_role(workspace_id,array['dev','pm','admin','superadmin']::public.app_role[])
  )
);

drop policy if exists helpdesk_internal_tags_insert on public.helpdesk_internal_tags;
create policy helpdesk_internal_tags_insert
on public.helpdesk_internal_tags for insert to authenticated
with check (
  private.has_workspace_permission(workspace_id,'manage_helpdesk')
  or private.has_workspace_permission(workspace_id,'manage_settings')
);

drop policy if exists helpdesk_internal_tags_update on public.helpdesk_internal_tags;
create policy helpdesk_internal_tags_update
on public.helpdesk_internal_tags for update to authenticated
using (
  private.has_workspace_permission(workspace_id,'manage_helpdesk')
  or private.has_workspace_permission(workspace_id,'manage_settings')
)
with check (
  private.has_workspace_permission(workspace_id,'manage_helpdesk')
  or private.has_workspace_permission(workspace_id,'manage_settings')
);

drop policy if exists helpdesk_internal_tags_delete on public.helpdesk_internal_tags;
create policy helpdesk_internal_tags_delete
on public.helpdesk_internal_tags for delete to authenticated
using (
  private.has_workspace_permission(workspace_id,'manage_helpdesk')
  or private.has_workspace_permission(workspace_id,'manage_settings')
);

-- The live v17.29.21 advisor exposed a duplicate unique index left by earlier
-- releases. Keep the canonical expression index and remove the duplicate only.
drop index if exists public.uq_helpdesk_internal_tags_workspace_name;

-- Target the Helpdesk foreign-key hot paths used by comments, activity, mentions
-- and catalog/ticket joins. These reduce lookup/lock overhead under concurrent users.
create index if not exists ix_helpdesk_comments_author_id
  on public.helpdesk_comments(author_id);
create index if not exists ix_helpdesk_activity_actor_id
  on public.helpdesk_activity(actor_id);
create index if not exists ix_helpdesk_mentions_comment_id
  on public.helpdesk_mentions(comment_id);
create index if not exists ix_helpdesk_mentions_mentioned_by
  on public.helpdesk_mentions(mentioned_by);
create index if not exists ix_helpdesk_mentions_workspace_id
  on public.helpdesk_mentions(workspace_id);
create index if not exists ix_helpdesk_request_types_created_by
  on public.helpdesk_request_types(created_by);
create index if not exists ix_helpdesk_tickets_department_workspace
  on public.helpdesk_tickets(department_id,workspace_id);
create index if not exists ix_helpdesk_tickets_request_type_workspace
  on public.helpdesk_tickets(request_type_id,workspace_id);


-- Recovery/delta reads use workspace + updated_at + id as a stable tie-breaker.
create index if not exists ix_helpdesk_tickets_workspace_updated_id
  on public.helpdesk_tickets(workspace_id,updated_at desc,id);

-- ============================================================
-- 3) Calm Helpdesk detail touch + atomic workflow mutation
-- ============================================================
-- A workflow transaction that inserts a comment already updates the parent ticket
-- itself. The transaction-local flag prevents the comment trigger from touching it
-- a second time and emitting a second ticket Broadcast for the same user action.
create or replace function private.touch_helpdesk_ticket_from_detail()
returns trigger
language plpgsql
security definer
set search_path=''
as $$
declare
  v_ticket uuid;
begin
  if coalesce(current_setting('app.helpdesk_skip_detail_touch',true),'')='1' then
    if tg_op='DELETE' then return old; end if;
    return new;
  end if;

  v_ticket:=case when tg_op='DELETE' then old.helpdesk_ticket_id else new.helpdesk_ticket_id end;
  update public.helpdesk_tickets
  set updated_at=clock_timestamp()
  where id=v_ticket;

  if tg_op='DELETE' then return old; end if;
  return new;
end
$$;
revoke all on function private.touch_helpdesk_ticket_from_detail() from public,anon,authenticated;

drop trigger if exists trg_95_helpdesk_comment_touch_ticket on public.helpdesk_comments;
create trigger trg_95_helpdesk_comment_touch_ticket
after insert or update or delete on public.helpdesk_comments
for each row execute function private.touch_helpdesk_ticket_from_detail();

drop trigger if exists trg_95_helpdesk_attachment_touch_ticket on public.helpdesk_attachments;
create trigger trg_95_helpdesk_attachment_touch_ticket
after insert or update or delete on public.helpdesk_attachments
for each row execute function private.touch_helpdesk_ticket_from_detail();

-- Comment + assignment + state are committed in a single DB transaction. Exactly
-- one parent-ticket UPDATE is produced by this RPC, so consumers see one visible
-- ticket mutation instead of status/assignment/comment touch races.
create or replace function public.mutate_helpdesk_workflow(
  p_ticket_id uuid,
  p_comment text default null,
  p_assignee uuid default null,
  p_status text default null
)
returns jsonb
language plpgsql
security definer
set search_path=public,private,pg_temp
as $$
declare
  v_caller uuid:=(select auth.uid());
  v_ticket public.helpdesk_tickets%rowtype;
  v_after public.helpdesk_tickets%rowtype;
  v_comment_row public.helpdesk_comments%rowtype;
  v_comment text:=nullif(btrim(coalesce(p_comment,'')),'');
  v_target_assignee uuid;
  v_target_status text;
  v_manager boolean:=false;
  v_assignee boolean:=false;
  v_requester boolean:=false;
  v_assignment_changed boolean:=false;
  v_status_changed boolean:=false;
  v_from_rank integer;
  v_to_rank integer;
begin
  if v_caller is null then raise exception 'Authentication required'; end if;
  if p_ticket_id is null then raise exception 'ticket_id is required'; end if;

  select * into v_ticket
  from public.helpdesk_tickets
  where id=p_ticket_id
  for update;

  if not found then raise exception 'Helpdesk ticket not found'; end if;
  if v_ticket.category in ('module','feature','new_requirement') then
    raise exception 'Requirement proposals are handled through the decision flow';
  end if;
  if not private.is_workspace_member(v_ticket.workspace_id) then
    raise exception 'Workspace access required';
  end if;

  v_manager:=private.has_workspace_permission(v_ticket.workspace_id,'manage_helpdesk');
  v_assignee:=v_ticket.assigned_to is not distinct from v_caller and v_ticket.assigned_to is not null;
  v_requester:=v_ticket.requester_user_id is not distinct from v_caller and v_ticket.requester_user_id is not null;
  if not (v_manager or v_assignee or v_requester) then
    raise exception 'You cannot update this Helpdesk request';
  end if;

  if v_comment is not null and char_length(v_comment)>4000 then
    raise exception 'El comentario no puede exceder 4000 caracteres.';
  end if;

  v_target_assignee:=coalesce(p_assignee,v_ticket.assigned_to);
  v_target_status:=coalesce(nullif(btrim(coalesce(p_status,'')),''),v_ticket.status);
  if v_target_status not in ('created','review','attended','closed') then
    raise exception 'Estado Helpdesk inválido.';
  end if;

  v_assignment_changed:=v_target_assignee is distinct from v_ticket.assigned_to;
  v_status_changed:=v_target_status is distinct from v_ticket.status;

  if v_assignment_changed then
    if not (v_manager or v_assignee) then
      raise exception 'No tienes permiso para reasignar esta solicitud.';
    end if;
    if v_target_assignee is null or not private.helpdesk_member_routable(v_ticket.workspace_id,v_target_assignee) then
      raise exception 'El responsable seleccionado no es un integrante activo disponible para Helpdesk.';
    end if;
  end if;

  v_from_rank:=case v_ticket.status when 'created' then 0 when 'review' then 1 when 'attended' then 2 when 'closed' then 3 else -1 end;
  v_to_rank:=case v_target_status when 'created' then 0 when 'review' then 1 when 'attended' then 2 when 'closed' then 3 else -1 end;

  if v_status_changed then
    if v_to_rank < v_from_rank then
      raise exception 'El estado no puede retroceder desde este flujo.';
    end if;
    if v_requester and not v_manager and not v_assignee then
      if not (v_ticket.status='attended' and v_target_status='closed') then
        raise exception 'El solicitante solo puede cerrar una solicitud atendida.';
      end if;
    elsif v_assignee and not v_manager then
      if v_to_rank <> v_from_rank+1 or v_target_status='closed' then
        raise exception 'El responsable debe avanzar secuencialmente: Nuevo → En revisión → Atendido.';
      end if;
    elsif not v_manager then
      raise exception 'No tienes permiso para cambiar el estado.';
    end if;
  end if;

  if v_comment is null and not v_assignment_changed and not v_status_changed then
    raise exception 'No hay cambios para guardar.';
  end if;

  -- All paths update the parent at most once. A comment-only action touches the
  -- ticket here; the comment trigger is suppressed only inside this transaction.
  perform set_config('app.helpdesk_skip_detail_touch','1',true);
  v_after:=v_ticket;

  if v_assignment_changed or v_status_changed then
    perform set_config('app.helpdesk_assignment_action','1',true);
    if v_assignment_changed then
      perform set_config(
        'app.helpdesk_assignment_source',
        case when v_assignee and not v_manager then 'redirect' else 'manual' end,
        true
      );
    end if;

    update public.helpdesk_tickets h
    set assigned_to=v_target_assignee,
        status=v_target_status,
        assignment_source=case
          when v_assignment_changed then case when v_assignee and not v_manager then 'redirect' else 'manual' end
          else h.assignment_source
        end,
        assignment_reason=case
          when v_assignment_changed then coalesce(v_comment,case when v_assignee and not v_manager then 'Redirigido por el responsable anterior.' else h.assignment_reason end)
          else h.assignment_reason
        end,
        assignment_confidence=case when v_assignment_changed then null else h.assignment_confidence end,
        assignment_queued_at=case when v_assignment_changed then null else h.assignment_queued_at end,
        assignment_last_routed_at=case when v_assignment_changed then clock_timestamp() else h.assignment_last_routed_at end,
        updated_at=clock_timestamp()
    where h.id=p_ticket_id
    returning h.* into v_after;
  elsif v_comment is not null then
    update public.helpdesk_tickets h
    set updated_at=clock_timestamp()
    where h.id=p_ticket_id
    returning h.* into v_after;
  end if;

  if v_comment is not null then
    insert into public.helpdesk_comments(helpdesk_ticket_id,author_id,body)
    values(p_ticket_id,v_caller,v_comment)
    returning * into v_comment_row;
  end if;

  return jsonb_build_object(
    'ticket',to_jsonb(v_after),
    'comment',case when v_comment is null then 'null'::jsonb else to_jsonb(v_comment_row) end,
    'assignment_changed',v_assignment_changed,
    'status_changed',v_status_changed
  );
end
$$;

revoke all on function public.mutate_helpdesk_workflow(uuid,text,uuid,text) from public,anon;
grant execute on function public.mutate_helpdesk_workflow(uuid,text,uuid,text) to authenticated;

analyze public.staff_job_titles;
analyze public.workspace_members;
analyze public.helpdesk_tickets;
analyze public.helpdesk_comments;
analyze public.helpdesk_activity;
analyze public.helpdesk_mentions;
analyze public.helpdesk_request_types;

-- PostgREST refresh is part of the migration contract so newly-created catalogs
-- and RPCs are immediately visible through supabase-js without a schema-cache wait.
notify pgrst,'reload schema';
commit;
