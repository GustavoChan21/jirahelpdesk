-- Jira Interno TROBBU v17.29.26
-- 10-file attachment pipeline + attachment query hardening + immediate Helpdesk revision acknowledgement.

begin;

-- Existing attachment rows remain fully compatible. These idempotent backfills keep
-- legacy metadata normalized in environments that skipped an older media migration.
update public.ticket_attachments
set original_size_bytes=size_bytes
where original_size_bytes is null and size_bytes is not null;

update public.sprint_attachments
set original_size_bytes=size_bytes
where original_size_bytes is null and size_bytes is not null;

update public.helpdesk_attachments
set original_size_bytes=size_bytes
where original_size_bytes is null and size_bytes is not null;

-- Detail screens group evidence by comment and creation time. Composite partial indexes
-- avoid extra sorting as comments accumulate more attachments.
create index if not exists ix_ticket_attachments_comment_created
  on public.ticket_attachments(comment_id,created_at)
  where comment_id is not null;
create index if not exists ix_sprint_attachments_comment_created
  on public.sprint_attachments(comment_id,created_at)
  where comment_id is not null;
create index if not exists ix_helpdesk_attachments_comment_created
  on public.helpdesk_attachments(comment_id,created_at)
  where comment_id is not null;

-- v17.29.25 had two identical ticket_id/created_at indexes. Keep the established
-- idx_* index and remove the redundant ix_* copy to reduce write amplification.
drop index if exists public.ix_ticket_attachments_ticket_created;

-- Return the monotonic Helpdesk revision produced by the same transaction. The client
-- can commit ticket + counters immediately instead of waiting for a later Broadcast.
create or replace function public.mutate_helpdesk_workflow(
  p_ticket_id uuid,
  p_comment text default null,
  p_assignee uuid default null,
  p_status text default null
)
returns jsonb
language plpgsql
security definer
set search_path=public,private,pg_temp
as $function$
declare
  v_caller uuid:=(select auth.uid());
  v_ticket public.helpdesk_tickets%rowtype;
  v_after public.helpdesk_tickets%rowtype;
  v_comment_row public.helpdesk_comments%rowtype;
  v_comment text:=nullif(btrim(coalesce(p_comment,'')),'');
  v_target_assignee uuid;
  v_target_status text;
  v_manager boolean:=false;
  v_assignee boolean:=false;
  v_requester boolean:=false;
  v_assignment_changed boolean:=false;
  v_status_changed boolean:=false;
  v_from_rank integer;
  v_to_rank integer;
  v_revision bigint:=0;
begin
  if v_caller is null then raise exception 'Authentication required'; end if;
  if p_ticket_id is null then raise exception 'ticket_id is required'; end if;

  select * into v_ticket
  from public.helpdesk_tickets
  where id=p_ticket_id
  for update;

  if not found then raise exception 'Helpdesk ticket not found'; end if;
  if v_ticket.category in ('module','feature','new_requirement') then
    raise exception 'Requirement proposals are handled through the decision flow';
  end if;
  if not private.is_workspace_member(v_ticket.workspace_id) then
    raise exception 'Workspace access required';
  end if;

  v_manager:=private.has_workspace_permission(v_ticket.workspace_id,'manage_helpdesk');
  v_assignee:=v_ticket.assigned_to is not distinct from v_caller and v_ticket.assigned_to is not null;
  v_requester:=v_ticket.requester_user_id is not distinct from v_caller and v_ticket.requester_user_id is not null;
  if not (v_manager or v_assignee or v_requester) then
    raise exception 'You cannot update this Helpdesk request';
  end if;

  if v_comment is not null and char_length(v_comment)>4000 then
    raise exception 'El comentario no puede exceder 4000 caracteres.';
  end if;

  v_target_assignee:=coalesce(p_assignee,v_ticket.assigned_to);
  v_target_status:=coalesce(nullif(btrim(coalesce(p_status,'')),''),v_ticket.status);
  if v_target_status not in ('created','review','attended','closed') then
    raise exception 'Estado Helpdesk inválido.';
  end if;

  v_assignment_changed:=v_target_assignee is distinct from v_ticket.assigned_to;
  v_status_changed:=v_target_status is distinct from v_ticket.status;

  if v_assignment_changed then
    if not (v_manager or v_assignee) then
      raise exception 'No tienes permiso para reasignar esta solicitud.';
    end if;
    if v_target_assignee is null or not private.helpdesk_member_routable(v_ticket.workspace_id,v_target_assignee) then
      raise exception 'El responsable seleccionado no es un integrante activo disponible para Helpdesk.';
    end if;
  end if;

  v_from_rank:=case v_ticket.status when 'created' then 0 when 'review' then 1 when 'attended' then 2 when 'closed' then 3 else -1 end;
  v_to_rank:=case v_target_status when 'created' then 0 when 'review' then 1 when 'attended' then 2 when 'closed' then 3 else -1 end;

  if v_status_changed then
    if v_to_rank < v_from_rank then
      raise exception 'El estado no puede retroceder desde este flujo.';
    end if;
    if v_requester and not v_manager and not v_assignee then
      if not (v_ticket.status='attended' and v_target_status='closed') then
        raise exception 'El solicitante solo puede cerrar una solicitud atendida.';
      end if;
    elsif v_assignee and not v_manager then
      if v_to_rank <> v_from_rank+1 or v_target_status='closed' then
        raise exception 'El responsable debe avanzar secuencialmente: Nuevo → En revisión → Atendido.';
      end if;
    elsif not v_manager then
      raise exception 'No tienes permiso para cambiar el estado.';
    end if;
  end if;

  if v_comment is null and not v_assignment_changed and not v_status_changed then
    raise exception 'No hay cambios para guardar.';
  end if;

  perform set_config('app.helpdesk_skip_detail_touch','1',true);
  v_after:=v_ticket;

  if v_assignment_changed or v_status_changed then
    perform set_config('app.helpdesk_assignment_action','1',true);
    if v_assignment_changed then
      perform set_config('app.helpdesk_assignment_source',case when v_assignee and not v_manager then 'redirect' else 'manual' end,true);
    end if;

    update public.helpdesk_tickets h
    set assigned_to=v_target_assignee,
        status=v_target_status,
        assignment_source=case when v_assignment_changed then case when v_assignee and not v_manager then 'redirect' else 'manual' end else h.assignment_source end,
        assignment_reason=case when v_assignment_changed then coalesce(v_comment,case when v_assignee and not v_manager then 'Redirigido por el responsable anterior.' else h.assignment_reason end) else h.assignment_reason end,
        assignment_confidence=case when v_assignment_changed then null else h.assignment_confidence end,
        assignment_queued_at=case when v_assignment_changed then null else h.assignment_queued_at end,
        assignment_last_routed_at=case when v_assignment_changed then clock_timestamp() else h.assignment_last_routed_at end,
        updated_at=clock_timestamp()
    where h.id=p_ticket_id
    returning h.* into v_after;
  elsif v_comment is not null then
    update public.helpdesk_tickets h
    set updated_at=clock_timestamp()
    where h.id=p_ticket_id
    returning h.* into v_after;
  end if;

  if v_comment is not null then
    insert into public.helpdesk_comments(helpdesk_ticket_id,author_id,body)
    values(p_ticket_id,v_caller,v_comment)
    returning * into v_comment_row;
  end if;

  select coalesce(s.revision,0) into v_revision
  from public.helpdesk_live_state s
  where s.workspace_id=v_ticket.workspace_id;

  return jsonb_build_object(
    'ticket',to_jsonb(v_after),
    'comment',case when v_comment is null then 'null'::jsonb else to_jsonb(v_comment_row) end,
    'assignment_changed',v_assignment_changed,
    'status_changed',v_status_changed,
    'revision',coalesce(v_revision,0)
  );
end
$function$;

revoke all on function public.mutate_helpdesk_workflow(uuid,text,uuid,text) from public,anon;
grant execute on function public.mutate_helpdesk_workflow(uuid,text,uuid,text) to authenticated;

analyze public.ticket_attachments;
analyze public.sprint_attachments;
analyze public.helpdesk_attachments;
analyze public.helpdesk_tickets;
notify pgrst,'reload schema';

commit;
