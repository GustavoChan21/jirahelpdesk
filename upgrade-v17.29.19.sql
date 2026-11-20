-- Jira TROBBU v17.29.19
-- Perfil/avatar + catálogo de tags internas Helpdesk + hardening de links

begin;

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values ('jira-avatars','jira-avatars',true,2097152,array['image/webp']::text[])
on conflict (id) do update
set public=true,
    file_size_limit=2097152,
    allowed_mime_types=array['image/webp']::text[],
    updated_at=now();

drop policy if exists jira_avatars_select_own on storage.objects;
create policy jira_avatars_select_own on storage.objects
for select to authenticated
using (bucket_id='jira-avatars' and (storage.foldername(name))[1]=(select auth.uid())::text);

drop policy if exists jira_avatars_insert_own on storage.objects;
create policy jira_avatars_insert_own on storage.objects
for insert to authenticated
with check (bucket_id='jira-avatars' and (storage.foldername(name))[1]=(select auth.uid())::text);

drop policy if exists jira_avatars_update_own on storage.objects;
create policy jira_avatars_update_own on storage.objects
for update to authenticated
using (bucket_id='jira-avatars' and (storage.foldername(name))[1]=(select auth.uid())::text)
with check (bucket_id='jira-avatars' and (storage.foldername(name))[1]=(select auth.uid())::text);

drop policy if exists jira_avatars_delete_own on storage.objects;
create policy jira_avatars_delete_own on storage.objects
for delete to authenticated
using (bucket_id='jira-avatars' and (storage.foldername(name))[1]=(select auth.uid())::text);

create unique index if not exists uq_helpdesk_internal_tags_workspace_name
on public.helpdesk_internal_tags(workspace_id, lower(name));

create index if not exists ix_helpdesk_ticket_internal_tags_workspace_tag
on public.helpdesk_ticket_internal_tags(workspace_id,tag_id);

create index if not exists ix_helpdesk_internal_tags_created_by
on public.helpdesk_internal_tags(created_by);

create index if not exists ix_helpdesk_ticket_internal_tags_created_by
on public.helpdesk_ticket_internal_tags(created_by);


-- Catalog management is PM/Admin/Superadmin; Dev may read/use tags but not mutate the catalog.
drop policy if exists helpdesk_internal_tags_insert on public.helpdesk_internal_tags;
create policy helpdesk_internal_tags_insert on public.helpdesk_internal_tags
for insert to authenticated
with check (
  private.has_workspace_role(workspace_id,array['pm','admin','superadmin']::public.app_role[])
);

drop policy if exists helpdesk_internal_tags_update on public.helpdesk_internal_tags;
create policy helpdesk_internal_tags_update on public.helpdesk_internal_tags
for update to authenticated
using (
  private.has_workspace_role(workspace_id,array['pm','admin','superadmin']::public.app_role[])
)
with check (
  private.has_workspace_role(workspace_id,array['pm','admin','superadmin']::public.app_role[])
);

drop policy if exists helpdesk_ticket_internal_tags_select on public.helpdesk_ticket_internal_tags;
create policy helpdesk_ticket_internal_tags_select on public.helpdesk_ticket_internal_tags
for select to authenticated
using (
  private.has_workspace_role(workspace_id,array['dev','pm','admin','superadmin']::public.app_role[])
  and exists (select 1 from public.helpdesk_tickets h where h.id=helpdesk_ticket_id and h.workspace_id=helpdesk_ticket_internal_tags.workspace_id)
  and exists (select 1 from public.helpdesk_internal_tags t where t.id=tag_id and t.workspace_id=helpdesk_ticket_internal_tags.workspace_id)
);

drop policy if exists helpdesk_ticket_internal_tags_insert on public.helpdesk_ticket_internal_tags;
create policy helpdesk_ticket_internal_tags_insert on public.helpdesk_ticket_internal_tags
for insert to authenticated
with check (
  private.has_workspace_role(workspace_id,array['dev','pm','admin','superadmin']::public.app_role[])
  and exists (select 1 from public.helpdesk_tickets h where h.id=helpdesk_ticket_id and h.workspace_id=helpdesk_ticket_internal_tags.workspace_id)
  and exists (select 1 from public.helpdesk_internal_tags t where t.id=tag_id and t.workspace_id=helpdesk_ticket_internal_tags.workspace_id and t.active=true)
);

drop policy if exists helpdesk_ticket_internal_tags_delete on public.helpdesk_ticket_internal_tags;
create policy helpdesk_ticket_internal_tags_delete on public.helpdesk_ticket_internal_tags
for delete to authenticated
using (
  private.has_workspace_role(workspace_id,array['dev','pm','admin','superadmin']::public.app_role[])
  and exists (select 1 from public.helpdesk_tickets h where h.id=helpdesk_ticket_id and h.workspace_id=helpdesk_ticket_internal_tags.workspace_id)
);

create or replace function private.broadcast_helpdesk_internal_tag_catalog_change()
returns trigger
language plpgsql
security definer
set search_path=''
as $function$
declare
  v_row jsonb;
  v_workspace uuid;
begin
  if tg_op='DELETE' then
    v_row:=to_jsonb(old);
    v_workspace:=old.workspace_id;
  else
    v_row:=to_jsonb(new);
    v_workspace:=new.workspace_id;
  end if;

  perform realtime.send(
    jsonb_build_object(
      'workspace_id',v_workspace,
      'entity','internal_tag_catalog',
      'operation',lower(tg_op),
      'row',v_row,
      'changed_at',clock_timestamp()
    ),
    'helpdesk_changed',
    'workspace:'||v_workspace::text||':helpdesk',
    true
  );

  if tg_op='DELETE' then return old; end if;
  return new;
end
$function$;

revoke all on function private.broadcast_helpdesk_internal_tag_catalog_change() from public,anon,authenticated;

drop trigger if exists trg_90_helpdesk_internal_tag_catalog_broadcast on public.helpdesk_internal_tags;
create trigger trg_90_helpdesk_internal_tag_catalog_broadcast
after insert or update or delete on public.helpdesk_internal_tags
for each row execute function private.broadcast_helpdesk_internal_tag_catalog_change();

-- Keep avatar_url in workspace bootstrap so profile photos survive reloads.
create or replace function public.get_workspace_bootstrap_v3(p_workspace uuid)
returns jsonb
language plpgsql
stable
set search_path to 'public','pg_temp'
as $function$
declare
  v_user uuid:=auth.uid();
  v_result jsonb;
begin
  if v_user is null or not private.is_workspace_member(p_workspace) then
    raise exception 'No autorizado para cargar este workspace.' using errcode='42501';
  end if;

  select jsonb_build_object(
    'products',coalesce((select jsonb_agg(to_jsonb(x) order by x.board_order nulls last,x.name) from public.list_authorized_products(p_workspace) x),'[]'::jsonb),
    'sprints',coalesce((select jsonb_agg(to_jsonb(x) order by x.created_at desc) from public.sprints x where x.workspace_id=p_workspace),'[]'::jsonb),
    'tickets',coalesce((select jsonb_agg(to_jsonb(x) order by x.updated_at desc) from public.tickets x where x.workspace_id=p_workspace),'[]'::jsonb),
    'members',coalesce((select jsonb_agg(to_jsonb(m)||jsonb_build_object('profile',jsonb_build_object('id',p.id,'email',p.email,'full_name',p.full_name,'avatar_url',p.avatar_url,'job_title',p.job_title,'locale',p.locale)) order by m.joined_at) from public.workspace_members m left join public.profiles p on p.id=m.user_id where m.workspace_id=p_workspace),'[]'::jsonb),
    'member_products',coalesce((select jsonb_agg(to_jsonb(x)) from public.workspace_member_products x where x.workspace_id=p_workspace),'[]'::jsonb),
    'roles',coalesce((select jsonb_agg(to_jsonb(x) order by x.created_at) from public.workspace_roles x where x.workspace_id=p_workspace),'[]'::jsonb),
    'settings',(select to_jsonb(x) from public.workspace_settings x where x.workspace_id=p_workspace limit 1),
    'modules',coalesce((select jsonb_agg(to_jsonb(x) order by x.name) from public.ticket_modules x where x.workspace_id=p_workspace),'[]'::jsonb),
    'tags',coalesce((select jsonb_agg(to_jsonb(x) order by x.name) from public.ticket_tags x where x.workspace_id=p_workspace),'[]'::jsonb),
    'ticket_tag_links',coalesce((select jsonb_agg(to_jsonb(x)) from public.ticket_tag_links x where x.workspace_id=p_workspace),'[]'::jsonb),
    'ticket_mentions',coalesce((select jsonb_agg(to_jsonb(x) order by x.last_mentioned_at desc) from public.ticket_mentions x where x.workspace_id=p_workspace and x.user_id=v_user),'[]'::jsonb),
    'helpdesk_mentions',coalesce((select jsonb_agg(to_jsonb(x) order by x.last_mentioned_at desc) from public.helpdesk_mentions x where x.workspace_id=p_workspace and x.user_id=v_user),'[]'::jsonb),
    'knowledge_articles',coalesce((select jsonb_agg(to_jsonb(x) order by x.updated_at desc) from public.knowledge_articles x where x.workspace_id=p_workspace),'[]'::jsonb),
    'vacation_requests',coalesce((select jsonb_agg(to_jsonb(x) order by x.start_date) from public.vacation_requests x where x.workspace_id=p_workspace),'[]'::jsonb),
    'notifications',coalesce((select jsonb_agg(to_jsonb(n) order by n.created_at desc) from (select * from public.notifications x where x.workspace_id=p_workspace and x.user_id=v_user order by x.created_at desc limit 500) n),'[]'::jsonb),
    'board_orders',coalesce((select jsonb_agg(to_jsonb(x) order by x.status,x.sort_order) from public.ticket_board_orders x where x.workspace_id=p_workspace and x.user_id=v_user),'[]'::jsonb),
    'counters',public.get_live_counters(p_workspace)
  ) into v_result;
  return v_result;
end;
$function$;

revoke all on function public.get_workspace_bootstrap_v3(uuid) from public,anon;
grant execute on function public.get_workspace_bootstrap_v3(uuid) to authenticated;

commit;
