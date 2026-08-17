// Template propio del bootstrap de Flutter Web. Si este archivo existe, `flutter build web` lo usa
// en lugar del que genera por defecto (ver `flutter_tools/.../targets/web.dart`), reemplazando los
// tokens `{{flutter_js}}` y `{{flutter_build_config}}`.
//
// Existe por una sola razón: **CanvasKit se sirve desde este dominio y no desde un CDN.**
//
// El loader por defecto trae `canvaskit.js`/`canvaskit.wasm` de `gstatic.com`. El build ya deja una
// copia local en `canvaskit/`, así que el CDN no aporta nada y sí agrega un modo de falla: donde
// `gstatic.com` esté bloqueado —una red corporativa, un país con filtros, un entorno de CI sin
// egress— la app carga el HTML y después queda en blanco, sin error visible para el usuario.
//
// Antes de este archivo, el parche se aplicaba a mano sobre el `flutter_bootstrap.js` generado
// después de cada build. Un paso manual que hay que acordarse de repetir es un paso que alguna vez
// no se va a hacer.

{{flutter_js}}
{{flutter_build_config}}

_flutter.loader.load({
  config: {
    canvasKitBaseUrl: 'canvaskit/',
  },
});
