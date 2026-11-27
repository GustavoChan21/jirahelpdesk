-- Jira Interno TROBBU v17.30.0
-- Image Compressor: private optimized-image collection, role-controlled access and Storage RLS.
begin;

create or replace function private.role_default_permission(p_role public.app_role,p_permission text)
returns boolean
language sql
immutable
security invoker
set search_path=public,pg_temp
as $$
  select case
    when p_role='superadmin' then true
    when p_role='admin' then p_permission in (
      'view_dashboard','view_tickets','create_tickets','edit_tickets','delete_tickets',
      'manage_sprints','qa_review','manage_helpdesk','manage_staff','manage_products','manage_settings',
      'use_image_compressor'
    )
    when p_role='pm' then p_permission in (
      'view_dashboard','view_tickets','create_tickets','edit_tickets','delete_tickets',
      'manage_sprints','qa_review','manage_helpdesk'
    )
    when p_role='dev' then p_permission in (
      'view_dashboard','view_tickets','create_tickets','edit_tickets'
    )
    when p_role='qa' then p_permission in (
      'view_dashboard','view_tickets','create_tickets','edit_tickets','qa_review'
    )
    when p_role='consulta' then p_permission in ('view_dashboard','view_tickets')
    else false
  end;
$$;

create table if not exists public.image_compression_assets (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces(id) on delete cascade,
  batch_id uuid not null,
  created_by uuid not null references public.profiles(id) on delete restrict,
  original_name text not null,
  original_size_bytes bigint not null check (original_size_bytes >= 0),
  original_width integer check (original_width is null or original_width > 0),
  original_height integer check (original_height is null or original_height > 0),
  output_name text not null,
  output_size_bytes bigint not null check (output_size_bytes >= 0),
  output_width integer check (output_width is null or output_width > 0),
  output_height integer check (output_height is null or output_height > 0),
  output_mime_type text not null default 'image/webp',
  storage_path text not null unique,
  compression_mode text not null default 'compress' check (compression_mode in ('compress','resize')),
  resize_max_side integer check (resize_max_side is null or resize_max_side between 320 and 8192),
  quality numeric(5,4) check (quality is null or (quality > 0 and quality <= 1)),
  target_min_bytes integer not null default 307200 check (target_min_bytes >= 0),
  target_max_bytes integer not null default 512000 check (target_max_bytes >= target_min_bytes),
  target_hit boolean not null default false,
  savings_percent numeric(7,2),
  created_at timestamptz not null default now()
);

create index if not exists ix_image_compression_assets_workspace_created
  on public.image_compression_assets(workspace_id,created_at desc);
create index if not exists ix_image_compression_assets_workspace_creator
  on public.image_compression_assets(workspace_id,created_by,created_at desc);
create index if not exists ix_image_compression_assets_batch
  on public.image_compression_assets(workspace_id,batch_id);
create index if not exists ix_image_compression_assets_created_by
  on public.image_compression_assets(created_by);

alter table public.image_compression_assets enable row level security;
grant select,insert,delete on public.image_compression_assets to authenticated;
revoke update on public.image_compression_assets from authenticated;

drop policy if exists image_compression_assets_select on public.image_compression_assets;
create policy image_compression_assets_select on public.image_compression_assets
for select to authenticated
using (private.has_workspace_permission(workspace_id,'use_image_compressor'));

drop policy if exists image_compression_assets_insert on public.image_compression_assets;
create policy image_compression_assets_insert on public.image_compression_assets
for insert to authenticated
with check (
  created_by=(select auth.uid())
  and private.has_workspace_permission(workspace_id,'use_image_compressor')
);

drop policy if exists image_compression_assets_delete on public.image_compression_assets;
create policy image_compression_assets_delete on public.image_compression_assets
for delete to authenticated
using (
  private.has_workspace_permission(workspace_id,'use_image_compressor')
  and (
    created_by=(select auth.uid())
    or private.has_workspace_permission(workspace_id,'manage_staff')
    or private.has_workspace_permission(workspace_id,'manage_settings')
  )
);

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values(
  'jira-image-compressions',
  'jira-image-compressions',
  false,
  15728640,
  array['image/webp','image/jpeg','image/png']
)
on conflict(id) do update set
  public=false,
  file_size_limit=excluded.file_size_limit,
  allowed_mime_types=excluded.allowed_mime_types;

drop policy if exists jira_image_compressions_select on storage.objects;
create policy jira_image_compressions_select on storage.objects
for select to authenticated
using (
  bucket_id='jira-image-compressions'
  and exists (
    select 1
    from public.workspace_members wm
    where wm.workspace_id::text=(storage.foldername(name))[1]
      and wm.user_id=(select auth.uid())
      and wm.active=true
      and private.member_has_permission(wm.workspace_id,wm.user_id,'use_image_compressor')
  )
);

drop policy if exists jira_image_compressions_insert on storage.objects;
create policy jira_image_compressions_insert on storage.objects
for insert to authenticated
with check (
  bucket_id='jira-image-compressions'
  and (storage.foldername(name))[2]=(select auth.uid())::text
  and exists (
    select 1
    from public.workspace_members wm
    where wm.workspace_id::text=(storage.foldername(name))[1]
      and wm.user_id=(select auth.uid())
      and wm.active=true
      and private.member_has_permission(wm.workspace_id,wm.user_id,'use_image_compressor')
  )
);

drop policy if exists jira_image_compressions_delete on storage.objects;
create policy jira_image_compressions_delete on storage.objects
for delete to authenticated
using (
  bucket_id='jira-image-compressions'
  and exists (
    select 1
    from public.workspace_members wm
    where wm.workspace_id::text=(storage.foldername(name))[1]
      and wm.user_id=(select auth.uid())
      and wm.active=true
      and private.member_has_permission(wm.workspace_id,wm.user_id,'use_image_compressor')
      and (
        (storage.foldername(name))[2]=(select auth.uid())::text
        or private.member_has_permission(wm.workspace_id,wm.user_id,'manage_staff')
        or private.member_has_permission(wm.workspace_id,wm.user_id,'manage_settings')
      )
  )
);

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname='supabase_realtime' and schemaname='public' and tablename='image_compression_assets'
  ) then
    alter publication supabase_realtime add table public.image_compression_assets;
  end if;
end $$;

alter table public.image_compression_assets replica identity full;
analyze public.image_compression_assets;
notify pgrst,'reload schema';
commit;


begin;
-- Jira TROBBU 17.30.7: threaded comments, same entity, no reparenting.
create or replace function private.guard_comment_thread() returns trigger language plpgsql security invoker set search_path='' as $$
declare scope_id uuid; found_parent boolean;
begin
  scope_id := (to_jsonb(new)->>tg_argv[0])::uuid;
  if tg_op='UPDATE' then
    if new.id is distinct from old.id or new.parent_comment_id is distinct from old.parent_comment_id or scope_id is distinct from (to_jsonb(old)->>tg_argv[0])::uuid then
      raise exception 'No se puede mover un comentario a otro hilo.' using errcode='23514';
    end if;
    return new;
  end if;
  if new.parent_comment_id is null then return new; end if;
  if new.parent_comment_id=new.id then raise exception 'Un comentario no puede responderse a sí mismo.' using errcode='23514'; end if;
  execute format('select exists(select 1 from %I.%I where id=$1 and %I=$2)',tg_table_schema,tg_table_name,tg_argv[0]) into found_parent using new.parent_comment_id,scope_id;
  if not found_parent then raise exception 'El comentario original no está disponible en este ticket.' using errcode='23503'; end if;
  return new;
end $$;
revoke all on function private.guard_comment_thread() from public,anon;
alter table public.ticket_comments add column if not exists parent_comment_id uuid;
create unique index if not exists ticket_comments_thread_scope_uidx on public.ticket_comments(id,ticket_id);
create index if not exists ticket_comments_thread_parent_idx on public.ticket_comments(parent_comment_id,ticket_id) where parent_comment_id is not null;
do $$ begin if not exists(select 1 from pg_constraint where conrelid='public.ticket_comments'::regclass and conname='ticket_comments_thread_parent_fk') then alter table public.ticket_comments add constraint ticket_comments_thread_parent_fk foreign key(parent_comment_id,ticket_id) references public.ticket_comments(id,ticket_id) on delete no action; end if; end $$;
drop trigger if exists trg_guard_comment_thread on public.ticket_comments;
create trigger trg_guard_comment_thread before insert or update of id,parent_comment_id,ticket_id on public.ticket_comments for each row execute function private.guard_comment_thread('ticket_id');
alter table public.sprint_comments add column if not exists parent_comment_id uuid;
create unique index if not exists sprint_comments_thread_scope_uidx on public.sprint_comments(id,sprint_id);
create index if not exists sprint_comments_thread_parent_idx on public.sprint_comments(parent_comment_id,sprint_id) where parent_comment_id is not null;
do $$ begin if not exists(select 1 from pg_constraint where conrelid='public.sprint_comments'::regclass and conname='sprint_comments_thread_parent_fk') then alter table public.sprint_comments add constraint sprint_comments_thread_parent_fk foreign key(parent_comment_id,sprint_id) references public.sprint_comments(id,sprint_id) on delete no action; end if; end $$;
drop trigger if exists trg_guard_comment_thread on public.sprint_comments;
create trigger trg_guard_comment_thread before insert or update of id,parent_comment_id,sprint_id on public.sprint_comments for each row execute function private.guard_comment_thread('sprint_id');
alter table public.helpdesk_comments add column if not exists parent_comment_id uuid;
create unique index if not exists helpdesk_comments_thread_scope_uidx on public.helpdesk_comments(id,helpdesk_ticket_id);
create index if not exists helpdesk_comments_thread_parent_idx on public.helpdesk_comments(parent_comment_id,helpdesk_ticket_id) where parent_comment_id is not null;
do $$ begin if not exists(select 1 from pg_constraint where conrelid='public.helpdesk_comments'::regclass and conname='helpdesk_comments_thread_parent_fk') then alter table public.helpdesk_comments add constraint helpdesk_comments_thread_parent_fk foreign key(parent_comment_id,helpdesk_ticket_id) references public.helpdesk_comments(id,helpdesk_ticket_id) on delete no action; end if; end $$;
drop trigger if exists trg_guard_comment_thread on public.helpdesk_comments;
create trigger trg_guard_comment_thread before insert or update of id,parent_comment_id,helpdesk_ticket_id on public.helpdesk_comments for each row execute function private.guard_comment_thread('helpdesk_ticket_id');

notify pgrst,'reload schema';
commit;


-- 17.30.9: sprint delivery counts closed tickets only.
begin;
create or replace function public.get_workspace_progress_report(p_workspace uuid,p_as_of date default current_date)
returns jsonb
language plpgsql
stable
security invoker
set search_path=public,pg_temp
as $$
declare result jsonb;
declare week_end date:=p_as_of + (7-extract(isodow from p_as_of)::int);
begin
  if not private.has_workspace_permission(p_workspace,'view_dashboard') then
    raise exception 'No tienes permiso para consultar reportes de este workspace';
  end if;

  with visible_tickets as (
    select t.*,
      coalesce(t.story_points,1)::numeric as weight,
      case t.status
        when 'backlog' then 0 when 'todo' then 10 when 'in_progress' then 45 when 'dev_done' then 65
        when 'qa_review' then 78 when 'qa_rejected' then 58 when 'qa_passed' then 92 when 'closed' then 100 else 0 end::numeric as progress
    from public.tickets t
    where t.workspace_id=p_workspace and private.has_product_access(t.workspace_id,t.product_id)
  ), product_rows as (
    select p.id,p.key,p.name,
      count(v.id)::int total_tickets,
      coalesce(sum(v.weight),0)::numeric total_sp,
      coalesce(round(sum(v.weight*v.progress)/nullif(sum(v.weight),0),1),0) progress_percent,
      count(v.id) filter(where v.status='backlog')::int backlog,
      count(v.id) filter(where v.status in ('todo','in_progress','dev_done'))::int development,
      count(v.id) filter(where v.status in ('qa_review','qa_rejected','qa_passed'))::int qa,
      count(v.id) filter(where v.status='closed')::int closed,
      count(v.id) filter(where v.due_date<p_as_of and v.status not in ('qa_passed','closed'))::int overdue,
      count(v.id) filter(where v.due_date between p_as_of and week_end and v.status not in ('closed'))::int due_this_week,
      coalesce(sum(v.weight) filter(where v.due_date between p_as_of and week_end and v.status not in ('closed')),0)::numeric sp_due_this_week,
      count(v.id) filter(where private.ticket_has_open_blockers(v.id))::int blocked
    from public.products p
    left join visible_tickets v on v.product_id=p.id
    where p.workspace_id=p_workspace and private.has_product_access(p.workspace_id,p.id)
    group by p.id,p.key,p.name,p.board_order
    order by p.board_order
  ), sprint_rows as (
    select s.id,s.name,s.status,s.start_date,s.end_date,
      count(v.id)::int total_tickets,
      count(v.id) filter(where v.status='closed')::int completed,
      count(v.id) filter(where v.status<>'closed')::int remaining,
      coalesce(sum(v.weight),0)::numeric total_sp,
      coalesce(sum(v.weight) filter(where v.status='closed'),0)::numeric completed_sp,
      count(v.id) filter(where private.ticket_has_open_blockers(v.id))::int blocked,
      count(v.id) filter(where v.due_date is not null and v.due_date<=coalesce(s.end_date,p_as_of) and v.status not in ('closed'))::int planned_by_sprint_end,
      coalesce(round(100.0*count(v.id) filter(where v.status='closed')/nullif(count(v.id),0),1),0) progress_percent
    from public.sprints s
    left join visible_tickets v on v.sprint_id=s.id
    where s.workspace_id=p_workspace
      and (s.status='active' or (p_as_of between coalesce(s.start_date,p_as_of) and coalesce(s.end_date,p_as_of)))
    group by s.id,s.name,s.status,s.start_date,s.end_date
    order by s.start_date desc nulls last
    limit 3
  ), module_rows as (
    select m.id,m.module_key,m.name,m.color,
      count(v.id)::int total_tickets,
      coalesce(sum(v.weight),0)::numeric total_sp,
      coalesce(round(sum(v.weight*v.progress)/nullif(sum(v.weight),0),1),0) progress_percent,
      count(v.id) filter(where v.status='closed')::int closed
    from public.ticket_modules m
    left join visible_tickets v on v.module_id=m.id
    where m.workspace_id=p_workspace and m.active
    group by m.id,m.module_key,m.name,m.color
    having count(v.id)>0
    order by count(v.id) desc,m.name
  ), totals as (
    select count(*)::int total_tickets,
      coalesce(sum(weight),0)::numeric total_sp,
      coalesce(round(sum(weight*progress)/nullif(sum(weight),0),1),0) progress_percent,
      count(*) filter(where status='closed')::int closed,
      count(*) filter(where status='backlog')::int backlog,
      count(*) filter(where due_date<p_as_of and status not in ('qa_passed','closed'))::int overdue,
      count(*) filter(where due_date between p_as_of and week_end and status not in ('closed'))::int due_this_week,
      count(*) filter(where private.ticket_has_open_blockers(id))::int blocked
    from visible_tickets
  )
  select jsonb_build_object(
    'as_of',p_as_of,
    'week_end',week_end,
    'workspace_id',p_workspace,
    'workspace',(select jsonb_build_object('name',w.name,'slug',w.slug) from public.workspaces w where w.id=p_workspace),
    'totals',(select to_jsonb(totals) from totals),
    'products',coalesce((select jsonb_agg(to_jsonb(product_rows)) from product_rows),'[]'::jsonb),
    'active_sprints',coalesce((select jsonb_agg(to_jsonb(sprint_rows)) from sprint_rows),'[]'::jsonb),
    'modules',coalesce((select jsonb_agg(to_jsonb(module_rows)) from module_rows),'[]'::jsonb)
  ) into result;
  return result;
end
$$;
notify pgrst,'reload schema';
commit;

-- v17.30.10: historical sprint delivery and carryover tracking.
alter table public.sprints add column if not exists delivery_frozen_at timestamptz;
alter table public.sprints add column if not exists delivery_source text;
create table if not exists public.sprint_delivery_history (
  sprint_id uuid not null references public.sprints(id) on delete cascade,
  ticket_id uuid not null,
  workspace_id uuid not null references public.workspaces(id) on delete cascade,
  product_id uuid not null,
  ticket_key text,
  title text not null,
  status_at_close text not null,
  story_points numeric,
  dev_owner_id uuid,
  qa_owner_id uuid,
  created_by uuid,
  closed_by uuid,
  due_date date,
  captured_at timestamptz not null,
  transfers jsonb not null default '[]'::jsonb,
  first_closed_at timestamptz,
  first_closed_sprint_id uuid,
  first_closed_sprint_name text,
  later_sprint_count integer,
  primary key(sprint_id,ticket_id)
);
create index if not exists sprint_delivery_history_workspace_idx on public.sprint_delivery_history(workspace_id,sprint_id);
create index if not exists sprint_delivery_history_ticket_idx on public.sprint_delivery_history(ticket_id);
alter table public.sprint_delivery_history enable row level security;
revoke all on public.sprint_delivery_history from public,anon,authenticated;
grant select on public.sprint_delivery_history to authenticated;
drop policy if exists sprint_delivery_history_select on public.sprint_delivery_history;
create policy sprint_delivery_history_select on public.sprint_delivery_history for select to authenticated using(private.has_workspace_permission(workspace_id,'view_dashboard') and private.has_workspace_permission(workspace_id,'view_tickets') and private.has_product_access(workspace_id,product_id));
-- Only triggers write history; no client INSERT/UPDATE/DELETE grants.
create or replace function private.freeze_sprint_delivery() returns trigger language plpgsql security definer set search_path='' as $$
begin
  if tg_op='INSERT' then
    new.delivery_frozen_at:=null; new.delivery_source:=null;
    if new.status='completed' then raise exception 'Crea el sprint y ciérralo desde su detalle.'; end if;
    return new;
  end if;
  if auth.uid() is null and old.delivery_frozen_at is null and new.delivery_source='reconstructed' then return new; end if;
  new.delivery_frozen_at:=old.delivery_frozen_at; new.delivery_source:=old.delivery_source;
  if old.status='completed' and new.status<>'completed' then raise exception 'El sprint cerrado conserva su historial; crea un nuevo sprint.'; end if;
  if old.status<>'completed' and new.status='completed' then
    if not private.has_workspace_permission(old.workspace_id,'manage_sprints') then raise exception 'Sin permiso para cerrar sprint' using errcode='42501'; end if;
    if exists(select 1 from public.tickets t where t.sprint_id=old.id and not private.has_product_access(t.workspace_id,t.product_id)) then raise exception 'El cierre requiere acceso a todos los productos del sprint.' using errcode='42501'; end if;
    perform 1 from public.tickets t where t.sprint_id=old.id order by t.id for update;
    new.delivery_frozen_at:=statement_timestamp(); new.delivery_source:='snapshot';
    insert into public.sprint_delivery_history(sprint_id,ticket_id,workspace_id,product_id,ticket_key,title,status_at_close,story_points,dev_owner_id,qa_owner_id,created_by,closed_by,due_date,captured_at)
    select old.id,t.id,t.workspace_id,t.product_id,t.ticket_key,t.title,t.status::text,t.story_points,t.dev_owner_id,t.qa_owner_id,coalesce(t.created_by,t.reporter_id),t.closed_by,t.due_date,new.delivery_frozen_at from public.tickets t where t.sprint_id=old.id;
  end if;
  return new;
end $$;
revoke all on function private.freeze_sprint_delivery() from public,anon,authenticated;
drop trigger if exists trg_freeze_sprint_delivery on public.sprints;
create trigger trg_freeze_sprint_delivery before insert or update on public.sprints for each row execute function private.freeze_sprint_delivery();
create or replace function private.track_sprint_delivery() returns trigger language plpgsql security definer set search_path='' as $$
declare dest_name text; dest_start date;
begin
  if new.sprint_id is not distinct from old.sprint_id and new.status is not distinct from old.status then return new; end if;
  select s.name,s.start_date into dest_name,dest_start from public.sprints s where s.id=new.sprint_id and s.workspace_id=new.workspace_id;
  if new.sprint_id is distinct from old.sprint_id then
    update public.sprint_delivery_history h set transfers=h.transfers||jsonb_build_array(jsonb_build_object('sprint_id',new.sprint_id,'name',coalesce(dest_name,'Backlog'),'at',statement_timestamp()))
    where h.ticket_id=new.id and h.workspace_id=new.workspace_id and h.status_at_close<>'closed' and h.first_closed_at is null;
  end if;
  if new.status='closed' and old.status<>'closed' then
    update public.sprint_delivery_history h set first_closed_at=coalesce(new.closed_at,statement_timestamp()),first_closed_sprint_id=new.sprint_id,first_closed_sprint_name=coalesce(dest_name,'Fuera de sprint'),later_sprint_count=case when dest_start is null or origin.start_date is null then null else (select count(*)::int from public.sprints x where x.workspace_id=h.workspace_id and x.start_date>origin.start_date and x.start_date<=dest_start) end
    from public.sprints origin where origin.id=h.sprint_id and h.ticket_id=new.id and h.workspace_id=new.workspace_id and h.status_at_close<>'closed' and h.first_closed_at is null;
  end if;
  return new;
end $$;
revoke all on function private.track_sprint_delivery() from public,anon,authenticated;
drop trigger if exists trg_track_sprint_delivery on public.tickets;
create trigger trg_track_sprint_delivery after update of sprint_id,status on public.tickets for each row execute function private.track_sprint_delivery();
create or replace function public.close_sprint_and_rollover(p_sprint_id uuid,p_next_sprint_id uuid default null) returns jsonb language plpgsql security invoker set search_path=public,pg_temp as $$
declare v_workspace uuid; v_status public.sprint_status; v_moved integer:=0;
begin
  select workspace_id,status into v_workspace,v_status from public.sprints where id=p_sprint_id for update;
  if v_workspace is null then raise exception 'Sprint not found'; end if;
  if not private.has_workspace_permission(v_workspace,'manage_sprints') or not private.has_workspace_permission(v_workspace,'edit_tickets') then raise exception 'No tienes permiso para cerrar y trasladar el sprint' using errcode='42501'; end if;
  if v_status='completed' then raise exception 'El sprint ya está cerrado.'; end if;
  if p_next_sprint_id is not null then
    if p_next_sprint_id=p_sprint_id or not exists(select 1 from public.sprints where id=p_next_sprint_id and workspace_id=v_workspace and status<>'completed') then raise exception 'El destino debe ser otro sprint abierto del mismo espacio.'; end if;
  end if;
  -- The BEFORE trigger freezes membership and status before any tickets move.
  update public.sprints set status='completed' where id=p_sprint_id;
  if p_next_sprint_id is not null then
    update public.tickets set sprint_id=p_next_sprint_id where sprint_id=p_sprint_id and status<>'closed';
    get diagnostics v_moved=row_count;
    update public.sprints set status='active' where id=p_next_sprint_id and status='planned';
  else
    update public.tickets set sprint_id=null,status='backlog' where sprint_id=p_sprint_id and status<>'closed';
    get diagnostics v_moved=row_count;
  end if;
  return jsonb_build_object('ok',true,'moved',v_moved,'source_sprint_id',p_sprint_id,'next_sprint_id',p_next_sprint_id);
end $$;
revoke all on function public.close_sprint_and_rollover(uuid,uuid) from public,anon;
grant execute on function public.close_sprint_and_rollover(uuid,uuid) to authenticated;
notify pgrst,'reload schema';
-- Use the same frozen membership in period reports, never current membership for completed sprints.
do $$
declare f text; a integer; b integer; seg text;
begin
select pg_get_functiondef('public.get_workspace_progress_report(uuid,date)'::regprocedure) into f;
a:=strpos(f,'), sprint_rows as ('); b:=strpos(f,'), module_rows as (');
if a=0 or b<=a then raise exception 'Unexpected report definition'; end if;
seg:=substring(f from a for b-a);
if strpos(seg,'sprint_delivery_history')>0 then return; end if;
seg:=replace(seg,'left join visible_tickets v on v.sprint_id=s.id', 'left join (select v.id,v.sprint_id,v.weight,v.status::text status,v.due_date from visible_tickets v join public.sprints live on live.id=v.sprint_id and live.status<>''completed'' union all select h.ticket_id,h.sprint_id,coalesce(h.story_points,1)::numeric,h.status_at_close,h.due_date from public.sprint_delivery_history h where h.workspace_id=p_workspace) v on v.sprint_id=s.id');
seg:=replace(seg,'where s.workspace_id=p_workspace','where s.workspace_id=p_workspace and (s.status<>''completed'' or s.delivery_frozen_at is not null)');
seg:=replace(seg,'count(v.id) filter(where private.ticket_has_open_blockers(v.id))','count(v.id) filter(where s.status<>''completed'' and private.ticket_has_open_blockers(v.id))');
execute substring(f from 1 for a-1)||seg||substring(f from b);
end $$;
