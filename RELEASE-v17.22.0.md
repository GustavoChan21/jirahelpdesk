# Jira Interno TROBBU · v17.22.0

Fecha: 17 de noviembre de 2026

## Objetivo
Estabilización visual/productiva posterior al refactor de Bitácora y separación correcta entre solicitudes propias y menciones de Helpdesk.

## Correcciones principales

- **Helpdesk / portal solicitante**
  - `Mis solicitudes` ahora usa únicamente registros cuyo `requester_user_id` corresponde al usuario autenticado.
  - Una solicitud de un tercero que el usuario puede consultar por mención ya no incrementa métricas, categorías ni contador de `Mis solicitudes`.
  - `Mencionados` conserva el acceso a tickets/solicitudes donde el usuario fue mencionado.
  - El contador lateral del portal solicitante ya no reutiliza el contador global del workspace.

- **Bitácora y sesiones**
  - Se corrigió la desalineación entre clases JSX y CSS del refactor (`audit-event-item`, `audit-filter-grid`, `audit-session-item`, `audit-session-icon`).
  - Se restauraron márgenes verticales entre toolbar, tabs, métricas, política y tablas/listados.
  - Las filas de Actividad vuelven a ser cards clicables alineadas a la izquierda.
  - Las sesiones usan una columna compacta para icono y dejan el contenido principal correctamente alineado.
  - Modal de detalle con padding, footer y responsive homologados.
  - Contrastes específicos para modo oscuro.

- **Helpdesk UI / modo oscuro**
  - Cards de `Solicitudes por tipo` ya no conservan fondo blanco en dark mode.
  - Cards, descripciones, uploader y contenedores usan superficies/tokens coherentes en ambos temas.
  - Espaciado entre PageHeader, métricas, categorías y listado homologado.

- **Limpieza productiva**
  - Se retiraron/ocultaron avisos técnicos de Storage privado, compresión/implementación, canalización interna, fallback técnico de IA, SMTP Test y banner redundante de portal privado.
  - Se mantienen errores, validaciones, estados y advertencias funcionales necesarias.

## Validación de datos real
Para el escenario reportado de Edgar Osorio, la BD devuelve actualmente:

- Solicitudes propias: **1**
- Menciones Helpdesk: **1**

La política RLS conserva la lectura por mención, por lo que el ticket mencionado sigue siendo accesible desde `Mencionados` sin mezclarse en `Mis solicitudes`.

## Distribución

- **FULL**: runtime actual + backend/Edge Functions actuales + DB consolidada + plantillas + documentación + QA. Sin histórico redundante de releases anteriores.
- **COMPACT**: únicamente archivos necesarios para desplegar el frontend estático actual y sus recursos runtime.

Ambos ZIP se entregan planos: **sin carpeta contenedora y sin `vendor/`**.
