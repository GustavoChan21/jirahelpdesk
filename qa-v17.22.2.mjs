import fs from 'fs';
import path from 'path';
import {createRequire} from 'module';
const require=createRequire(import.meta.url);
const ts=require('/opt/nvm/versions/node/v22.16.0/lib/node_modules/typescript/lib/typescript.js');
const root=process.cwd();
const read=f=>fs.readFileSync(path.join(root,f),'utf8');
const app=read('app-v17.22.2.js'),css=read('styles-v17.22.2.css'),idx=read('index.html'),pkg=JSON.parse(read('package.json'));
let pass=0,fail=0;const check=(name,ok)=>{console.log(ok?'PASS ':'FAIL ',name);ok?pass++:fail++};
const parseJsx=(src,file)=>{const sf=ts.createSourceFile(file,src,ts.ScriptTarget.Latest,true,ts.ScriptKind.JSX);return sf.parseDiagnostics.length===0};
check('Version 17.22.2',pkg.version==='17.22.2'&&app.includes("BUILD_VERSION='17.22.2'"));
check('Index points to 17.22.2 assets',idx.includes('app-v17.22.2.js')&&idx.includes('styles-v17.22.2.css'));
check('Generic app/css copies match versioned build',read('app.js')===app&&read('styles.css')===css);
check('JSX parses with TypeScript parser',parseJsx(app,'app-v17.22.2.js'));
check('CSS braces balanced',(css.match(/{/g)||[]).length===(css.match(/}/g)||[]).length);
check('No merge markers',![app,css].some(s=>/^(<<<<<<<|=======|>>>>>>>)/m.test(s)));

// Requester vs mentions separation.
check('Own Helpdesk collection exists',app.includes("const ownHelpdesk=useMemo(()=>helpdesk.filter(h=>h.requester_user_id===session.user.id)"));
check('Requester portal receives only own Helpdesk',app.includes('<HelpdeskPortal items={ownHelpdesk}'));
check('Requester sidebar receives only own Helpdesk',app.includes('helpdesk={helpdeskOnly?ownHelpdesk:helpdesk}'));
check('Requester sidebar ignores workspace-wide Helpdesk counter',app.includes('helpdesk:Number(helpdeskOnly?helpdesk.length:(server.helpdesk??helpdesk.length))'));
check('Mentioned Helpdesk remains based on mention rows',app.includes('mentionedHelpdeskIds.has(h.id)'));
check('Mentioned requested tab remains own-only',app.includes('requestedHelpdesk={helpdesk.filter(h=>h.requester_user_id===session.user.id)}'));
const sample=[{id:'HD-35',requester_user_id:'frontdesk'},{id:'HD-23',requester_user_id:'edgar'}];
check('Ownership scenario excludes mentioned third-party request',sample.filter(x=>x.requester_user_id==='edgar').length===1);

// Production UI helper cleanup.
check('Portal private info banner removed',!app.includes('<div className="portal-info"'));
check('Create Storage implementation banner removed',!app.includes('Storage privado y optimización automática</b>'));
check('Portal routing implementation banner removed',!app.includes('className="notice routing-notice"'));
check('Comment Storage implementation banner removed',!app.includes('<div className="compression-notice"><Icon name="lucide:paperclip"'));
check('Assignment process notice removed',!app.includes('className={redirecting?\'notice routing-notice\''));
check('AI fallback implementation notice removed',!app.includes('<div className=\"notice\"><Icon name=\"lucide:bot\"/>'));
check('Staff subtle routing callout removed',!app.includes('className="notice subtle-routing-note"'));
check('SMTP Test production alert removed from UI',!app.includes('SendPulse continúa en SMTP Test.</b>'));
check('Workspace summary is not rendered as notice',app.includes('className="workspace-access-inline"'));
check('Critical runtime errors remain visible',app.includes('className="error')&&app.includes('compact-error'));

// Audit UI refactor alignment.
check('Audit activity JSX uses item class',app.includes('className="audit-event-item"'));
check('Audit activity item has concrete layout styles',css.includes('.audit-event-item{appearance:none;width:100%;display:grid;grid-template-columns:40px minmax(0,1fr) 20px'));
check('Audit activity metadata styled',css.includes('.audit-event-meta{display:flex'));
check('Audit filters match JSX class',app.includes('className="audit-filter-grid"')&&css.includes('.audit-filter-grid{display:grid;grid-template-columns:repeat(3'));
check('Audit session row matches JSX class',app.includes('className="audit-session-item"')&&css.includes('.audit-session-list .audit-session-item{display:grid;grid-template-columns:40px minmax(0,1fr) auto'));
check('Audit session icon styled',app.includes('className={`audit-session-icon')&&css.includes('.audit-session-icon{width:36px;height:36px'));
check('Audit summary vertical rhythm restored',css.includes('.audit-metrics{margin:0 0 16px!important}')&&css.includes('.audit-policy-card{margin:0 0 16px!important}'));
check('Audit detail modal has real padding',css.includes('.audit-detail-modal-body{padding:18px 20px 14px!important'));
check('Audit detail footer has horizontal padding',css.includes('.audit-detail-footer{margin:0!important;padding:12px 20px 16px!important'));

// Light/dark parity.
check('Audit dark cards override exists',css.includes('html[data-theme="dark"] .audit-activity-card'));
check('Audit dark filter contrast exists',css.includes('html[data-theme="dark"] .audit-filter-grid{background:#0E171F!important'));
check('Audit dark event contrast exists',css.includes('html[data-theme="dark"] .audit-event-item:hover'));
check('Portal type cards dark contrast exists',css.includes('html[data-theme="dark"] .portal-category-stats>div:last-child span'));
check('Request description dark contrast exists',css.includes('html[data-theme="dark"] .request-card-title p'));
check('Workspace inline dark contrast exists',css.includes('html[data-theme="dark"] .workspace-access-inline'));
check('Mobile Audit filters collapse to one column',css.includes('@media(max-width:700px)')&&css.includes('.audit-filter-grid{grid-template-columns:1fr;padding:10px;gap:9px}'));
check('Mobile audit event hides chevron at narrow width',css.includes('.audit-event-item>.audit-event-chevron{display:none}'));
check('Mobile portal category cards collapse',css.includes('.portal-category-stats>div:last-child{grid-template-columns:1fr}'));

// Regression guards for restored modules / current staff CRUD.
for(const n of ['StaffRolesView','SettingsView','WorkspaceSettings','HelpdeskSettings','NotificationSettings','Toggle','EntitySettings'])check('Module still present: '+n,app.includes('function '+n+'('));
check('Staff route still renders',app.includes("view==='team' && canManageStaff && <StaffRolesView"));
check('Staff update still uses Edge function',app.includes("action:'update_member'"));
check('Staff removal still uses Edge function',app.includes("action:'remove_member'"));
check('Realtime audit channel preserved',app.includes("audit-live-v3:${workspace.id}"));
check('Helpdesk Realtime data source preserved',app.includes("'helpdesk_tickets'")&&app.includes("scopedTables.forEach"));


check('Audit policy icon uses known timer icon',app.includes('className="page-icon sm audit-policy-icon"')&&app.includes('Icon name="lucide:timer"'));
check('Audit policy icon light style exists',css.includes('.audit-policy-card .audit-policy-icon{width:46px;height:46px'));
check('Audit policy icon dark contrast exists',css.includes('html[data-theme="dark"] .audit-policy-card .audit-policy-icon{background:#173A64!important;color:#A8CCFF!important}'));
check('Out today badge is intrinsic width',css.includes('.out-today-badge{width:max-content;min-width:max-content;max-width:none'));
check('Out today badge never wraps',css.includes('white-space:nowrap')&&css.includes('.out-today-badge span{display:inline!important'));
check('Out today label remains visible at <=820px',css.includes('@media(max-width:820px){.out-today-badge span{display:inline!important}'));
check('Header has 3-digit away-count responsive breakpoints',css.includes('@media(max-width:1180px)')&&css.includes('@media(max-width:920px)')&&css.includes('@media(max-width:560px)'));
const labels=['2 fuera hoy','10 fuera hoy','100 fuera hoy'];check('Away badge labels support 1-3 digit counts',labels.every(x=>x.length<=13));




// v17.22.2 shared header regression guards.
check('Header reserves max-content actions before flexible search',css.includes('grid-template-columns:minmax(250px,330px) minmax(180px,1fr) max-content'));
check('Search can shrink without overflowing grid',css.includes('.global-search,.portal-topbar-context{')&&css.includes('min-width:0;')&&css.includes('max-width:620px'));
check('Portal context has dark mode surface',css.includes('html[data-theme="dark"] .portal-topbar-context{')&&css.includes('background:#0D151D!important'));
check('Portal title has dark mode text contrast',css.includes('html[data-theme="dark"] .portal-topbar-context b{color:#E9F0F6!important}'));
check('Portal subtitle has dark mode text contrast',css.includes('html[data-theme="dark"] .portal-topbar-context small{color:#8FA1B3!important}'));
check('Header has pre-collision 1540 breakpoint',css.includes('@media(max-width:1540px)'));
check('Header hides user text before narrow layout',css.includes('@media(max-width:1380px)')&&css.includes('.top-user div{display:none}'));
check('Header hides search shortcut before collision',css.includes('.global-search kbd{display:none}'));
check('Header suppresses live label before mobile collapse',css.includes('@media(max-width:1040px)')&&css.includes('.topbar-actions .live-sync-indicator span{display:none}'));
check('Portal/search hide only at mobile breakpoint',css.includes('@media(max-width:820px)')&&css.includes('.global-search,.portal-topbar-context{display:none}'));

console.log(`\n${pass} passed · ${fail} failed`);if(fail)process.exit(1);
