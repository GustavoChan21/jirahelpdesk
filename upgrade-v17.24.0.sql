-- Jira TROBBU v17.24.0
-- Performance/concurrency, per-user Kanban ordering and resilient email queue.

create table if not exists public.ticket_board_orders (
  workspace_id uuid not null references public.workspaces(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  ticket_id uuid not null,
  status text not null check (status in ('backlog','todo','in_progress','dev_done','qa_review','qa_rejected','qa_passed','closed')),
  sort_order integer not null,
  updated_at timestamptz not null default now(),
  primary key (workspace_id, user_id, ticket_id),
  constraint ticket_board_orders_ticket_workspace_fkey
    foreign key (ticket_id, workspace_id) references public.tickets(id, workspace_id) on delete cascade
);

create index if not exists ix_ticket_board_orders_user_lane
  on public.ticket_board_orders(workspace_id, user_id, status, sort_order, ticket_id);

alter table public.ticket_board_orders enable row level security;

drop policy if exists ticket_board_orders_select_self on public.ticket_board_orders;
create policy ticket_board_orders_select_self
on public.ticket_board_orders for select to authenticated
using (
  user_id = (select auth.uid())
  and private.is_workspace_member(workspace_id)
);

drop policy if exists ticket_board_orders_insert_self on public.ticket_board_orders;
create policy ticket_board_orders_insert_self
on public.ticket_board_orders for insert to authenticated
with check (
  user_id = (select auth.uid())
  and private.is_workspace_member(workspace_id)
);

drop policy if exists ticket_board_orders_update_self on public.ticket_board_orders;
create policy ticket_board_orders_update_self
on public.ticket_board_orders for update to authenticated
using (
  user_id = (select auth.uid())
  and private.is_workspace_member(workspace_id)
)
with check (
  user_id = (select auth.uid())
  and private.is_workspace_member(workspace_id)
);

drop policy if exists ticket_board_orders_delete_self on public.ticket_board_orders;
create policy ticket_board_orders_delete_self
on public.ticket_board_orders for delete to authenticated
using (
  user_id = (select auth.uid())
  and private.is_workspace_member(workspace_id)
);

grant select,insert,update,delete on public.ticket_board_orders to authenticated;

create or replace function public.set_ticket_board_order(
  p_workspace uuid,
  p_status text,
  p_ticket_ids uuid[]
) returns jsonb
language plpgsql
security invoker
set search_path = public, pg_temp
as $$
declare
  v_user uuid := auth.uid();
  v_expected integer := coalesce(array_length(p_ticket_ids, 1), 0);
  v_valid integer := 0;
begin
  if v_user is null or not private.is_workspace_member(p_workspace) then
    raise exception 'No autorizado para ordenar tickets en este workspace.' using errcode='42501';
  end if;
  if p_status not in ('backlog','todo','in_progress','dev_done','qa_review','qa_rejected','qa_passed','closed') then
    raise exception 'Estado de Kanban inválido.';
  end if;

  if v_expected > 0 then
    select count(*) into v_valid
    from public.tickets t
    where t.workspace_id = p_workspace
      and t.status = p_status::public.ticket_status
      and t.id = any(p_ticket_ids);
    if v_valid <> v_expected then
      raise exception 'La lista contiene tickets que ya no pertenecen a esta columna.';
    end if;
  end if;

  delete from public.ticket_board_orders
  where workspace_id=p_workspace and user_id=v_user and status=p_status;

  insert into public.ticket_board_orders(workspace_id,user_id,ticket_id,status,sort_order,updated_at)
  select p_workspace,v_user,x.ticket_id,p_status,(x.ord::integer)*1000,now()
  from unnest(coalesce(p_ticket_ids,array[]::uuid[])) with ordinality as x(ticket_id,ord)
  on conflict (workspace_id,user_id,ticket_id)
  do update set status=excluded.status,sort_order=excluded.sort_order,updated_at=now();

  return jsonb_build_object('status',p_status,'count',v_expected);
end;
$$;

revoke all on function public.set_ticket_board_order(uuid,text,uuid[]) from public,anon;
grant execute on function public.set_ticket_board_order(uuid,text,uuid[]) to authenticated;

-- Single-request bootstrap to avoid 20+ parallel REST calls for every login.
create or replace function public.get_workspace_bootstrap_v3(p_workspace uuid)
returns jsonb
language plpgsql
stable
security invoker
set search_path = public, pg_temp
as $$
declare
  v_user uuid := auth.uid();
  v_result jsonb;
begin
  if v_user is null or not private.is_workspace_member(p_workspace) then
    raise exception 'No autorizado para cargar este workspace.' using errcode='42501';
  end if;

  select jsonb_build_object(
    'products', coalesce((select jsonb_agg(to_jsonb(x) order by x.board_order nulls last,x.name) from public.list_authorized_products(p_workspace) x),'[]'::jsonb),
    'sprints', coalesce((select jsonb_agg(to_jsonb(x) order by x.created_at desc) from public.sprints x where x.workspace_id=p_workspace),'[]'::jsonb),
    'tickets', coalesce((select jsonb_agg(to_jsonb(x) order by x.updated_at desc) from public.tickets x where x.workspace_id=p_workspace),'[]'::jsonb),
    'members', coalesce((
      select jsonb_agg(
        to_jsonb(m) || jsonb_build_object('profile',jsonb_build_object('id',p.id,'email',p.email,'full_name',p.full_name,'job_title',p.job_title,'locale',p.locale))
        order by m.joined_at
      )
      from public.workspace_members m
      left join public.profiles p on p.id=m.user_id
      where m.workspace_id=p_workspace
    ),'[]'::jsonb),
    'member_products', coalesce((select jsonb_agg(to_jsonb(x)) from public.workspace_member_products x where x.workspace_id=p_workspace),'[]'::jsonb),
    'roles', coalesce((select jsonb_agg(to_jsonb(x) order by x.created_at) from public.workspace_roles x where x.workspace_id=p_workspace),'[]'::jsonb),
    'settings', (select to_jsonb(x) from public.workspace_settings x where x.workspace_id=p_workspace limit 1),
    'modules', coalesce((select jsonb_agg(to_jsonb(x) order by x.name) from public.ticket_modules x where x.workspace_id=p_workspace),'[]'::jsonb),
    'tags', coalesce((select jsonb_agg(to_jsonb(x) order by x.name) from public.ticket_tags x where x.workspace_id=p_workspace),'[]'::jsonb),
    'ticket_tag_links', coalesce((select jsonb_agg(to_jsonb(x)) from public.ticket_tag_links x where x.workspace_id=p_workspace),'[]'::jsonb),
    'ticket_mentions', coalesce((select jsonb_agg(to_jsonb(x) order by x.last_mentioned_at desc) from public.ticket_mentions x where x.workspace_id=p_workspace and x.user_id=v_user),'[]'::jsonb),
    'helpdesk_mentions', coalesce((select jsonb_agg(to_jsonb(x) order by x.last_mentioned_at desc) from public.helpdesk_mentions x where x.workspace_id=p_workspace and x.user_id=v_user),'[]'::jsonb),
    'knowledge_articles', coalesce((select jsonb_agg(to_jsonb(x) order by x.updated_at desc) from public.knowledge_articles x where x.workspace_id=p_workspace),'[]'::jsonb),
    'vacation_requests', coalesce((select jsonb_agg(to_jsonb(x) order by x.start_date) from public.vacation_requests x where x.workspace_id=p_workspace),'[]'::jsonb),
    'board_orders', coalesce((select jsonb_agg(to_jsonb(x) order by x.status,x.sort_order) from public.ticket_board_orders x where x.workspace_id=p_workspace and x.user_id=v_user),'[]'::jsonb),
    'counters', public.get_live_counters(p_workspace)
  ) into v_result;

  return v_result;
end;
$$;

revoke all on function public.get_workspace_bootstrap_v3(uuid) from public,anon;
grant execute on function public.get_workspace_bootstrap_v3(uuid) to authenticated;

-- Notification queue: transient provider quota errors must not permanently lose mail.
alter table public.notification_outbox add column if not exists processing_at timestamptz;
alter table public.notification_outbox add column if not exists next_attempt_at timestamptz;
create index if not exists ix_notification_outbox_claim
  on public.notification_outbox(workspace_id,status,next_attempt_at,created_at,id);

create or replace function public.claim_notification_batch(
  p_workspace uuid,
  p_limit integer default 20,
  p_rollout_at timestamptz default '1970-01-01'::timestamptz
) returns setof public.notification_outbox
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  -- Service-role only function. Reclaim interrupted workers after 5 minutes.
  update public.notification_outbox
  set status='pending', processing_at=null,
      last_error=coalesce(last_error,'') || case when coalesce(last_error,'')='' then '' else ' · ' end || 'Recovered stale processing claim'
  where workspace_id=p_workspace
    and status='processing'
    and processing_at < now()-interval '5 minutes';

  return query
  with picked as (
    select o.id
    from public.notification_outbox o
    where o.workspace_id=p_workspace
      and o.status in ('pending','failed')
      and o.created_at >= p_rollout_at
      and coalesce(o.next_attempt_at,'1970-01-01'::timestamptz) <= now()
      and o.attempts < 6
    order by case when o.event_type='daily_jira_reminder' then 1 else 0 end, o.created_at, o.id
    for update skip locked
    limit greatest(1,least(coalesce(p_limit,20),50))
  )
  update public.notification_outbox o
  set status='processing',processing_at=now(),attempts=o.attempts+1,provider='sendpulse'
  from picked p
  where o.id=p.id
  returning o.*;
end;
$$;

revoke all on function public.claim_notification_batch(uuid,integer,timestamptz) from public,anon,authenticated;
grant execute on function public.claim_notification_batch(uuid,integer,timestamptz) to service_role;

-- Reset records stranded by earlier concurrent browser/cron executions.
update public.notification_outbox
set status='pending',processing_at=null,next_attempt_at=now()
where status='processing';

-- Helpful indexes for detail loading.
create index if not exists ix_ticket_comments_ticket_created on public.ticket_comments(ticket_id,created_at);
create index if not exists ix_ticket_activity_ticket_created on public.ticket_activity(ticket_id,created_at desc);
create index if not exists ix_ticket_attachments_ticket_created on public.ticket_attachments(ticket_id,created_at);
create index if not exists ix_helpdesk_comments_ticket_created on public.helpdesk_comments(helpdesk_ticket_id,created_at);
create index if not exists ix_helpdesk_activity_ticket_created on public.helpdesk_activity(helpdesk_ticket_id,created_at desc);
create index if not exists ix_helpdesk_attachments_ticket_created on public.helpdesk_attachments(helpdesk_ticket_id,created_at);


-- Lightweight counters: retain only the unread notification count at bootstrap.
create or replace function public.get_live_counters(p_workspace uuid)
returns jsonb
language plpgsql
stable
security invoker
set search_path=public,pg_temp
as $$
declare
  v_uid uuid:=(select auth.uid());
  v_navigation jsonb;
  v_modules jsonb:='[]'::jsonb;
  v_helpdesk jsonb;
begin
  if v_uid is null then raise exception 'Authentication required';end if;
  if not private.is_workspace_member(p_workspace) then raise exception 'Workspace access required';end if;
  select jsonb_build_object(
    'tickets',(select count(*) from public.tickets t where t.workspace_id=p_workspace),
    'backlog',(select count(*) from public.tickets t where t.workspace_id=p_workspace and t.sprint_id is null and t.status<>'closed'),
    'knowledge',(select count(*) from public.knowledge_articles k where k.workspace_id=p_workspace),
    'helpdesk',(select count(*) from public.helpdesk_tickets h where h.workspace_id=p_workspace),
    'mytasks',(select count(*) from public.tickets t where t.workspace_id=p_workspace and (t.reporter_id=v_uid or t.dev_owner_id=v_uid or t.qa_owner_id=v_uid)),
    'notifications_unread',(select count(*) from public.notifications n where n.workspace_id=p_workspace and n.user_id=v_uid and n.read_at is null),
    'products',coalesce((select jsonb_object_agg(x.product_id::text,x.cnt) from (select t.product_id,count(*)::bigint cnt from public.tickets t where t.workspace_id=p_workspace group by t.product_id)x),'{}'::jsonb)
  ) into v_navigation;
  select coalesce(jsonb_agg(jsonb_build_object('module_id',q.module_id,'ticket_count',q.ticket_count,'activity_count',q.activity_count,'article_count',q.article_count) order by q.name),'[]'::jsonb)
  into v_modules
  from (
    select m.id module_id,m.name,
      (select count(*) from public.tickets t where t.workspace_id=p_workspace and t.module_id=m.id) ticket_count,
      (select count(*) from public.ticket_activity a join public.tickets t on t.id=a.ticket_id where t.workspace_id=p_workspace and t.module_id=m.id) activity_count,
      (select count(*) from public.knowledge_articles k where k.workspace_id=p_workspace and k.module_id=m.id) article_count
    from public.ticket_modules m where m.workspace_id=p_workspace
  ) q;
  select jsonb_build_object(
    'total',count(*),
    'created',count(*) filter(where h.category not in ('module','feature','new_requirement') and h.status='created'),
    'review',count(*) filter(where h.category not in ('module','feature','new_requirement') and h.status='review'),
    'attended',count(*) filter(where h.category not in ('module','feature','new_requirement') and h.status='attended'),
    'closed',count(*) filter(where h.category not in ('module','feature','new_requirement') and h.status='closed'),
    'pending_requirements',count(*) filter(where h.category in ('module','feature','new_requirement') and coalesce(h.proposal_status,'pending')='pending'),
    'overdue',count(*) filter(where h.category not in ('module','feature','new_requirement') and h.status<>'closed' and h.due_at is not null and h.due_at<now())
  ) into v_helpdesk
  from public.helpdesk_tickets h where h.workspace_id=p_workspace;
  return jsonb_build_object('navigation',v_navigation,'modules',v_modules,'helpdesk',v_helpdesk,'generated_at',now());
end $$;

create index if not exists ix_notifications_workspace_user_unread
  on public.notifications(workspace_id,user_id,created_at desc)
  where read_at is null;
