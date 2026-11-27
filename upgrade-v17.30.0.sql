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
