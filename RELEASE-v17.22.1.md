# Jira TROBBU v17.22.1

- Corrige icono faltante en la tarjeta Duración máxima de sesión.
- Usa icono `lucide:timer`, ya utilizado y validado por el sistema.
- Ajusta dimensiones/contraste del icono para claro y oscuro.
- Badge `Fuera hoy` ahora es `max-content`, no hace wrap y soporta conteos de al menos tres dígitos como `100 fuera hoy`.
- Breakpoints 1180/920/820/560 conservan la etiqueta y reducen padding/tipografía antes de ocultar otros elementos del header.
- Sin cambios de BD, RLS, Edge Functions ni flujos funcionales.
