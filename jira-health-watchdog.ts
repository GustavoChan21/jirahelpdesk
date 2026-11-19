import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2.119.0";

const cors={"Access-Control-Allow-Origin":"*","Access-Control-Allow-Headers":"authorization,x-client-info,apikey,content-type,x-notification-cron-token"};
const VERCEL_ORIGIN="https://jiratrobbu.vercel.app";
const GITHUB_ORIGIN="https://gustavochan21.github.io/jirahelpdesk";
const VERSION="17.29.8";
const out=(data:any,status=200)=>new Response(JSON.stringify(data),{status,headers:{...cors,"Content-Type":"application/json","Cache-Control":"no-store"}});
async function sha(v:string){const d=await crypto.subtle.digest("SHA-256",new TextEncoder().encode(v));return Array.from(new Uint8Array(d)).map(x=>x.toString(16).padStart(2,"0")).join("")}
async function requestText(url:string,timeout=7000){const started=Date.now(),controller=new AbortController(),timer=setTimeout(()=>controller.abort(),timeout);try{const r=await fetch(`${url}${url.includes('?')?'&':'?'}t=${Date.now()}`,{cache:"no-store",redirect:"follow",signal:controller.signal,headers:{"User-Agent":"Jira-TROBBU-Health/17.29.8"}});const text=await r.text();return{ok:r.ok,status:r.status,latency_ms:Date.now()-started,text,error:r.ok?null:`HTTP ${r.status}`}}catch(e){return{ok:false,status:null,latency_ms:Date.now()-started,text:"",error:e instanceof Error?e.message:String(e)}}finally{clearTimeout(timer)}}
async function probe(origin:string){const health=await requestText(`${origin}/health.json`);if(health.ok&&health.text.includes("Jira Interno TROBBU")){let manifest:any=null;try{manifest=JSON.parse(health.text)}catch{}const assets=Array.isArray(manifest?.criticalAssets)?manifest.criticalAssets.slice(0,8):[];if(assets.length){const checks=await Promise.all(assets.map((asset:string)=>requestText(`${origin}/${String(asset).replace(/^\/+/,"")}`,5000)));const failed=assets.filter((_:string,i:number)=>!checks[i]?.ok);const latency=health.latency_ms+Math.max(0,...checks.map((c:any)=>Number(c.latency_ms||0)));if(failed.length)return{ok:false,status:health.status,latency_ms:latency,error:`Missing critical assets: ${failed.join(", ")}`,mode:"health-assets",version_match:health.text.includes(VERSION),asset_failures:failed};return{ok:true,status:health.status,latency_ms:latency,error:null,mode:"health-assets",version_match:health.text.includes(VERSION),asset_failures:[]}}return{ok:true,status:health.status,latency_ms:health.latency_ms,error:null,mode:"health",version_match:health.text.includes(VERSION)}}const root=await requestText(`${origin}/`);const rootOk=root.ok&&(root.text.includes("Jira Interno")||root.text.includes("id=\"root\"")||root.text.includes("id='root'"));return{ok:rootOk,status:root.status,latency_ms:health.latency_ms+root.latency_ms,error:rootOk?null:(root.error||health.error||"Invalid health response"),mode:rootOk?"root-fallback":"unavailable",version_match:false}}

Deno.serve(async(req:Request)=>{
  if(req.method==="OPTIONS")return new Response("ok",{headers:cors});
  try{
    const body=await req.json().catch(()=>({})),workspaceId=String(body.workspace_id||"");
    if(!workspaceId)return out({error:"workspace_id is required"},400);
    const admin=createClient(Deno.env.get("SUPABASE_URL")!,Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,{auth:{autoRefreshToken:false,persistSession:false}});
    const {data:settings,error:settingsError}=await admin.from("workspace_settings").select("workspace_id,email_cron_token_hash").eq("workspace_id",workspaceId).maybeSingle();
    if(settingsError)throw settingsError;
    const token=req.headers.get("x-notification-cron-token")||"";
    if(!token||!settings?.email_cron_token_hash||(await sha(token))!==settings.email_cron_token_hash)return out({error:"Forbidden"},403);

    const dbStarted=Date.now();
    const {error:dbError}=await admin.from("workspaces").select("id").eq("id",workspaceId).maybeSingle();
    const db={ok:!dbError,latency_ms:Date.now()-dbStarted,error:dbError?.message||null};
    const [vercel,github]=await Promise.all([probe(VERCEL_ORIGIN),probe(GITHUB_ORIGIN)]);
    const {data:last}=await admin.from("system_health_checks").select("checked_at,status,recovery_action").eq("workspace_id",workspaceId).order("checked_at",{ascending:false}).limit(1).maybeSingle();
    let status=db.ok&&(vercel.ok||github.ok)?(vercel.ok?"healthy":"degraded"):"down";
    let recoveryAction:string|null=null,recoveryError:string|null=null;
    if(!vercel.ok){
      const hook=(Deno.env.get("VERCEL_DEPLOY_HOOK_URL")||"").trim();
      const lastRecovery=last?.recovery_action==="vercel_redeploy_triggered"?new Date(last.checked_at).getTime():0;
      const canRetry=!lastRecovery||Date.now()-lastRecovery>15*60*1000;
      if(hook&&canRetry){
        try{const r=await fetch(hook,{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({source:"jira-health-watchdog",workspace_id:workspaceId,version:VERSION})});if(!r.ok)throw new Error(`Deploy hook HTTP ${r.status}`);recoveryAction="vercel_redeploy_triggered"}catch(e){recoveryAction=github.ok?"github_fallback_available":"manual_intervention_required";recoveryError=e instanceof Error?e.message:String(e)}
      }else recoveryAction=github.ok?"github_fallback_available":"manual_intervention_required";
    }else if(last?.status&&last.status!=="healthy")recoveryAction="service_recovered";
    const {error:insertError}=await admin.from("system_health_checks").insert({workspace_id:workspaceId,status,version:VERSION,database_ok:db.ok,vercel_ok:vercel.ok,github_ok:github.ok,database_latency_ms:db.latency_ms,vercel_latency_ms:vercel.latency_ms,github_latency_ms:github.latency_ms,vercel_status:vercel.status,github_status:github.status,error:[db.error,vercel.error,github.error,recoveryError].filter(Boolean).join(" | ")||null,recovery_action:recoveryAction,metadata:{source:body.source||"manual"}});
    if(insertError)throw insertError;
    await admin.from("system_health_checks").delete().eq("workspace_id",workspaceId).lt("checked_at",new Date(Date.now()-14*86400000).toISOString());
    return out({ok:status!=="down",status,version:VERSION,database:db,vercel,github,recovery_action:recoveryAction});
  }catch(e){return out({error:e instanceof Error?e.message:String(e)},400)}
});
