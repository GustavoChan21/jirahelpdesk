-- Jira Interno TROBBU v17.29.2
-- Closed Helpdesk compatibility + comment notifications + legacy accepted-backlog normalization.

begin;

create or replace function private.notify_helpdesk_comment_created()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_req public.helpdesk_tickets%rowtype;
  v_user uuid;
  v_email_user uuid;
  v_direction text;
  v_author_name text;
  v_author_email text;
begin
  select * into v_req from public.helpdesk_tickets where id=new.helpdesk_ticket_id;
  if not found then return new; end if;

  select coalesce(nullif(new.author_name,''),p.full_name,'Usuario'),
         coalesce(nullif(new.author_email,''),p.email)
  into v_author_name,v_author_email
  from public.profiles p
  where p.id=new.author_id;

  v_author_name:=coalesce(v_author_name,nullif(new.author_name,''),'Usuario');
  v_author_email:=coalesce(v_author_email,nullif(new.author_email,''));

  if new.author_id is not distinct from v_req.requester_user_id then
    v_direction:='requester_to_team';
    v_email_user:=v_req.assigned_to;
    if v_email_user is null then
      select wm.user_id into v_email_user
      from public.workspace_members wm
      where wm.workspace_id=v_req.workspace_id
        and wm.active=true
        and private.member_has_permission(v_req.workspace_id,wm.user_id,'manage_helpdesk')
        and wm.user_id is distinct from new.author_id
      order by wm.joined_at nulls last,wm.user_id
      limit 1;
    end if;
  else
    v_direction:='team_to_requester';
    v_email_user:=v_req.requester_user_id;
  end if;

  for v_user in
    select distinct x.user_id from (
      select v_req.requester_user_id user_id
      union select v_req.assigned_to
      union select wm.user_id
      from public.workspace_members wm
      where wm.workspace_id=v_req.workspace_id
        and wm.active=true
        and private.member_has_permission(v_req.workspace_id,wm.user_id,'manage_helpdesk')
    ) x
    where x.user_id is not null and x.user_id is distinct from new.author_id
  loop
    perform private.emit_notification(
      v_req.workspace_id,v_user,'helpdesk_comment','helpdesk',
      v_req.ticket_key||' · nuevo comentario',left(coalesce(new.body,'Nuevo comentario'),180),
      jsonb_build_object(
        'entity_type','helpdesk','entity_id',v_req.id,'helpdesk_key',v_req.ticket_key,
        'subject',v_req.subject,'action','comment','comment_id',new.id,
        'comment_preview',left(coalesce(new.body,''),360),'comment_direction',v_direction,
        'comment_author_name',v_author_name,'comment_author_email',v_author_email,
        'requester_user_id',v_req.requester_user_id,'assigned_to',v_req.assigned_to
      ),
      new.author_id,null,v_req.id,
      'helpdesk:'||v_req.id||':comment:'||new.id||':'||v_user,
      v_user is not distinct from v_email_user
    );
  end loop;
  return new;
end
$function$;

revoke all on function private.notify_helpdesk_comment_created() from public,anon,authenticated;

create or replace function private.validate_helpdesk_product()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
begin
  if new.product_id is not null and not exists(
    select 1 from public.products p
    where p.id=new.product_id and p.workspace_id=new.workspace_id
  ) then
    raise exception 'El producto seleccionado no pertenece a este workspace';
  end if;

  if tg_op='UPDATE'
     and coalesce(old.proposal_status,'pending')<>'pending'
     and new.product_id is distinct from old.product_id
     and coalesce(current_setting('app.helpdesk_requirement_decision',true),'')<>'1'
  then
    raise exception 'El producto de un requerimiento ya evaluado no puede modificarse';
  end if;
  return new;
end
$function$;

revoke all on function private.validate_helpdesk_product() from public,anon,authenticated;

-- One-time normalization for legacy accepted requirements created before product_id
-- was persisted on the Helpdesk record. The target Backlog ticket is the source of truth.
select set_config('app.helpdesk_requirement_decision','1',true);
update public.helpdesk_tickets h
set product_id=t.product_id
from public.tickets t
where h.proposal_status='accepted_backlog'
  and h.converted_ticket_id=t.id
  and h.workspace_id=t.workspace_id
  and h.product_id is null
  and t.product_id is not null;

commit;
