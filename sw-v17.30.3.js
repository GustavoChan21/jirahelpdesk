const CACHE='jira-trobbu-v17.30.3';
const CORE=['./react-18.3.1.min.js','./logo.svg','./favicon.svg','./apple-touch-icon.png','./csv-import-v15.2.js','./speed-insights.js','./pwa-icon-192.png','./pwa-icon-512.png'];
const VENDOR_BASE='https://prweelxfuvbsdsxfopuh.supabase.co/storage/v1/object/public/jira-runtime';
const PUSH_RECEIPT_URL='https://prweelxfuvbsdsxfopuh.supabase.co/functions/v1/jira-web-push';
const reportPushReceipt=async(payload,stage,error='')=>{
  const deliveryId=Number(payload?.delivery_id||0),token=String(payload?.receipt_token||'');
  if(!deliveryId||!token)return false;
  try{
    const response=await fetch(PUSH_RECEIPT_URL,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({action:'receipt',delivery_id:deliveryId,receipt_token:token,stage,error:String(error||'').slice(0,480)}),cache:'no-store'});
    return response.ok;
  }catch{return false}
};
const RUNTIME=[
  `${VENDOR_BASE}/react/18.3.1/react.production.min.js`,
  `${VENDOR_BASE}/react-dom/18.3.1/react-dom.production.min.js`,
  `${VENDOR_BASE}/supabase-js/2.119.0/supabase.min.js`,
  `${VENDOR_BASE}/iconify-icon/2.3.0/iconify-icon.min.js`,
  `${VENDOR_BASE}/xlsx/0.18.5/xlsx.full.min.js`
];
self.addEventListener('install',event=>{event.waitUntil((async()=>{const cache=await caches.open(CACHE);for(const url of CORE){try{const r=await fetch(url,{cache:'reload'});if(r.ok)await cache.put(url,r.clone())}catch{}}for(const url of RUNTIME){try{const r=await fetch(url,{mode:'no-cors',cache:'reload'});await cache.put(url,r)}catch{}}await self.skipWaiting()})())});
self.addEventListener('activate',event=>{event.waitUntil((async()=>{for(const key of await caches.keys())if(key.startsWith('jira-trobbu-')&&key!==CACHE)await caches.delete(key);await self.clients.claim()})())});
self.addEventListener('fetch',event=>{const req=event.request;if(req.method!=='GET')return;const url=new URL(req.url);const same=url.origin===self.location.origin;const isConfig=same&&url.pathname.endsWith('/config.js');const isNav=req.mode==='navigate';const isVersionedAppAsset=same&&/(?:\/app-v|\/boot-v|\/styles-v|\/health\.json$|\/manifest\.webmanifest$)/.test(url.pathname);if(isNav||isConfig||isVersionedAppAsset){event.respondWith((async()=>{try{return await fetch(req,{cache:'no-store'})}catch(error){if(isNav)return new Response('<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Jira Interno</title></head><body style="font-family:system-ui;padding:32px;background:#0b1620;color:#fff"><h1>Sin conexión al build actual</h1><p>Jira Interno no usará una versión anterior en caché. Recupera la conexión y recarga la página.</p></body></html>',{status:503,headers:{'Content-Type':'text/html; charset=utf-8','Cache-Control':'no-store'}});throw error}})());return}event.respondWith((async()=>{const cached=await caches.match(req);if(cached)return cached;try{const fresh=await fetch(req);if(fresh.ok||fresh.type==='opaque'){const cache=await caches.open(CACHE);cache.put(req,fresh.clone()).catch(()=>{})}return fresh}catch{return cached||Response.error()}})())});


const macChromiumClientNotification=async(client,payload)=>{
  if(!client||typeof MessageChannel==='undefined')return false;
  return await new Promise(resolve=>{
    const channel=new MessageChannel();let done=false;
    const finish=value=>{if(done)return;done=true;clearTimeout(timer);resolve(!!value)};
    const timer=setTimeout(()=>finish(false),1400);
    channel.port1.onmessage=event=>finish(event?.data?.shown===true);
    try{client.postMessage({type:'JIRA_PUSH_MAC_NATIVE',notification:payload},[channel.port2])}catch{finish(false)}
  });
};

const pushNotificationOptions=payload=>({
  body:String(payload?.body||''),
  icon:payload?.icon||'./pwa-icon-192.png',
  badge:payload?.badge||'./pwa-icon-192.png',
  tag:payload?.tag||(`jira-${payload?.notification_id||Date.now()}`),
  renotify:true,
  requireInteraction:payload?.requireInteraction===true,
  silent:payload?.silent===true,
  vibrate:payload?.silent===true?undefined:[120,80,120],
  timestamp:Date.now(),
  actions:Array.isArray(payload?.actions)?payload.actions.slice(0,2):[],
  data:{url:payload?.url||'./',notification_id:payload?.notification_id||null,type:payload?.type||'system',category:payload?.category||'system',metadata:payload?.metadata||{},delivery_id:payload?.delivery_id||null,receipt_token:payload?.receipt_token||null}
});

self.addEventListener('push',event=>{
  event.waitUntil((async()=>{
    let payload={};
    try{payload=event.data?.json?.()||{}}catch{try{payload={title:'Jira Interno TROBBU',body:event.data?.text?.()||'Tienes una actualización.'}}catch{payload={title:'Jira Interno TROBBU',body:'Tienes una actualización.'}}}
    await reportPushReceipt(payload,'received');
    const windows=await self.clients.matchAll({type:'window',includeUncontrolled:true});
    const focused=windows.find(client=>client.focused===true);
    if(focused&&payload?.force_native!==true){
      try{focused.postMessage({type:'JIRA_PUSH_FOREGROUND',notification:payload});return}catch{}
    }
    try{
      await self.registration.showNotification(String(payload?.title||'Jira Interno TROBBU'),pushNotificationOptions(payload));
      await reportPushReceipt(payload,'displayed');
    }catch(error){
      await reportPushReceipt(payload,'display_error',error?.message||String(error));
      const desktopClient=windows.find(client=>client.visibilityState==='visible')||windows[0];
      if(desktopClient&&await macChromiumClientNotification(desktopClient,payload)){await reportPushReceipt(payload,'displayed');return}
      throw error;
    }
  })());
});

self.addEventListener('notificationclick',event=>{
  event.notification.close();
  const data=event.notification?.data||{};
  const target=new URL(data.url||'./',self.registration.scope);
  if(data.notification_id){target.searchParams.set('notification_action','read');target.searchParams.set('notification_id',String(data.notification_id))}
  event.waitUntil((async()=>{
    await reportPushReceipt(data,'clicked');
    const windows=await self.clients.matchAll({type:'window',includeUncontrolled:true});
    for(const client of windows){
      if(new URL(client.url).origin===target.origin){
        try{if('navigate'in client)await client.navigate(target.href);await client.focus();return}catch{}
      }
    }
    if(self.clients.openWindow)await self.clients.openWindow(target.href);
  })());
});


self.addEventListener('pushsubscriptionchange',event=>{
  event.waitUntil((async()=>{
    const windows=await self.clients.matchAll({type:'window',includeUncontrolled:true});
    for(const client of windows){try{client.postMessage({type:'JIRA_PUSH_SUBSCRIPTION_CHANGE'})}catch{}}
  })());
});
