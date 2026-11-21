-- Jira TROBBU v17.29.24
-- Helpdesk counter/realtime consistency hardening.
-- Adds an RLS-aware status digest to the existing watermark so clients can
-- detect missed/out-of-order Broadcasts even when total rows do not change.

begin;

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
  v_created bigint := 0;
  v_review bigint := 0;
  v_attended bigint := 0;
  v_closed bigint := 0;
  v_pending_requirements bigint := 0;
  v_approved_requirements bigint := 0;
  v_rejected_requirements bigint := 0;
  v_overdue bigint := 0;
begin
  if v_uid is null then raise exception 'Authentication required'; end if;
  if p_workspace is null then raise exception 'workspace_id is required'; end if;
  if not private.is_workspace_member(p_workspace) then raise exception 'Workspace access required'; end if;

  select
    count(*),
    max(updated_at),
    count(*) filter (
      where coalesce(category,'') not in ('module','feature','new_requirement') and status='created'
    ),
    count(*) filter (
      where coalesce(category,'') not in ('module','feature','new_requirement') and status='review'
    ),
    count(*) filter (
      where coalesce(category,'') not in ('module','feature','new_requirement') and status='attended'
    ),
    count(*) filter (
      where coalesce(category,'') not in ('module','feature','new_requirement') and status='closed'
    ),
    count(*) filter (
      where category in ('module','feature','new_requirement') and coalesce(proposal_status,'pending')='pending'
    ),
    count(*) filter (
      where category in ('module','feature','new_requirement') and proposal_status='accepted_backlog'
    ),
    count(*) filter (
      where category in ('module','feature','new_requirement') and proposal_status='rejected'
    ),
    count(*) filter (
      where coalesce(category,'') not in ('module','feature','new_requirement')
        and due_at is not null and status<>'closed' and due_at<now()
    )
  into
    v_total,v_max_updated,v_created,v_review,v_attended,v_closed,
    v_pending_requirements,v_approved_requirements,v_rejected_requirements,v_overdue
  from public.helpdesk_tickets
  where workspace_id=p_workspace;

  return jsonb_build_object(
    'total',v_total,
    'max_updated_at',v_max_updated,
    'created',v_created,
    'review',v_review,
    'attended',v_attended,
    'closed',v_closed,
    'pending_requirements',v_pending_requirements,
    'approved_requirements',v_approved_requirements,
    'rejected_requirements',v_rejected_requirements,
    'overdue',v_overdue,
    'generated_at',clock_timestamp()
  );
end
$function$;

revoke all on function public.get_helpdesk_watermark(uuid) from public,anon;
grant execute on function public.get_helpdesk_watermark(uuid) to authenticated;

analyze public.helpdesk_tickets;
notify pgrst,'reload schema';
commit;
