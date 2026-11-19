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

function targetUrl(n:any){
  const m=n?.metadata||{},entity=m.entity_type,id=m.entity_id;
  if(n?.ticket_id||entity==="ticket")return APP+`?view=board&ticket=${encodeURIComponent(String(n.ticket_id||id||""))}`;
  if(n?.helpdesk_ticket_id||entity==="helpdesk")return APP+`?view=helpdesk&helpdesk=${encodeURIComponent(String(n.helpdesk_ticket_id||id||""))}`;
  if(entity==="sprint")return APP+`?view=backlog&sprint=${encodeURIComponent(String(id||""))}`;
  if(entity==="knowledge")return APP+"?view=knowledge";
  if(entity==="vacation")return APP+"?view=vacations";
  if(entity==="staff")return APP+"?view=team";
  if(String(n?.type||"").includes("mention"))return APP+"?view=mentioned";
  return APP+"?view=overview";
}
function categoryIcon(category:string){return ({tickets:"ticket",helpdesk:"helpdesk",mentions:"mention",sprints:"sprint",knowledge:"knowledge",vacations:"vacation",staff:"staff"} as any)[category]||"system"}
function pushPayload(n:any,sub:any){
  const highValue=new Set(["ticket_created","assigned_dev","assigned_qa","ticket_closed","ticket_mention","helpdesk_new","helpdesk_assigned","helpdesk_closed","helpdesk_mention","helpdesk_requirement_decision","vacation_requested","vacation_approved","vacation_rejected"]);
  return {
    version:"17.29.5",notification_id:n.id??null,workspace_id:n.workspace_id,user_id:n.user_id,
    type:n.type||"system",category:n.category||"system",title:clean(n.title||"Jira Interno TROBBU",120),
    body:clean(n.body||"Tienes una actualización en Jira Interno.",260),url:targetUrl(n),
    icon:APP+"pwa-icon-192.png",badge:APP+"pwa-icon-192.png",tag:n.id?`jira-${n.id}`:`jira-test-${Date.now()}`,
    requireInteraction:highValue.has(String(n.type||"")),silent:sub?.sound_enabled===false,metadata:n.metadata||{},
    actions:[{action:"open",title:"Abrir Jira"},{action:"mark-read",title:"Marcar leída"}],
    visual:{kind:categoryIcon(String(n.category||"system"))},force_native:n?.metadata?.qa_preview===true
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
    if(n.id){const {data:done}=await admin.from("web_push_delivery_log").select("id,status").eq("notification_id",n.id).eq("subscription_id",sub.id).eq("status","sent").maybeSingle();if(done){results.push({subscription_id:sub.id,status:"duplicate_skipped"});continue}}
    const payload=pushPayload(n,sub);
    try{
      const subscriber=server.subscribe({endpoint:sub.endpoint,keys:{p256dh:sub.p256dh,auth:sub.auth_key}});
      await subscriber.pushTextMessage(JSON.stringify(payload),{});
      await admin.from("web_push_subscriptions").update({last_success_at:new Date().toISOString(),last_failure_at:null,failure_count:0,updated_at:new Date().toISOString()}).eq("id",sub.id);
      await admin.from("web_push_delivery_log").upsert({notification_id:n.id??null,subscription_id:sub.id,workspace_id:n.workspace_id,user_id:n.user_id,status:"sent",provider_status:201,error:null},{onConflict:"notification_id,subscription_id",ignoreDuplicates:n.id?true:false});
      results.push({subscription_id:sub.id,status:"sent"});
    }catch(error:any){
      const gone=error instanceof webpush.PushMessageError?error.isGone():false;
      const status=Number(error?.response?.status||error?.status||error?.statusCode||0)||null;
      const message=clean(error?.message||String(error),480);
      await admin.from("web_push_subscriptions").update({last_failure_at:new Date().toISOString(),failure_count:Number(sub.failure_count||0)+1,disabled_at:gone?new Date().toISOString():null,updated_at:new Date().toISOString()}).eq("id",sub.id);
      await admin.from("web_push_delivery_log").upsert({notification_id:n.id??null,subscription_id:sub.id,workspace_id:n.workspace_id,user_id:n.user_id,status:gone?"gone":"failed",provider_status:status,error:message},{onConflict:"notification_id,subscription_id",ignoreDuplicates:false});
      results.push({subscription_id:sub.id,status:gone?"gone":"failed",provider_status:status,error:message});
    }
  }
  return results;
}

Deno.serve(async(req:Request)=>{
  if(req.method==="OPTIONS")return new Response("ok",{headers:cors});
  try{
    const body=await req.json().catch(()=>({}));
    const admin=createClient(Deno.env.get("SUPABASE_URL")!,Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,{auth:{autoRefreshToken:false,persistSession:false}});
    const auth=await authorize(admin,req,body);
    if(!auth.ok)return out({error:auth.error},auth.status);
    const action=String(body.action||"dispatch");
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
