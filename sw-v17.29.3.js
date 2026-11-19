const CACHE='jira-trobbu-v17.29.3';
const CORE=['./','./index.html','./styles-v17.29.3.css','./boot-v17.29.3.js','./app-v17.29.3.runtime.js','./config.js','./react-18.3.1.min.js','./logo.svg','./favicon.svg','./apple-touch-icon.png','./csv-import-v15.2.js','./speed-insights.js','./health.json','./manifest.webmanifest','./pwa-icon-192.png','./pwa-icon-512.png'];
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
self.addEventListener('notificationclick',event=>{event.notification.close();const raw=event.notification?.data?.url||'./';const target=new URL(raw,self.registration.scope).href;event.waitUntil((async()=>{const windows=await self.clients.matchAll({type:'window',includeUncontrolled:true});for(const client of windows){if(new URL(client.url).origin===new URL(target).origin){try{await client.focus();if('navigate'in client)await client.navigate(target);return}catch{}}}if(self.clients.openWindow)await self.clients.openWindow(target)})())});
