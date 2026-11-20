-- Jira TROBBU v17.29.20
-- Helpdesk concurrency/performance stabilization.

-- Cheap RLS-aware health watermark used by the client to detect missed Broadcasts
-- without reloading the whole Helpdesk list.
create or replace function public.get_helpdesk_watermark(p_workspace uuid)
returns jsonb
language plpgsql
stable
set search_path to 'public','pg_temp'
as $function$
declare
  v_uid uuid := (select auth.uid());
  v_total bigint := 0;
  v_max_updated timestamptz;
begin
  if v_uid is null then raise exception 'Authentication required'; end if;
  if not private.is_workspace_member(p_workspace) then raise exception 'Workspace access required'; end if;

  select count(*), max(updated_at)
  into v_total, v_max_updated
  from public.helpdesk_tickets
  where workspace_id=p_workspace;

  return jsonb_build_object(
    'total',v_total,
    'max_updated_at',v_max_updated,
    'generated_at',clock_timestamp()
  );
end
$function$;
revoke all on function public.get_helpdesk_watermark(uuid) from public,anon;
grant execute on function public.get_helpdesk_watermark(uuid) to authenticated;

-- Keep queue metadata on the INSERT row itself, avoiding the immediate UPDATE
-- that previously produced a second audit/Broadcast for every new Helpdesk ticket.
create or replace function private.prepare_helpdesk_auto_assignment()
returns trigger
language plpgsql
security definer
set search_path to 'public','pg_temp'
as $function$
declare
  v_enabled boolean := true;
begin
  if new.category in ('module','feature','new_requirement') or new.assigned_to is not null then
    return new;
  end if;

  select coalesce(helpdesk_auto_assignment_enabled,true)
  into v_enabled
  from public.workspace_settings
  where workspace_id=new.workspace_id;

  if not coalesce(v_enabled,true) then return new; end if;

  new.assignment_source := coalesce(new.assignment_source,'queue');
  new.assignment_reason := coalesce(new.assignment_reason,'Pendiente de análisis automático.');
  new.assignment_queued_at := coalesce(new.assignment_queued_at,now());
  return new;
end
$function$;
revoke all on function private.prepare_helpdesk_auto_assignment() from public,anon,authenticated;

drop trigger if exists trg_02_helpdesk_auto_queue_prepare on public.helpdesk_tickets;
create trigger trg_02_helpdesk_auto_queue_prepare
before insert on public.helpdesk_tickets
for each row execute function private.prepare_helpdesk_auto_assignment();

create or replace function private.enqueue_helpdesk_auto_assignment()
returns trigger
language plpgsql
security definer
set search_path to 'public','pg_temp'
as $function$
declare
  v_enabled boolean := true;
begin
  if new.category in ('module','feature','new_requirement') or new.assigned_to is not null then return new; end if;
  select coalesce(helpdesk_auto_assignment_enabled,true) into v_enabled
  from public.workspace_settings where workspace_id=new.workspace_id;
  if not coalesce(v_enabled,true) then return new; end if;

  insert into public.helpdesk_assignment_queue(
    workspace_id,helpdesk_ticket_id,status,reason,queued_at,updated_at
  ) values(
    new.workspace_id,new.id,'waiting',coalesce(new.assignment_reason,'Pendiente de análisis automático.'),
    coalesce(new.assignment_queued_at,now()),now()
  )
  on conflict(helpdesk_ticket_id) do update
  set status='waiting',
      reason=excluded.reason,
      queued_at=coalesce(public.helpdesk_assignment_queue.queued_at,excluded.queued_at),
      updated_at=now();
  return new;
end
$function$;
revoke all on function private.enqueue_helpdesk_auto_assignment() from public,anon,authenticated;

-- Only one queue drainer may run at a time across cron/manual/trigger paths.
create or replace function private.process_helpdesk_assignment_queue_impl(p_workspace uuid default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public','private','pg_temp'
as $function$
declare
  r record;
  result jsonb;
  processed int:=0;
  assigned int:=0;
  caller uuid:=(select auth.uid());
  internal_call boolean:=coalesce(current_setting('app.helpdesk_internal_queue',true),'')='1';
begin
  if caller is not null and not internal_call and p_workspace is not null
     and not private.has_workspace_permission(p_workspace,'manage_helpdesk')
     and not private.has_workspace_permission(p_workspace,'manage_staff') then
    raise exception 'Insufficient Helpdesk permissions';
  end if;

  if not pg_try_advisory_xact_lock(17292020261120::bigint) then
    return jsonb_build_object('processed',0,'assigned',0,'skipped','locked');
  end if;
  if coalesce(current_setting('app.helpdesk_queue_draining',true),'')='1' then
    return jsonb_build_object('processed',0,'assigned',0,'skipped','already_draining');
  end if;
  perform set_config('app.helpdesk_queue_draining','1',true);

  for r in
    select q.helpdesk_ticket_id
    from public.helpdesk_assignment_queue q
    join public.helpdesk_tickets h on h.id=q.helpdesk_ticket_id
    where q.status='waiting'
      and (p_workspace is null or q.workspace_id=p_workspace)
      and h.assigned_to is null
      and h.status<>'closed'
    order by q.queued_at
    limit 50
    for update of q skip locked
  loop
    processed:=processed+1;
    result:=private.route_helpdesk_ticket_rules(r.helpdesk_ticket_id);
    if coalesce((result->>'assigned')::boolean,false) then assigned:=assigned+1; end if;
  end loop;

  return jsonb_build_object('processed',processed,'assigned',assigned);
end
$function$;
revoke all on function private.process_helpdesk_assignment_queue_impl(uuid) from public,anon,authenticated;

-- Optimized aggregate counters: same JSON contract, substantially less repeated work.
create or replace function public.get_live_counters(p_workspace uuid)
returns jsonb
language plpgsql
stable
set search_path to 'public','pg_temp'
as $function$
declare
  v_uid uuid := (select auth.uid());
  v_navigation jsonb;
  v_modules jsonb := '[]'::jsonb;
  v_helpdesk jsonb;
  v_ticket_total bigint:=0;
  v_backlog bigint:=0;
  v_mytasks bigint:=0;
  v_knowledge bigint:=0;
  v_unread bigint:=0;
  v_products jsonb:='{}'::jsonb;
begin
  if v_uid is null then raise exception 'Authentication required'; end if;
  if not private.is_workspace_member(p_workspace) then raise exception 'Workspace access required'; end if;

  select count(*),
         count(*) filter(where sprint_id is null and status<>'closed'),
         count(*) filter(where reporter_id=v_uid or dev_owner_id=v_uid or qa_owner_id=v_uid)
  into v_ticket_total,v_backlog,v_mytasks
  from public.tickets
  where workspace_id=p_workspace;

  select count(*) into v_knowledge from public.knowledge_articles where workspace_id=p_workspace;
  select count(*) into v_unread from public.notifications where workspace_id=p_workspace and user_id=v_uid and read_at is null;

  select coalesce(jsonb_object_agg(product_id::text,cnt),'{}'::jsonb)
  into v_products
  from (
    select product_id,count(*)::bigint cnt
    from public.tickets
    where workspace_id=p_workspace and product_id is not null
    group by product_id
  ) p;

  with ticket_module as (
    select module_id,count(*)::bigint cnt
    from public.tickets
    where workspace_id=p_workspace and module_id is not null
    group by module_id
  ), activity_module as (
    select t.module_id,count(*)::bigint cnt
    from public.ticket_activity a
    join public.tickets t on t.id=a.ticket_id
    where t.workspace_id=p_workspace and t.module_id is not null
    group by t.module_id
  ), article_module as (
    select module_id,count(*)::bigint cnt
    from public.knowledge_articles
    where workspace_id=p_workspace and module_id is not null
    group by module_id
  )
  select coalesce(jsonb_agg(
    jsonb_build_object(
      'module_id',m.id,
      'ticket_count',coalesce(tm.cnt,0),
      'activity_count',coalesce(am.cnt,0),
      'article_count',coalesce(km.cnt,0)
    ) order by m.name
  ),'[]'::jsonb)
  into v_modules
  from public.ticket_modules m
  left join ticket_module tm on tm.module_id=m.id
  left join activity_module am on am.module_id=m.id
  left join article_module km on km.module_id=m.id
  where m.workspace_id=p_workspace;

  select jsonb_build_object(
    'total',count(*),
    'created',count(*) filter(where h.category not in ('module','feature','new_requirement') and h.status='created'),
    'review',count(*) filter(where h.category not in ('module','feature','new_requirement') and h.status='review'),
    'attended',count(*) filter(where h.category not in ('module','feature','new_requirement') and h.status='attended'),
    'closed',count(*) filter(where h.category not in ('module','feature','new_requirement') and h.status='closed'),
    'pending_requirements',count(*) filter(where h.category in ('module','feature','new_requirement') and coalesce(h.proposal_status,'pending')='pending'),
    'approved_requirements',count(*) filter(where h.category in ('module','feature','new_requirement') and h.proposal_status='accepted_backlog'),
    'rejected_requirements',count(*) filter(where h.category in ('module','feature','new_requirement') and h.proposal_status='rejected'),
    'overdue',count(*) filter(where h.category not in ('module','feature','new_requirement') and h.status<>'closed' and h.due_at is not null and h.due_at<now()),
    'max_updated_at',max(h.updated_at)
  ) into v_helpdesk
  from public.helpdesk_tickets h
  where h.workspace_id=p_workspace;

  v_navigation:=jsonb_build_object(
    'tickets',v_ticket_total,
    'backlog',v_backlog,
    'knowledge',v_knowledge,
    'helpdesk',coalesce((v_helpdesk->>'total')::bigint,0),
    'mytasks',v_mytasks,
    'notifications_unread',v_unread,
    'products',v_products
  );

  return jsonb_build_object(
    'navigation',v_navigation,
    'modules',v_modules,
    'helpdesk',v_helpdesk,
    'generated_at',now()
  );
end
$function$;
revoke all on function public.get_live_counters(uuid) from public,anon;
grant execute on function public.get_live_counters(uuid) to authenticated;
