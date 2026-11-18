const CACHE='jira-trobbu-v17.24.0';
const CORE=['./','./index.html','./styles-v17.24.0.css','./boot-v17.24.0.js','./app-v17.24.0.runtime.js','./config.js','./logo.svg','./favicon.svg','./apple-touch-icon.png','./csv-import-v15.2.js','./speed-insights.js','./health.json'];
const CDN=[
  'https://unpkg.com/react@18.3.1/umd/react.production.min.js',
  'https://cdn.jsdelivr.net/npm/react@18.3.1/umd/react.production.min.js',
  'https://unpkg.com/react-dom@18.3.1/umd/react-dom.production.min.js',
  'https://cdn.jsdelivr.net/npm/react-dom@18.3.1/umd/react-dom.production.min.js',
  'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.119.0/dist/umd/supabase.min.js',
  'https://unpkg.com/@supabase/supabase-js@2.119.0/dist/umd/supabase.min.js',
  'https://code.iconify.design/iconify-icon/2.3.0/iconify-icon.min.js',
  'https://cdn.jsdelivr.net/npm/xlsx@0.18.5/dist/xlsx.full.min.js'
];
self.addEventListener('install',event=>{event.waitUntil((async()=>{const cache=await caches.open(CACHE);for(const url of CORE){try{await cache.add(url)}catch{}}for(const url of CDN){try{const r=await fetch(url,{mode:'no-cors',cache:'reload'});await cache.put(url,r)}catch{}}await self.skipWaiting()})())});
self.addEventListener('activate',event=>{event.waitUntil((async()=>{for(const key of await caches.keys())if(key.startsWith('jira-trobbu-')&&key!==CACHE)await caches.delete(key);await self.clients.claim()})())});
self.addEventListener('fetch',event=>{const req=event.request;if(req.method!=='GET')return;const url=new URL(req.url);const same=url.origin===self.location.origin;const isConfig=same&&url.pathname.endsWith('/config.js');const isNav=req.mode==='navigate';if(isNav||isConfig){event.respondWith((async()=>{try{const fresh=await fetch(req,{cache:'no-store'});if(fresh.ok){const cache=await caches.open(CACHE);cache.put(req,fresh.clone()).catch(()=>{});return fresh}}catch{}return (await caches.match(req))||(await caches.match('./index.html'))})());return}event.respondWith((async()=>{const cached=await caches.match(req);if(cached)return cached;try{const fresh=await fetch(req);if(fresh.ok||fresh.type==='opaque'){const cache=await caches.open(CACHE);cache.put(req,fresh.clone()).catch(()=>{})}return fresh}catch{return cached||Response.error()}})())});
