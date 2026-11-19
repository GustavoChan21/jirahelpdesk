-- Jira Interno TROBBU v17.28.0
-- Helpdesk monotonic state + terminal proposal decisions.

create or replace function private.guard_helpdesk_requester_update()
returns trigger language plpgsql security definer set search_path to 'public','pg_temp' as $$
declare
  v_actor uuid:=(select auth.uid());
  v_assignment_context boolean:=coalesce(current_setting('app.helpdesk_assignment_action',true),'')='1';
  v_decision_context boolean:=coalesce(current_setting('app.helpdesk_requirement_decision',true),'')='1';
  v_requester boolean:=old.requester_user_id is not distinct from v_actor;
  v_assignee boolean:=old.assigned_to is not distinct from v_actor;
  v_internal_changed boolean;
begin
  if v_assignment_context or v_decision_context then return new; end if;
  if private.has_workspace_permission(old.workspace_id,'manage_helpdesk') then return new; end if;
  v_internal_changed := row(new.workspace_id,new.requester_user_id,new.assigned_to,new.due_at,new.first_response_at,new.reviewed_at,new.attended_at,new.resolved_at,new.closed_at)
    is distinct from row(old.workspace_id,old.requester_user_id,old.assigned_to,old.due_at,old.first_response_at,old.reviewed_at,old.attended_at,old.resolved_at,old.closed_at);
  if v_requester then
    if new.status is distinct from old.status and not (old.status='attended' and new.status='closed') then raise exception 'The requester can only close an attended Helpdesk ticket'; end if;
    if v_internal_changed then raise exception 'Requesters cannot change internal Helpdesk handling fields'; end if;
    return new;
  end if;
  if v_assignee then
    if v_internal_changed then raise exception 'Assigned users can only advance the Helpdesk status'; end if;
    if new.status is not distinct from old.status then return new; end if;
    if not ((old.status='created' and new.status='review') or (old.status='review' and new.status='attended')) then raise exception 'Assigned users must follow Nuevo -> En revisión -> Atendido'; end if;
    return new;
  end if;
  raise exception 'You cannot update this Helpdesk request';
end $$;

create or replace function private.guard_helpdesk_requirement()
returns trigger language plpgsql security definer set search_path to 'public','pg_temp' as $$
declare
  v_decision_context text:=coalesce(current_setting('app.helpdesk_requirement_decision',true),'');
  v_old_proposal boolean:=old.category in ('module','feature','new_requirement');
  v_new_proposal boolean:=new.category in ('module','feature','new_requirement');
begin
  if v_old_proposal then
    if new.category is distinct from old.category then raise exception 'A product proposal cannot change category after creation'; end if;
    if row(new.status,new.assigned_to,new.due_at) is distinct from row(old.status,old.assigned_to,old.due_at) then
      if not (v_decision_context='1' and new.status='closed' and new.assigned_to is not distinct from old.assigned_to and new.due_at is not distinct from old.due_at) then raise exception 'Product proposals do not use the operational Helpdesk status/SLA workflow'; end if;
    end if;
    if row(new.proposal_status,new.decision_by,new.decision_at,new.decision_note,new.converted_ticket_id,new.converted_ticket_key)
       is distinct from row(old.proposal_status,old.decision_by,old.decision_at,old.decision_note,old.converted_ticket_id,old.converted_ticket_key)
       and v_decision_context<>'1' then raise exception 'Use the requirement decision action to accept or reject this proposal'; end if;
  elsif v_new_proposal then
    raise exception 'Create a product proposal as a new request instead of changing an existing Helpdesk ticket';
  end if;
  return new;
end $$;

create or replace function public.get_live_counters(p_workspace uuid)
returns jsonb language plpgsql stable set search_path to 'public','pg_temp' as $$
declare v_uid uuid:=(select auth.uid()); v_navigation jsonb; v_modules jsonb:='[]'::jsonb; v_helpdesk jsonb;
begin
  if v_uid is null then raise exception 'Authentication required';end if;
  if not private.is_workspace_member(p_workspace) then raise exception 'Workspace access required';end if;
  select jsonb_build_object('tickets',(select count(*) from public.tickets t where t.workspace_id=p_workspace),'backlog',(select count(*) from public.tickets t where t.workspace_id=p_workspace and t.sprint_id is null and t.status<>'closed'),'knowledge',(select count(*) from public.knowledge_articles k where k.workspace_id=p_workspace),'helpdesk',(select count(*) from public.helpdesk_tickets h where h.workspace_id=p_workspace),'mytasks',(select count(*) from public.tickets t where t.workspace_id=p_workspace and (t.reporter_id=v_uid or t.dev_owner_id=v_uid or t.qa_owner_id=v_uid)),'notifications_unread',(select count(*) from public.notifications n where n.workspace_id=p_workspace and n.user_id=v_uid and n.read_at is null),'products',coalesce((select jsonb_object_agg(x.product_id::text,x.cnt) from (select t.product_id,count(*)::bigint cnt from public.tickets t where t.workspace_id=p_workspace group by t.product_id)x),'{}'::jsonb)) into v_navigation;
  select coalesce(jsonb_agg(jsonb_build_object('module_id',q.module_id,'ticket_count',q.ticket_count,'activity_count',q.activity_count,'article_count',q.article_count) order by q.name),'[]'::jsonb) into v_modules from (select m.id module_id,m.name,(select count(*) from public.tickets t where t.workspace_id=p_workspace and t.module_id=m.id) ticket_count,(select count(*) from public.ticket_activity a join public.tickets t on t.id=a.ticket_id where t.workspace_id=p_workspace and t.module_id=m.id) activity_count,(select count(*) from public.knowledge_articles k where k.workspace_id=p_workspace and k.module_id=m.id) article_count from public.ticket_modules m where m.workspace_id=p_workspace) q;
  select jsonb_build_object('total',count(*),'created',count(*) filter(where h.category not in ('module','feature','new_requirement') and h.status='created'),'review',count(*) filter(where h.category not in ('module','feature','new_requirement') and h.status='review'),'attended',count(*) filter(where h.category not in ('module','feature','new_requirement') and h.status='attended'),'closed',count(*) filter(where h.category not in ('module','feature','new_requirement') and h.status='closed'),'pending_requirements',count(*) filter(where h.category in ('module','feature','new_requirement') and coalesce(h.proposal_status,'pending')='pending'),'approved_requirements',count(*) filter(where h.category in ('module','feature','new_requirement') and h.proposal_status='accepted_backlog'),'rejected_requirements',count(*) filter(where h.category in ('module','feature','new_requirement') and h.proposal_status='rejected'),'overdue',count(*) filter(where h.category not in ('module','feature','new_requirement') and h.status<>'closed' and h.due_at is not null and h.due_at<now())) into v_helpdesk from public.helpdesk_tickets h where h.workspace_id=p_workspace;
  return jsonb_build_object('navigation',v_navigation,'modules',v_modules,'helpdesk',v_helpdesk,'generated_at',now());
end $$;

create or replace function public.decide_helpdesk_requirement(p_helpdesk_id uuid,p_decision text,p_product_id uuid default null::uuid,p_note text default null::text)
returns jsonb language plpgsql set search_path to 'public','pg_temp' as $$
declare v_req public.helpdesk_tickets%rowtype; v_ticket_id uuid; v_ticket_key text; v_title text; v_product_id uuid;
begin
  select * into v_req from public.helpdesk_tickets where id=p_helpdesk_id for update;
  if not found then raise exception 'Solicitud no encontrada'; end if;
  if v_req.category not in ('module','feature','new_requirement') then raise exception 'La solicitud no es una propuesta de producto'; end if;
  if coalesce(v_req.proposal_status,'pending')<>'pending' then raise exception 'Este requerimiento ya fue evaluado'; end if;
  if not private.has_workspace_permission(v_req.workspace_id,'manage_sprints') then raise exception 'Solo PM, Admin, Superadmin o un rol con permiso de planeación puede evaluar nuevos requerimientos'; end if;
  if p_decision not in ('accepted_backlog','rejected') then raise exception 'Decisión inválida'; end if;
  if p_decision='accepted_backlog' then
    v_product_id:=coalesce(p_product_id,v_req.product_id);
    if v_product_id is null then raise exception 'Selecciona el producto al que se enviará el requerimiento'; end if;
    if not exists(select 1 from public.products p where p.id=v_product_id and p.workspace_id=v_req.workspace_id) then raise exception 'El producto no pertenece a este workspace'; end if;
    if not private.has_product_access(v_req.workspace_id,v_product_id) then raise exception 'No tienes acceso al producto seleccionado'; end if;
    v_title:=left(coalesce(nullif(trim(v_req.subject),''),'Nuevo requerimiento'),220);
    insert into public.tickets(workspace_id,product_id,title,description,type,priority,status,reporter_id,sprint_id,dev_owner_id,qa_owner_id,story_points,start_date,due_date)
    values(v_req.workspace_id,v_product_id,v_title,concat('Origen: ',coalesce(v_req.ticket_key,'Helpdesk'),E'\n','Tipo: ',coalesce(v_req.category,'new_requirement'),E'\n','Solicitante: ',coalesce(v_req.requester_name,v_req.requester_email,'—'),E'\n\n',coalesce(v_req.description,'Sin descripción.'),case when nullif(trim(coalesce(p_note,'')),'') is not null then E'\n\nDecisión PM/Admin:\n'||trim(p_note) else '' end),'improvement',v_req.priority,'backlog',auth.uid(),null,null,null,null,null,null)
    returning id,ticket_key into v_ticket_id,v_ticket_key;
  else
    if nullif(trim(coalesce(p_note,'')),'') is null then raise exception 'Indica el motivo para rechazar la sugerencia'; end if;
  end if;
  perform set_config('app.helpdesk_requirement_decision','1',true);
  update public.helpdesk_tickets set proposal_status=p_decision,status='closed',closed_at=coalesce(closed_at,now()),decision_by=auth.uid(),decision_at=now(),decision_note=nullif(trim(coalesce(p_note,'')),''),converted_ticket_id=v_ticket_id,converted_ticket_key=v_ticket_key,product_id=case when p_decision='accepted_backlog' then v_product_id else product_id end where id=p_helpdesk_id;
  perform private.record_helpdesk_requirement_decision(p_helpdesk_id,p_decision,v_ticket_id,v_ticket_key,p_note);
  return jsonb_build_object('ok',true,'decision',p_decision,'ticket_id',v_ticket_id,'ticket_key',v_ticket_key,'product_id',case when p_decision='accepted_backlog' then v_product_id else v_req.product_id end);
end $$;

select set_config('app.helpdesk_requirement_decision','1',true);
update public.helpdesk_tickets set status='closed',closed_at=coalesce(closed_at,decision_at,updated_at,now()) where category in ('module','feature','new_requirement') and proposal_status in ('accepted_backlog','rejected') and status<>'closed';
