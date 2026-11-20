-- Jira TROBBU v17.29.21
-- Helpdesk queue backoff, secure manual queue drain and reduced realtime churn.
-- Safe to run after v17.29.20. Idempotent where practical.

-- Retry-aware lookup for queued assignments. The existing waiting index is kept;
-- this one makes the backoff predicate cheap when several tickets are waiting.
create index if not exists ix_helpdesk_assignment_queue_retry
on public.helpdesk_assignment_queue(workspace_id,last_attempt_at,queued_at)
where status='waiting';

-- Queue retries are internal state. Do not UPDATE helpdesk_tickets on every failed
-- assignment attempt, because that advances updated_at and broadcasts a ticket
-- change even though nothing visible to the user changed.
create or replace function private.queue_helpdesk_assignment(
  p_ticket uuid,
  p_reason text,
  p_suggested uuid default null
)
returns void
language plpgsql
security definer
set search_path=public,pg_temp
as $$
declare
  v_workspace uuid;
  v_reason text:=left(coalesce(p_reason,'Pendiente de asignación automática'),1000);
begin
  select workspace_id into v_workspace
  from public.helpdesk_tickets
  where id=p_ticket;

  if v_workspace is null then return; end if;

  insert into public.helpdesk_assignment_queue(
    workspace_id,helpdesk_ticket_id,status,suggested_user_id,reason,
    attempts,queued_at,last_attempt_at,updated_at
  )
  values(
    v_workspace,p_ticket,'waiting',p_suggested,v_reason,
    1,now(),now(),now()
  )
  on conflict(helpdesk_ticket_id) do update set
    status='waiting',
    suggested_user_id=excluded.suggested_user_id,
    reason=excluded.reason,
    attempts=public.helpdesk_assignment_queue.attempts+1,
    last_attempt_at=now(),
    updated_at=now();

  -- Visible ticket state changes only the first time it enters the queue or when
  -- the reason actually changes. Repeated capacity retries stay queue-only.
  perform set_config('app.helpdesk_assignment_action','1',true);
  update public.helpdesk_tickets
  set assignment_source='queue',
      assignment_reason=v_reason,
      assignment_queued_at=coalesce(assignment_queued_at,now()),
      assignment_last_routed_at=now()
  where id=p_ticket
    and assigned_to is null
    and (
      assignment_source is distinct from 'queue'
      or assignment_reason is distinct from v_reason
      or assignment_queued_at is null
    );
end
$$;
revoke all on function private.queue_helpdesk_assignment(uuid,text,uuid) from public,anon,authenticated;

-- One drainer globally, SKIP LOCKED for safety, and retry backoff so tickets with
-- no current capacity do not cause a write/broadcast storm every minute.
create or replace function private.process_helpdesk_assignment_queue_impl(p_workspace uuid default null)
returns jsonb
language plpgsql
security definer
set search_path=public,private,pg_temp
as $$
declare
  r record;
  result jsonb;
  processed int:=0;
  assigned int:=0;
  deferred int:=0;
  caller uuid:=(select auth.uid());
  internal_call boolean:=coalesce(current_setting('app.helpdesk_internal_queue',true),'')='1';
begin
  if caller is not null and not internal_call and p_workspace is not null
     and not private.has_workspace_permission(p_workspace,'manage_helpdesk')
     and not private.has_workspace_permission(p_workspace,'manage_staff') then
    raise exception 'Insufficient Helpdesk permissions';
  end if;

  if not pg_try_advisory_xact_lock(17292120261120::bigint) then
    return jsonb_build_object('processed',0,'assigned',0,'deferred',0,'skipped','locked');
  end if;

  if coalesce(current_setting('app.helpdesk_queue_draining',true),'')='1' then
    return jsonb_build_object('processed',0,'assigned',0,'deferred',0,'skipped','already_draining');
  end if;
  perform set_config('app.helpdesk_queue_draining','1',true);

  -- Retire stale queue rows without touching helpdesk_tickets. This prevents old
  -- closed/proposal/manually-assigned records from being reconsidered forever.
  update public.helpdesk_assignment_queue q
  set status=case when h.assigned_to is not null then 'assigned' else 'cancelled' end,
      assigned_user_id=case when h.assigned_to is not null then h.assigned_to else q.assigned_user_id end,
      assigned_at=case when h.assigned_to is not null then coalesce(q.assigned_at,now()) else q.assigned_at end,
      reason=case
        when h.assigned_to is not null then 'Solicitud ya asignada; cola finalizada.'
        when h.status='closed' then 'Solicitud cerrada; autoasignación cancelada.'
        else 'Tipo de solicitud no autoasignable; cola cancelada.'
      end,
      updated_at=now()
  from public.helpdesk_tickets h
  where h.id=q.helpdesk_ticket_id
    and q.status='waiting'
    and (p_workspace is null or q.workspace_id=p_workspace)
    and (h.status='closed' or h.assigned_to is not null or h.category in ('module','feature','new_requirement'));

  for r in
    select q.helpdesk_ticket_id
    from public.helpdesk_assignment_queue q
    join public.helpdesk_tickets h on h.id=q.helpdesk_ticket_id
    where q.status='waiting'
      and (p_workspace is null or q.workspace_id=p_workspace)
      and h.assigned_to is null
      and h.status<>'closed'
      and (
        q.last_attempt_at is null
        or q.last_attempt_at <= now() - case
          when coalesce(q.attempts,0) < 2 then interval '30 seconds'
          when coalesce(q.attempts,0) < 5 then interval '2 minutes'
          else interval '5 minutes'
        end
      )
    order by coalesce(q.last_attempt_at,q.queued_at),q.queued_at
    limit 20
    for update of q skip locked
  loop
    processed:=processed+1;
    result:=private.route_helpdesk_ticket_rules(r.helpdesk_ticket_id);
    if coalesce((result->>'assigned')::boolean,false) then
      assigned:=assigned+1;
    elsif coalesce((result->>'queued')::boolean,false) then
      deferred:=deferred+1;
    else
      -- Defensive backoff for non-queue outcomes (for example auto assignment
      -- disabled while a historical row is still waiting).
      update public.helpdesk_assignment_queue
      set status=case when coalesce(result->>'reason','') in ('auto_assignment_disabled','proposal') then 'cancelled' else status end,
          reason=left(coalesce(result->>'reason',reason,'Pendiente de reintento'),1000),
          attempts=attempts+1,
          last_attempt_at=now(),
          updated_at=now()
      where helpdesk_ticket_id=r.helpdesk_ticket_id and status='waiting';
      deferred:=deferred+1;
    end if;
  end loop;

  return jsonb_build_object(
    'processed',processed,
    'assigned',assigned,
    'deferred',deferred
  );
end
$$;
revoke all on function private.process_helpdesk_assignment_queue_impl(uuid) from public,anon,authenticated;

-- Make incremental upgrades deterministic as well: older installations may still
-- have a cron job calling the public wrapper with NULL. The internal cron path is
-- intentionally the only path allowed to drain all workspaces.
select cron.unschedule(jobid)
from cron.job
where jobname='jira-helpdesk-assignment-queue';
select cron.schedule(
  'jira-helpdesk-assignment-queue',
  '* * * * *',
  'select private.process_helpdesk_assignment_queue_impl(null);'
);

-- Public/manual entry point: keep the private implementation private. SECURITY
-- DEFINER is safe here because the authenticated caller and workspace permission
-- are explicitly checked before calling the private function.
create or replace function public.process_helpdesk_assignment_queue(p_workspace uuid default null)
returns jsonb
language plpgsql
security definer
set search_path=public,private,pg_temp
as $$
declare
  v_uid uuid:=(select auth.uid());
begin
  if v_uid is null then
    raise exception 'Authentication required';
  end if;
  if p_workspace is null then
    raise exception 'workspace_id is required';
  end if;
  if not private.is_workspace_member(p_workspace) then
    raise exception 'Workspace access required';
  end if;
  if not private.has_workspace_permission(p_workspace,'manage_helpdesk')
     and not private.has_workspace_permission(p_workspace,'manage_staff') then
    raise exception 'Insufficient Helpdesk permissions';
  end if;

  perform set_config('app.helpdesk_internal_queue','1',true);
  return private.process_helpdesk_assignment_queue_impl(p_workspace);
end
$$;
revoke all on function public.process_helpdesk_assignment_queue(uuid) from public,anon;
grant execute on function public.process_helpdesk_assignment_queue(uuid) to authenticated;

-- Watermark remains RLS-aware and cheap, but now validates the argument explicitly.
create or replace function public.get_helpdesk_watermark(p_workspace uuid)
returns jsonb
language plpgsql
stable
set search_path to 'public','pg_temp'
as $$
declare
  v_uid uuid := (select auth.uid());
  v_total bigint := 0;
  v_max_updated timestamptz;
begin
  if v_uid is null then raise exception 'Authentication required'; end if;
  if p_workspace is null then raise exception 'workspace_id is required'; end if;
  if not private.is_workspace_member(p_workspace) then raise exception 'Workspace access required'; end if;

  select count(*),max(updated_at)
  into v_total,v_max_updated
  from public.helpdesk_tickets
  where workspace_id=p_workspace;

  return jsonb_build_object(
    'total',v_total,
    'max_updated_at',v_max_updated,
    'generated_at',clock_timestamp()
  );
end
$$;
revoke all on function public.get_helpdesk_watermark(uuid) from public,anon;
grant execute on function public.get_helpdesk_watermark(uuid) to authenticated;

-- Keep planner statistics current after the new partial index is created.
analyze public.helpdesk_assignment_queue;
analyze public.helpdesk_tickets;
