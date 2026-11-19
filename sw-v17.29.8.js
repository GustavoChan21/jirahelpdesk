const CACHE='jira-trobbu-v17.29.8';
const CORE=['./','./index.html','./styles-v17.29.8.css','./boot-v17.29.8.js','./app-v17.29.8.runtime.js','./config.js','./react-18.3.1.min.js','./logo.svg','./favicon.svg','./apple-touch-icon.png','./csv-import-v15.2.js','./speed-insights.js','./health.json','./manifest.webmanifest','./pwa-icon-192.png','./pwa-icon-512.png'];
const VENDOR_BASE='https://prweelxfuvbsdsxfopuh.supabase.co/storage/v1/object/public/jira-runtime';
const RUNTIME=[
  `${VENDOR_BASE}/react/18.3.1/react.production.min.js`,
  `${VENDOR_BASE}/react-dom/18.3.1/react-dom.production.min.js`,
  `${VENDOR_BASE}/supabase-js/2.119.0/supabase.min.js`,
  `${VENDOR_BASE}/iconify-icon/2.3.0/iconify-icon.min.js`,
  `${VENDOR_BASE}/xlsx/0.18.5/xlsx.full.min.js`
];
self.addEventListener('install',event=>{event.waitUntil((async()=>{const cache=await caches.open(CACHE);for(const url of CORE){try{await cache.add(url)}catch{}}for(const url of RUNTIME){try{const r=await fetch(url,{mode:'no-cors',cache:'reload'});await cache.put(url,r)}catch{}}await self.skipWaiting()})())});
self.addEventListener('activate',event=>{event.waitUntil((async()=>{for(const key of await caches.keys())if(key.startsWith('jira-trobbu-')&&key!==CACHE)await caches.delete(key);await self.clients.claim()})())});
self.addEventListener('fetch',event=>{const req=event.request;if(req.method!=='GET')return;const url=new URL(req.url);const same=url.origin===self.location.origin;const isConfig=same&&url.pathname.endsWith('/config.js');const isNav=req.mode==='navigate';if(isNav||isConfig){event.respondWith((async()=>{try{const fresh=await fetch(req,{cache:'no-store'});if(fresh.ok){const cache=await caches.open(CACHE);cache.put(req,fresh.clone()).catch(()=>{});return fresh}}catch{}return (await caches.match(req))||(await caches.match('./index.html'))})());return}event.respondWith((async()=>{const cached=await caches.match(req);if(cached)return cached;try{const fresh=await fetch(req);if(fresh.ok||fresh.type==='opaque'){const cache=await caches.open(CACHE);cache.put(req,fresh.clone()).catch(()=>{})}return fresh}catch{return cached||Response.error()}})())});

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
  data:{url:payload?.url||'./',notification_id:payload?.notification_id||null,type:payload?.type||'system',category:payload?.category||'system',metadata:payload?.metadata||{}}
});

self.addEventListener('push',event=>{
  event.waitUntil((async()=>{
    let payload={};
    try{payload=event.data?.json?.()||{}}catch{try{payload={title:'Jira Interno TROBBU',body:event.data?.text?.()||'Tienes una actualización.'}}catch{payload={title:'Jira Interno TROBBU',body:'Tienes una actualización.'}}}
    const windows=await self.clients.matchAll({type:'window',includeUncontrolled:true});
    const focused=windows.find(client=>client.focused===true);
    if(focused&&payload?.force_native!==true){
      try{focused.postMessage({type:'JIRA_PUSH_FOREGROUND',notification:payload});return}catch{}
    }
    await self.registration.showNotification(String(payload?.title||'Jira Interno TROBBU'),pushNotificationOptions(payload));
  })());
});

self.addEventListener('notificationclick',event=>{
  event.notification.close();
  const data=event.notification?.data||{};
  const target=new URL(data.url||'./',self.registration.scope);
  if(event.action==='mark-read'&&data.notification_id){target.searchParams.set('notification_action','read');target.searchParams.set('notification_id',String(data.notification_id))}
  event.waitUntil((async()=>{
    const windows=await self.clients.matchAll({type:'window',includeUncontrolled:true});
    for(const client of windows){
      if(new URL(client.url).origin===target.origin){
        try{if('navigate'in client)await client.navigate(target.href);await client.focus();return}catch{}
      }
    }
    if(self.clients.openWindow)await self.clients.openWindow(target.href);
  })());
});
