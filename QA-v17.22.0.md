# QA / Code Review · Jira Interno TROBBU v17.22.0

## Resultado

**53 PASS · 0 FAIL** en la suite focal v17.22.0.

## Cobertura

- Parseo JSX completo con parser TypeScript.
- Balance de CSS y ausencia de merge markers.
- Separación de solicitudes propias vs menciones.
- Métricas y contador de Helpdesk solicitante.
- Preservación del acceso de Mencionados.
- Limpieza de callouts técnicos de producción.
- Layout de Bitácora: Resumen, Sesiones, Actividad y modal de detalle.
- Responsive de filtros, sesiones y actividad.
- Contrastes dark mode de Bitácora y Helpdesk.
- Preservación de Staff & Roles / Settings restaurados en v17.21.
- Preservación de CRUD de Staff vía `manage-member`.
- Preservación de Realtime de Helpdesk y Audit.

## Verificación contra Supabase real

- Edgar Osorio: **1 solicitud propia** y **1 mención**.
- HD-23: solicitante Edgar Osorio.
- HD-35: solicitante Recepción Tulum; Edgar accede por mención.
- RLS `helpdesk_tickets_select` permite lectura por solicitante, asignado o `private.is_helpdesk_mentioned(id)`.
- Health Advisor: **0 lints**.

## Code review

No se eliminó ninguna función React respecto a v17.21.0: 165 funciones antes / 165 después, 0 ausentes.

La regresión visual principal se originó porque el JSX nuevo usaba clases que nunca recibieron estilos específicos. v17.22.0 alinea el contrato JSX/CSS en lugar de depender de selectores heredados.

## Distribución

- FULL reducido: no incluye copias históricas de app/styles, QA y releases de versiones antiguas.
- COMPACT: solo runtime estático requerido.
- Ambos paquetes son planos en raíz y no contienen `vendor/`.
