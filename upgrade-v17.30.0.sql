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
