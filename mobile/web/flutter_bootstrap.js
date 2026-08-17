// Template propio del bootstrap de Flutter Web. Si este archivo existe, `flutter build web` lo usa
// en lugar del que genera por defecto (ver `flutter_tools/.../build_system/targets/web.dart`).
//
// Existe por una sola razón: **CanvasKit se sirve desde este dominio y no desde un CDN.**
//
// El loader por defecto trae `canvaskit.js`/`canvaskit.wasm` de gstatic.com. El build ya deja una
// copia local en `canvaskit/`, así que el CDN no aporta nada y sí agrega un modo de falla: donde
// gstatic esté bloqueado —una red corporativa, un país con filtros, un entorno de CI sin egress— la
// app carga el HTML y después queda en blanco, sin error visible para el usuario.
//
// CUIDADO al editar los comentarios de este archivo: el build sustituye los marcadores de plantilla
// EN TODO EL TEXTO, comentarios incluidos. Escribir sus nombres entre llaves dobles acá adentro hace
// que se reemplacen también ahí, y el `flutter.js` minificado termina inyectado dentro de una línea
// de comentario, se derrama fuera y el archivo deja de ser JavaScript válido (la app arranca en
// blanco con un `SyntaxError`). Si hace falta nombrarlos, nombralos sin las llaves.

{{flutter_js}}
{{flutter_build_config}}

_flutter.loader.load({
  config: {
    canvasKitBaseUrl: 'canvaskit/',
  },
});
