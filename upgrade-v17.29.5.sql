-- Jira TROBBU v17.29.6
-- Restore notification history/counters for the intended recipient and preload the last 100 notifications in workspace bootstrap.

drop policy if exists notifications_select on public.notifications;
create policy notifications_select on public.notifications
for select to authenticated
using (
  user_id=(select auth.uid())
  and private.is_workspace_member(workspace_id)
);

create or replace function public.get_workspace_bootstrap_v3(p_workspace uuid)
returns jsonb
language plpgsql
stable
security invoker
set search_path=public,pg_temp
as $$
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
    'members',coalesce((select jsonb_agg(to_jsonb(m)||jsonb_build_object('profile',jsonb_build_object('id',p.id,'email',p.email,'full_name',p.full_name,'job_title',p.job_title,'locale',p.locale)) order by m.joined_at) from public.workspace_members m left join public.profiles p on p.id=m.user_id where m.workspace_id=p_workspace),'[]'::jsonb),
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
$$;

revoke all on function public.get_workspace_bootstrap_v3(uuid) from public,anon;
grant execute on function public.get_workspace_bootstrap_v3(uuid) to authenticated;
