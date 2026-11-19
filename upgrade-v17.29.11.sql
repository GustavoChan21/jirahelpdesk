-- Jira TROBBU v17.29.11
-- Ticket audit ownership (created_by / closed_by) + Web Push device receipts.

begin;

alter table public.tickets
  add column if not exists created_by uuid references auth.users(id),
  add column if not exists closed_by uuid references auth.users(id);

create index if not exists idx_tickets_created_by on public.tickets(created_by);
create index if not exists idx_tickets_closed_by on public.tickets(closed_by);

update public.tickets t
set created_by=coalesce(
  (
    select a.actor_id
    from public.ticket_activity a
    where a.ticket_id=t.id and a.action='created' and a.actor_id is not null
    order by a.created_at asc
    limit 1
  ),
  t.reporter_id
)
where t.created_by is null;

with closing as (
  select
    t.id,
    coalesce(
      (
        select a.actor_id
        from public.ticket_activity a
        where a.ticket_id=t.id
          and a.action='status_changed'
          and a.to_value='closed'
          and a.actor_id is not null
        order by a.created_at desc
        limit 1
      ),
      case
        when exists(
          select 1 from public.ticket_activity a
          where a.ticket_id=t.id and a.action='created' and a.to_value='closed'
        ) then coalesce(
          (
            select a.actor_id
            from public.ticket_activity a
            where a.ticket_id=t.id
              and a.action='created'
              and a.to_value='closed'
              and a.actor_id is not null
            order by a.created_at asc
            limit 1
          ),
          t.created_by,
          t.reporter_id
        )
        else null
      end
    ) as actor_id,
    coalesce(
      t.closed_at,
      (
        select a.created_at
        from public.ticket_activity a
        where a.ticket_id=t.id
          and (
            (a.action='status_changed' and a.to_value='closed')
            or (a.action='created' and a.to_value='closed')
          )
        order by a.created_at desc
        limit 1
      ),
      t.updated_at,
      t.created_at
    ) as closed_at
  from public.tickets t
  where t.status='closed'
)
update public.tickets t
set
  closed_by=coalesce(t.closed_by,c.actor_id,t.created_by,t.reporter_id),
  closed_at=coalesce(t.closed_at,c.closed_at)
from closing c
where c.id=t.id;

create or replace function private.stamp_ticket_audit_people()
returns trigger
language plpgsql
security definer
set search_path=''
as $function$
declare
  v_actor uuid:=auth.uid();
begin
  if tg_op='INSERT' then
    new.created_by:=coalesce(v_actor,new.created_by,new.reporter_id);
    if new.status='closed' then
      new.closed_by:=coalesce(v_actor,new.closed_by,new.created_by,new.reporter_id);
      new.closed_at:=coalesce(new.closed_at,clock_timestamp());
    else
      new.closed_by:=null;
    end if;
    return new;
  end if;

  new.created_by:=old.created_by;

  if old.status is distinct from new.status then
    if new.status='closed' then
      new.closed_by:=coalesce(v_actor,new.created_by,new.reporter_id,old.closed_by);
      new.closed_at:=coalesce(new.closed_at,clock_timestamp());
    elsif old.status='closed' then
      new.closed_by:=null;
      new.closed_at:=null;
    else
      new.closed_by:=old.closed_by;
    end if;
  else
    new.closed_by:=old.closed_by;
    if old.status='closed' then new.closed_at:=old.closed_at; end if;
  end if;

  return new;
end
$function$;

revoke all on function private.stamp_ticket_audit_people() from public,anon,authenticated;

drop trigger if exists trg_01_ticket_audit_people on public.tickets;
create trigger trg_01_ticket_audit_people
before insert or update on public.tickets
for each row execute function private.stamp_ticket_audit_people();

create or replace function private.log_ticket_created()
returns trigger
language plpgsql
security definer
set search_path='public','pg_temp'
as $function$
begin
  insert into public.ticket_activity(ticket_id,actor_id,action,to_value)
  values(new.id,coalesce((select auth.uid()),new.created_by,new.reporter_id),'created',new.status::text);
  return new;
end
$function$;

alter table public.web_push_delivery_log
  add column if not exists receipt_token_hash text,
  add column if not exists received_at timestamptz,
  add column if not exists displayed_at timestamptz,
  add column if not exists clicked_at timestamptz,
  add column if not exists display_error text;

alter table public.web_push_subscriptions
  add column if not exists last_received_at timestamptz,
  add column if not exists last_displayed_at timestamptz,
  add column if not exists last_clicked_at timestamptz;

alter table public.web_push_delivery_log
  drop constraint if exists web_push_delivery_log_status_check;
alter table public.web_push_delivery_log
  add constraint web_push_delivery_log_status_check
  check(status in ('queued','sent','failed','gone','skipped'));

commit;
