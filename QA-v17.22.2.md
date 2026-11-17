# QA · Jira TROBBU v17.22.2

## Resultado

**71 PASS · 0 FAIL**

## Correcciones verificadas

- Header compartido para Vercel y GitHub Pages; no existen reglas por dominio.
- El grid reserva el ancho real del bloque de acciones (`max-content`) y permite que el buscador reduzca su ancho sin invadir `En vivo`.
- Breakpoints preventivos a 1540, 1380, 1200, 1040, 920 y 820 px.
- Nombre/email del usuario, `⌘ K` y etiqueta de Live se reducen progresivamente antes del breakpoint móvil.
- `Portal de solicitudes` usa superficie dark nativa y ya no conserva fondo blanco.
- Contraste dark del título Portal: **15.99:1**.
- Contraste dark del subtítulo Portal: **6.93:1**.
- `100 fuera hoy` conserva ancho intrínseco y no hace wrap.
- JSX parseado con TypeScript sin errores.
- CSS con llaves balanceadas y sin marcadores de merge.
- Regresión: Staff, Settings, Helpdesk, Realtime, Bitácora y separación Mis solicitudes/Mencionados continúan presentes.

## Paridad de hosting

Se compararon por SHA-256 los archivos runtime de FULL y COMPACT. Los siguientes archivos son idénticos byte a byte:

- `index.html`
- `app-v17.22.2.js`
- `styles-v17.22.2.css`
- `config.js`
- `logo.svg`
- `favicon.svg`
- `speed-insights.js`
- `csv-import-v15.2.js`

El frontend no requiere una variante específica para `vercel.app` o `github.io`.

También se sirvió el paquete COMPACT bajo una ruta anidada simulando GitHub Pages (`/jira_172222_compact/`): `index.html`, CSS, JS y `config.js` respondieron HTTP 200.

## Backend

Esta revisión es exclusivamente de frontend/header. No requiere migraciones de PostgreSQL, cambios RLS ni nuevos despliegues de Edge Functions.
