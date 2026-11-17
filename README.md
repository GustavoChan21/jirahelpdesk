# Jira Interno TROBBU · v17.22.1

Build estable del Jira interno TROBBU.

## Despliegue frontend
Publica los archivos del paquete en la raíz del sitio. `index.html` carga `app-v17.22.1.js` y `styles-v17.22.1.css`.

## Base de datos
v17.22.1 no requiere migración de esquema respecto a v17.21.0. La separación `Mis solicitudes` / `Mencionados` se corrige en la capa de presentación conservando las políticas RLS existentes.

## Paquetes
- FULL: frontend + fuentes backend actuales + database.sql + QA + documentos/plantillas.
- COMPACT: frontend y assets runtime solamente.

No se requiere carpeta `vendor/`; las dependencias web se cargan desde los CDNs ya definidos en `index.html`.


## v17.22.1
Corrección focal de icono de sesión y badge Fuera hoy adaptable.
