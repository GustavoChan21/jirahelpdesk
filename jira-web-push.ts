import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2.119.0";
import * as webpush from "jsr:@negrel/webpush@0.5.0";

const cors={
  "Access-Control-Allow-Origin":"*",
  "Access-Control-Allow-Headers":"authorization,x-client-info,apikey,content-type,x-notification-cron-token",
  "Access-Control-Allow-Methods":"POST,OPTIONS"
};
const APP="https://jiratrobbu.vercel.app/";
const out=(data:any,status=200)=>new Response(JSON.stringify(data),{status,headers:{...cors,"Content-Type":"application/json","Cache-Control":"no-store"}});
const clean=(v:any,n=220)=>{const s=String(v??"").replace(/\s+/g," ").trim();return s.length>n?s.slice(0,n-1)+"…":s};
async function sha(v:string){const d=await crypto.subtle.digest("SHA-256",new TextEncoder().encode(v));return Array.from(new Uint8Array(d)).map(x=>x.toString(16).padStart(2,"0")).join("")}

function appUrl(view:string,params:Record<string,any>={}){
  const url=new URL(APP);url.searchParams.set("view",view);
  for(const [key,value] of Object.entries(params)){if(value!==null&&value!==undefined&&String(value)!=="")url.searchParams.set(key,String(value))}
  return url.toString();
}
function targetUrl(n:any){
  const m=n?.metadata||{},type=String(n?.type||m.event_type||""),entity=String(m.entity_type||""),category=String(n?.category||m.category||"");
  const ticketId=n?.ticket_id||(entity==="ticket"?m.entity_id:null),helpdeskId=n?.helpdesk_ticket_id||(entity==="helpdesk"?m.entity_id:null);
  if(type==="helpdesk_requirement_decision"){if(helpdeskId)return appUrl("helpdesk",{helpdesk:helpdeskId});const converted=m.converted_ticket_id||n?.ticket_id;if(converted)return appUrl("board",{ticket:converted})}
  if(type==="ticket_sprint")return ticketId?appUrl("backlog",{ticket:ticketId}):appUrl("backlog",{sprint:m.sprint_id||null});
  if(ticketId)return appUrl(type==="ticket_mention"||category==="mentions"?"mentioned":"board",{ticket:ticketId});
  if(helpdeskId)return appUrl(type==="helpdesk_mention"||category==="mentions"?"mentioned":"helpdesk",{helpdesk:helpdeskId});
  const sprintId=entity==="sprint"?(m.sprint_id||m.entity_id):(type.startsWith("sprint_")?m.sprint_id:null);if(sprintId)return appUrl("backlog",{sprint:sprintId});
  const knowledgeId=entity==="knowledge"?(m.article_id||m.entity_id):(type.startsWith("knowledge_")?m.article_id:null);if(knowledgeId)return appUrl("knowledge",{knowledge:knowledgeId});
  const vacationId=entity==="vacation"?m.entity_id:(type.startsWith("vacation_")?m.entity_id:null);if(vacationId)return appUrl("vacations",{tab:type==="vacation_requested"?"requests":"mine",vacation:vacationId});
  const staffId=entity==="staff"?(m.member_user_id||m.entity_id):(type.startsWith("member_")?(m.member_user_id||m.entity_id):null);if(staffId)return appUrl("team",{tab:"staff",member:staffId});
  if(category==="mentions"||type.includes("mention"))return appUrl("mentioned");
  return appUrl("overview");
}
function categoryIcon(category:string){return ({tickets:"ticket",helpdesk:"helpdesk",mentions:"mention",sprints:"sprint",knowledge:"knowledge",vacations:"vacation",staff:"staff"} as any)[category]||"system"}
function subscriptionBrowser(sub:any){
  const label=String(sub?.device_label||"").split("·").slice(1).join("·").trim();
  if(label && !/Not:A-Brand|Navegador/i.test(label)) return label;
  const ua=String(sub?.user_agent||"");
  if(/Edg\//i.test(ua)) return "Microsoft Edge";
  if(/Chrome\//i.test(ua)) return "Google Chrome";
  if(/Firefox\//i.test(ua)) return "Firefox";
  if(/Safari\//i.test(ua)&&!/Chrome\//i.test(ua)) return "Safari";
  return label||"Navegador";
}
function pushPayload(n:any,sub:any,receipt:any=null){
  const highValue=new Set(["ticket_created","assigned_dev","assigned_qa","ticket_closed","ticket_mention","helpdesk_new","helpdesk_assigned","helpdesk_closed","helpdesk_mention","helpdesk_requirement_decision","vacation_requested","vacation_approved","vacation_rejected"]);
  return {
    version:"17.29.11",notification_id:n.id??null,workspace_id:n.workspace_id,user_id:n.user_id,ticket_id:n.ticket_id??null,helpdesk_ticket_id:n.helpdesk_ticket_id??null,
    type:n.type||"system",category:n.category||"system",title:clean(n.title||"Jira Interno TROBBU",120),
    body:clean(n.body||"Tienes una actualización en Jira Interno.",260),url:targetUrl(n),
    icon:APP+"pwa-icon-192.png",badge:APP+"pwa-icon-192.png",tag:n.id?`jira-${n.id}`:`jira-test-${Date.now()}`,
    requireInteraction:highValue.has(String(n.type||"")),silent:sub?.sound_enabled===false,metadata:n.metadata||{},
    platform:sub?.platform||null,device_label:sub?.device_label||null,browser:subscriptionBrowser(sub),
    actions:[{action:"open",title:"Abrir Jira"},{action:"mark-read",title:"Marcar leída"}],
    visual:{kind:categoryIcon(String(n.category||"system"))},force_native:n?.metadata?.qa_preview===true,delivery_id:receipt?.delivery_id??null,receipt_token:receipt?.receipt_token??null
  };
}

async function ensureVapid(admin:any){
  const {data:existing,error}=await admin.from("web_push_server_config").select("*").eq("id",1).maybeSingle();
  if(error)throw error;
  if(existing){
    const {data:pub}=await admin.from("web_push_public_config").select("vapid_public_key").eq("id",1).maybeSingle();
    if(!pub?.vapid_public_key)await admin.from("web_push_public_config").upsert({id:1,vapid_public_key:existing.vapid_public_key,enabled:true,updated_at:new Date().toISOString()});
    return existing;
  }
  const keys=await webpush.generateVapidKeys({extractable:true});
  const exported=await webpush.exportVapidKeys(keys);
  const publicKey=await webpush.exportApplicationServerKey(keys);
  const row={id:1,vapid_public_key:publicKey,vapid_public_jwk:exported.publicKey,vapid_private_jwk:exported.privateKey,vapid_subject:"mailto:helpdesk@trobbucollection.com",updated_at:new Date().toISOString()};
  const {error:insertError}=await admin.from("web_push_server_config").insert(row);
  if(insertError){const {data:race,error:raceError}=await admin.from("web_push_server_config").select("*").eq("id",1).single();if(raceError)throw insertError;return race}
  const {error:publicError}=await admin.from("web_push_public_config").upsert({id:1,vapid_public_key:publicKey,enabled:true,updated_at:new Date().toISOString()});
  if(publicError)throw publicError;
  return row;
}
async function applicationServer(admin:any){
  const cfg=await ensureVapid(admin);
  const vapidKeys=await webpush.importVapidKeys({publicKey:cfg.vapid_public_jwk,privateKey:cfg.vapid_private_jwk},{extractable:false});
  return {cfg,server:await webpush.ApplicationServer.new({contactInformation:cfg.vapid_subject,vapidKeys})};
}
async function authorize(admin:any,req:Request,body:any){
  const workspaceId=String(body.workspace_id||"");
  if(!workspaceId)throw new Error("workspace_id is required");
  const cron=req.headers.get("x-notification-cron-token")||"";
  if(cron){
    const {data:s,error}=await admin.from("workspace_settings").select("email_cron_token_hash").eq("workspace_id",workspaceId).maybeSingle();
    if(error)throw error;
    if(!s?.email_cron_token_hash||(await sha(cron))!==s.email_cron_token_hash)return {ok:false,status:403,error:"Forbidden"};
    return {ok:true,workspaceId,server:true,userId:null,role:"system"};
  }
  const token=(req.headers.get("Authorization")||"").replace(/^Bearer\s+/i,"");
  if(!token)return {ok:false,status:401,error:"Unauthorized"};
  const {data:u,error:userError}=await admin.auth.getUser(token);
  if(userError||!u.user)return {ok:false,status:401,error:"Invalid session"};
  const {data:wm,error:memberError}=await admin.from("workspace_members").select("active,role").eq("workspace_id",workspaceId).eq("user_id",u.user.id).maybeSingle();
  if(memberError)throw memberError;
  if(!wm?.active)return {ok:false,status:403,error:"Forbidden"};
  return {ok:true,workspaceId,server:false,userId:u.user.id,role:wm.role};
}
async function sendToUser(admin:any,server:any,n:any){
  const {data:subs,error}=await admin.from("web_push_subscriptions").select("*").eq("workspace_id",n.workspace_id).eq("user_id",n.user_id).is("disabled_at",null);
  if(error)throw error;
  const results:any[]=[];
  for(const sub of subs||[]){
    if(n.id){
      const {data:delivered}=await admin.from("web_push_delivery_log").select("id,status,received_at,displayed_at").eq("notification_id",n.id).eq("subscription_id",sub.id).eq("status","sent").maybeSingle();
      if(delivered){results.push({subscription_id:sub.id,status:"duplicate_skipped",received_at:delivered.received_at,displayed_at:delivered.displayed_at});continue}
    }
    const receiptToken=crypto.randomUUID().replaceAll("-","")+crypto.randomUUID().replaceAll("-","");
    const receiptHash=await sha(receiptToken);
    const {data:delivery,error:deliveryError}=await admin.from("web_push_delivery_log").upsert({notification_id:n.id??null,subscription_id:sub.id,workspace_id:n.workspace_id,user_id:n.user_id,status:"queued",provider_status:null,error:null,display_error:null,receipt_token_hash:receiptHash,received_at:null,displayed_at:null,clicked_at:null},{onConflict:"notification_id,subscription_id",ignoreDuplicates:false}).select("id").single();
    if(deliveryError)throw deliveryError;
    const payload=pushPayload(n,sub,{delivery_id:delivery.id,receipt_token:receiptToken});
    try{
      const subscriber=server.subscribe({endpoint:sub.endpoint,keys:{p256dh:sub.p256dh,auth:sub.auth_key}});
      await subscriber.pushTextMessage(JSON.stringify(payload),{});
      const now=new Date().toISOString();
      await admin.from("web_push_subscriptions").update({last_success_at:now,last_failure_at:null,failure_count:0,updated_at:now}).eq("id",sub.id);
      await admin.from("web_push_delivery_log").update({status:"sent",provider_status:201,error:null}).eq("id",delivery.id);
      results.push({subscription_id:sub.id,status:"sent",delivery_id:delivery.id});
    }catch(error:any){
      const gone=error instanceof webpush.PushMessageError?error.isGone():false;
      const status=Number(error?.response?.status||error?.status||error?.statusCode||0)||null;
      const message=clean(error?.message||String(error),480),now=new Date().toISOString();
      await admin.from("web_push_subscriptions").update({last_failure_at:now,failure_count:Number(sub.failure_count||0)+1,disabled_at:gone?now:null,updated_at:now}).eq("id",sub.id);
      await admin.from("web_push_delivery_log").update({status:gone?"gone":"failed",provider_status:status,error:message}).eq("id",delivery.id);
      results.push({subscription_id:sub.id,status:gone?"gone":"failed",provider_status:status,error:message,delivery_id:delivery.id});
    }
  }
  return results;
}

Deno.serve(async(req:Request)=>{
  if(req.method==="OPTIONS")return new Response("ok",{headers:cors});
  try{
    const body=await req.json().catch(()=>({}));
    const admin=createClient(Deno.env.get("SUPABASE_URL")!,Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,{auth:{autoRefreshToken:false,persistSession:false}});
    const action=String(body.action||"dispatch");
    if(action==="receipt"){
      const deliveryId=Number(body.delivery_id||0),token=String(body.receipt_token||""),stage=String(body.stage||"received");
      if(!deliveryId||!token)return out({error:"Invalid receipt"},400);
      const {data:delivery,error:re}=await admin.from("web_push_delivery_log").select("id,receipt_token_hash,subscription_id").eq("id",deliveryId).maybeSingle();
      if(re)throw re;
      if(!delivery||!delivery.receipt_token_hash||(await sha(token))!==delivery.receipt_token_hash)return out({error:"Invalid receipt token"},403);
      const now=new Date().toISOString(),patch:any={};
      if(stage==="received")patch.received_at=now;else if(stage==="displayed")patch.displayed_at=now;else if(stage==="clicked")patch.clicked_at=now;else if(stage==="display_error")patch.display_error=clean(body.error||"Display failed",480);else return out({error:"Invalid receipt stage"},400);
      const {error:updateDeliveryError}=await admin.from("web_push_delivery_log").update(patch).eq("id",deliveryId);if(updateDeliveryError)throw updateDeliveryError;
      if(delivery.subscription_id){const subPatch:any={updated_at:now};if(stage==="received")subPatch.last_received_at=now;if(stage==="displayed")subPatch.last_displayed_at=now;if(stage==="clicked")subPatch.last_clicked_at=now;await admin.from("web_push_subscriptions").update(subPatch).eq("id",delivery.subscription_id)}
      return out({ok:true,stage});
    }
    const auth=await authorize(admin,req,body);
    if(!auth.ok)return out({error:auth.error},auth.status);
    if(action==="config"){const cfg=await ensureVapid(admin);return out({ok:true,enabled:true,vapid_public_key:cfg.vapid_public_key})}
    if(action==="subscribe"){
      if(auth.server)return out({error:"User session required"},403);
      const sub=body.subscription||{},endpoint=String(sub.endpoint||"").trim(),p256dh=String(sub.p256dh||"").trim(),authKey=String(sub.auth_key||"").trim();
      if(!endpoint||!p256dh||!authKey)return out({error:"Invalid push subscription"},400);
      await admin.from("web_push_subscriptions").delete().eq("endpoint",endpoint).neq("user_id",auth.userId);
      const {error:upsertError}=await admin.from("web_push_subscriptions").upsert({workspace_id:auth.workspaceId,user_id:auth.userId,endpoint,p256dh,auth_key:authKey,expiration_time:sub.expiration_time??null,locale:sub.locale==="en"?"en":"es",user_agent:String(sub.user_agent||"").slice(0,1000)||null,platform:String(sub.platform||"").slice(0,200)||null,device_label:String(sub.device_label||"").slice(0,240)||null,sound_enabled:sub.sound_enabled!==false,disabled_at:null,updated_at:new Date().toISOString()},{onConflict:"workspace_id,user_id,endpoint"});
      if(upsertError)throw upsertError;
      return out({ok:true,subscribed:true});
    }
    if(action==="unsubscribe"){
      if(auth.server)return out({error:"User session required"},403);
      const endpoint=String(body.endpoint||"").trim();if(!endpoint)return out({ok:true,unsubscribed:false});
      const {error:deleteError}=await admin.from("web_push_subscriptions").delete().eq("user_id",auth.userId).eq("endpoint",endpoint);if(deleteError)throw deleteError;
      return out({ok:true,unsubscribed:true});
    }
    if(action==="sound"){
      if(auth.server)return out({error:"User session required"},403);
      const endpoint=String(body.endpoint||"").trim();if(!endpoint)return out({error:"endpoint is required"},400);
      const {error:updateError}=await admin.from("web_push_subscriptions").update({sound_enabled:body.sound_enabled!==false,locale:body.locale==="en"?"en":"es",updated_at:new Date().toISOString()}).eq("user_id",auth.userId).eq("endpoint",endpoint);if(updateError)throw updateError;
      return out({ok:true});
    }
    if(action==="diagnostic"){
      if(auth.server)return out({error:"User session required"},403);
      const {data:subs,error:se}=await admin.from("web_push_subscriptions").select("id,device_label,platform,sound_enabled,disabled_at,last_success_at,last_received_at,last_displayed_at,last_clicked_at,last_failure_at,failure_count,updated_at").eq("workspace_id",auth.workspaceId).eq("user_id",auth.userId).order("updated_at",{ascending:false}).limit(10);
      if(se)throw se;
      const {data:deliveries,error:de}=await admin.from("web_push_delivery_log").select("status,provider_status,error,display_error,created_at,received_at,displayed_at,clicked_at,subscription_id").eq("workspace_id",auth.workspaceId).eq("user_id",auth.userId).order("created_at",{ascending:false}).limit(10);
      if(de)throw de;
      const active=(subs||[]).filter((s:any)=>!s.disabled_at);
      return out({ok:true,active_subscriptions:active.length,subscriptions:subs||[],latest_delivery:(deliveries||[])[0]||null,recent_deliveries:deliveries||[]});
    }
    const {server}=await applicationServer(admin);
    if(action==="test"){
      if(auth.server||auth.role!=="superadmin")return out({error:"Superadmin required"},403);
      const sample={id:null,workspace_id:auth.workspaceId,user_id:auth.userId,type:String(body.type||"helpdesk_comment"),category:String(body.category||"helpdesk"),title:String(body.title||"Jira Interno TROBBU · QA"),body:String(body.message||"Prueba Web Push real de Jira Interno TROBBU."),metadata:{...(body.metadata&&typeof body.metadata==="object"?body.metadata:{}),entity_type:body.entity_type||body.metadata?.entity_type||null,entity_id:body.entity_id||body.metadata?.entity_id||null,qa_preview:true}};
      const results=await sendToUser(admin,server,sample);
      return out({ok:true,mode:"test",subscriptions:results.length,sent:results.filter(x=>x.status==="sent").length,results});
    }
    const notificationId=Number(body.notification_id||0);
    if(!auth.server||!notificationId)return out({error:"Server dispatch required"},403);
    const {data:n,error}=await admin.from("notifications").select("*").eq("id",notificationId).eq("workspace_id",auth.workspaceId).maybeSingle();
    if(error)throw error;
    if(!n)return out({ok:true,skipped:true,reason:"notification_not_found"});
    const results=await sendToUser(admin,server,n);
    return out({ok:true,notification_id:n.id,subscriptions:results.length,sent:results.filter(x=>x.status==="sent").length,results});
  }catch(error:any){return out({error:error?.message||String(error)},400)}
});
