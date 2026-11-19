-- Jira Interno TROBBU v17.29.0
-- Atomic Helpdesk detail snapshot + comment persistence reliability.

begin;

create or replace function public.get_helpdesk_detail_v3(p_ticket uuid)
returns jsonb
language plpgsql
stable
security invoker
set search_path=public,pg_temp
as $$
declare
  v_ticket public.helpdesk_tickets%rowtype;
begin
  select * into v_ticket from public.helpdesk_tickets where id=p_ticket;
  if not found then raise exception 'La solicitud no está disponible o no tienes acceso.' using errcode='42501'; end if;
  return jsonb_build_object(
    'ticket',to_jsonb(v_ticket),
    'comments',coalesce((select jsonb_agg(to_jsonb(c) order by c.created_at,c.id) from public.helpdesk_comments c where c.helpdesk_ticket_id=p_ticket),'[]'::jsonb),
    'activity',coalesce((select jsonb_agg(to_jsonb(a) order by a.created_at desc,a.id desc) from public.helpdesk_activity a where a.helpdesk_ticket_id=p_ticket),'[]'::jsonb),
    'attachments',coalesce((select jsonb_agg(to_jsonb(x) order by x.created_at,x.id) from public.helpdesk_attachments x where x.helpdesk_ticket_id=p_ticket),'[]'::jsonb),
    'snapshot_at',clock_timestamp()
  );
end $$;
revoke all on function public.get_helpdesk_detail_v3(uuid) from public,anon;
grant execute on function public.get_helpdesk_detail_v3(uuid) to authenticated;

create or replace function private.touch_helpdesk_ticket_from_comment()
returns trigger
language plpgsql
security definer
set search_path=''
as $$
declare v_ticket uuid;
begin
  v_ticket:=case when tg_op='DELETE' then old.helpdesk_ticket_id else new.helpdesk_ticket_id end;
  update public.helpdesk_tickets set updated_at=clock_timestamp() where id=v_ticket;
  if tg_op='DELETE' then return old; end if;
  return new;
end $$;
revoke all on function private.touch_helpdesk_ticket_from_comment() from public,anon,authenticated;
drop trigger if exists trg_95_helpdesk_comment_touch_ticket on public.helpdesk_comments;
create trigger trg_95_helpdesk_comment_touch_ticket after insert or update or delete on public.helpdesk_comments for each row execute function private.touch_helpdesk_ticket_from_comment();

commit;
