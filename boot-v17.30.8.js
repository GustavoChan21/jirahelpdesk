(()=>{
  'use strict';
  const VERSION='17.30.8';
  const root=document.getElementById('root');
  const state={startedAt:Date.now(),attempt:0};
  window.__JIRA_BOOT={version:VERSION,state};
  const secondaryBase=location.hostname.includes('github.io')?'https://jiratrobbu.vercel.app/':'https://gustavochan21.github.io/jirahelpdesk/';
  const sleep=ms=>new Promise(r=>setTimeout(r,ms));
  const timeout=(promise,ms,label)=>new Promise((resolve,reject)=>{const id=setTimeout(()=>reject(new Error(`${label} excedió ${Math.round(ms/1000)} s`)),ms);Promise.resolve(promise).then(v=>{clearTimeout(id);resolve(v)},e=>{clearTimeout(id);reject(e)})});
  const loadScript=(url,ms=9000)=>timeout(new Promise((resolve,reject)=>{const s=document.createElement('script');s.src=url;s.async=false;s.onload=()=>resolve(url);s.onerror=()=>{s.remove();reject(new Error(`No se pudo cargar ${url}`))};document.head.appendChild(s)}),ms,url);
  const ensure=async(name,check,urls,critical=true)=>{
    if(check())return true;
    let last=null;
    for(const url of urls){try{await loadScript(url);if(check())return true}catch(error){last=error}}
    if(critical)throw last||new Error(`No se pudo cargar ${name}`);
    console.warn(`Jira boot · ${name} no disponible`,last);return false;
  };
  const localScript=async(path,critical=true)=>{try{return await loadScript(path,8000)}catch(error){if(critical)throw error;console.warn('Jira boot · recurso opcional',path,error);return null}};
  const showRecovery=(error)=>{
    const msg=String(error?.message||error||'No se pudo iniciar la aplicación.');
    if(!root)return;
    root.innerHTML=`<div class="boot-recovery"><div class="boot-recovery-card"><h1>Jira Interno no terminó de iniciar</h1><p>${msg.replace(/[<>&]/g,c=>({'<':'&lt;','>':'&gt;','&':'&amp;'}[c]))}</p><div class="boot-recovery-actions"><button id="jira-boot-retry" type="button">Reintentar conexión</button><a href="${secondaryBase}">Abrir sitio alterno</a></div></div></div>`;
    document.getElementById('jira-boot-retry')?.addEventListener('click',()=>{sessionStorage.removeItem('jira_boot_auto_retry');location.reload()});
  };
  const registerSW=async()=>{
    if(!('serviceWorker' in navigator))return;
    const sw=navigator.serviceWorker;
    const isCurrent=()=>!!sw.controller&&new URL(sw.controller.scriptURL).pathname.endsWith('/sw-v17.30.8.js');
    const legacy=!!sw.controller&&!isCurrent();
    try{
      const reg=await timeout(sw.register(`./sw-v17.30.8.js?v=${VERSION}`,{scope:'./',updateViaCache:'none'}),12000,'Actualización de caché');
      if(legacy&&!isCurrent()){
        await timeout(new Promise(resolve=>{
          const changed=()=>{if(isCurrent()){sw.removeEventListener('controllerchange',changed);resolve()}};
          sw.addEventListener('controllerchange',changed);changed();
        }),15000,'Activación de caché segura');
      }
      // Uncontrolled first visits are safe; activation removes historical Jira caches.
      if('caches' in window)for(const key of await caches.keys())if(key.startsWith('jira-trobbu-')&&key!==`jira-trobbu-v${VERSION}`)await caches.delete(key);
    }catch(error){
      if(sw.controller&&!isCurrent())throw new Error('No se pudo activar la caché segura. Recarga la aplicación para recuperar los datos actuales.');
      console.warn('Jira SW registration',error?.message||error);
    }
  };
  const boot=async()=>{
    state.attempt++;
    await registerSW();
    // Config first: it defines the project-owned runtime host used below.
    await localScript(`./config.js?v=${VERSION}`);
    if(!window.JIRA_CONFIG?.supabaseUrl||!window.JIRA_CONFIG?.supabasePublishableKey)throw new Error('config.js no contiene la configuración pública de Supabase.');
    const vendorBase=`${String(window.JIRA_CONFIG.supabaseUrl).replace(/\/$/,'')}/storage/v1/object/public/jira-runtime`;

    // Critical libraries: own/local assets first. Public CDNs are only emergency fallbacks.
    await ensure('React',()=>!!window.React,[
      './react-18.3.1.min.js?v=18.3.1',
      `${vendorBase}/react/18.3.1/react.production.min.js`
    ]);
    await ensure('ReactDOM',()=>!!window.ReactDOM,[
      `${vendorBase}/react-dom/18.3.1/react-dom.production.min.js`
    ]);
    await ensure('Supabase',()=>!!window.supabase?.createClient,[
      `${vendorBase}/supabase-js/2.119.0/supabase.min.js`
    ]);
    await Promise.all([
      ensure('Iconify',()=>customElements.get('iconify-icon'),[
        `${vendorBase}/iconify-icon/2.3.0/iconify-icon.min.js`
      ],false),
      ensure('XLSX',()=>!!window.XLSX,[
        `${vendorBase}/xlsx/0.18.5/xlsx.full.min.js`
      ],false)
    ]);
    await Promise.all([localScript('./csv-import-v15.2.js?v=15.9.0',false),localScript('./speed-insights.js?v=15.9.0',false)]);
    await localScript(`./app-v17.30.8.runtime.js?v=${VERSION}`);
    for(let i=0;i<60&&!window.__JIRA_APP_READY;i++)await sleep(200);
    if(!window.__JIRA_APP_READY)throw new Error('React no confirmó el arranque de la aplicación.');
    if(window.__JIRA_APP_BUILD!==VERSION){
      const skewRetries=Number(sessionStorage.getItem('jira_boot_version_skew')||0);
      if(skewRetries<1){
        sessionStorage.setItem('jira_boot_version_skew',String(skewRetries+1));
        try{if('caches'in window)for(const key of await caches.keys())if(key.startsWith('jira-trobbu-'))await caches.delete(key)}catch{}
        try{const regs=await navigator.serviceWorker?.getRegistrations?.();for(const reg of regs||[])await reg.update?.()}catch{}
        location.reload();return;
      }
      throw new Error(`Inconsistencia de versión: boot ${VERSION} / app ${window.__JIRA_APP_BUILD||'desconocida'}.`);
    }
    sessionStorage.removeItem('jira_boot_version_skew');sessionStorage.removeItem('jira_boot_auto_retry');
  };
  boot().catch(async error=>{
    console.error('Jira boot failed',error);
    const retries=Number(sessionStorage.getItem('jira_boot_auto_retry')||0);
    if(retries<1){sessionStorage.setItem('jira_boot_auto_retry',String(retries+1));await sleep(1800);location.reload();return}
    showRecovery(error);
  });
})();
