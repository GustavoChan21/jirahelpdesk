-- Jira Interno TROBBU v17.25.0
-- Replace operational email with private Realtime device notifications.

-- 1) Email delivery is intentionally retired. Keep historical rows for audit only.
do $$
declare j record;
begin
  for j in select jobid from cron.job where jobname in ('jira-daily-email-reminder','jira-process-email-outbox')
  loop
    perform cron.unschedule(j.jobid);
  end loop;
end $$;

update public.workspace_settings
set email_notifications=false,
    email_daily_reminder_enabled=false
where email_notifications is distinct from false
   or email_daily_reminder_enabled is distinct from false;

update public.notification_outbox
set status='suppressed',
    suppressed_at=coalesce(suppressed_at,now()),
    suppressed_reason=coalesce(suppressed_reason,'email_channel_retired_v17_25'),
    processing_at=null,
    next_attempt_at=null
where status in ('pending','processing','failed');

-- 2) Private per-user Realtime Broadcast channel for notifications.
drop policy if exists jira_user_notification_broadcast_select on realtime.messages;
create policy jira_user_notification_broadcast_select
on realtime.messages
for select
to authenticated
using (
  realtime.messages.extension='broadcast'
  and (select realtime.topic()) = ('user:' || (select auth.uid())::text || ':notifications')
);

create or replace function private.broadcast_user_notification()
returns trigger
language plpgsql
security definer
set search_path=''
as $$
declare
  v_user uuid;
  v_row jsonb;
  v_event text;
begin
  if tg_op='DELETE' then
    v_user:=old.user_id;
    v_row:=to_jsonb(old);
    v_event:='notification_deleted';
  elsif tg_op='UPDATE' then
    v_user:=new.user_id;
    v_row:=to_jsonb(new);
    v_event:='notification_updated';
  else
    v_user:=new.user_id;
    v_row:=to_jsonb(new);
    v_event:='notification_created';
  end if;

  if v_user is not null then
    perform realtime.send(
      payload => v_row,
      event => v_event,
      topic => 'user:' || v_user::text || ':notifications',
      private => true
    );
  end if;

  if tg_op='DELETE' then return old; end if;
  return new;
end $$;

revoke all on function private.broadcast_user_notification() from public,anon,authenticated;

drop trigger if exists trg_notifications_realtime_broadcast on public.notifications;
create trigger trg_notifications_realtime_broadcast
after insert or update or delete on public.notifications
for each row execute function private.broadcast_user_notification();

-- Notifications no longer need Postgres Changes; Broadcast handles the personal stream.
do $$
begin
  if exists(
    select 1 from pg_publication_tables
    where pubname='supabase_realtime' and schemaname='public' and tablename='notifications'
  ) then
    alter publication supabase_realtime drop table public.notifications;
  end if;
end $$;

notify pgrst,'reload schema';
