# GlideBoard

Teclado flotante con **glide/swipe typing** para macOS — escribe palabras deslizando el ratón o el trackpad sobre un teclado en pantalla, como el teclado de Android. Pensado para escribir con una sola mano.

## Compilar y ejecutar

```sh
./build.sh
open build/GlideBoard.app
```

Requiere Xcode Command Line Tools (Swift). La primera vez, macOS pedirá el permiso de **Accesibilidad** (Ajustes del Sistema → Privacidad y seguridad → Accesibilidad): es necesario para que la app pueda "teclear" en otras aplicaciones.

> La app se firma con un certificado autofirmado estable ("GlideBoard Signing", en tu llavero de inicio de sesión), de modo que el permiso de Accesibilidad sobrevive a las recompilaciones. Si ese certificado no existe, `build.sh` recurre a firma ad-hoc y entonces habría que volver a conceder el permiso tras cada build (`tccutil reset Accessibility com.jon.glideboard` ayuda a limpiar el estado obsoleto).

## Uso

- **⌥⌘G** muestra/oculta el teclado flotante (también desde el icono ⌨︎ de la barra de menús).
- El teclado **no roba el foco**: el texto va a la app donde estés escribiendo (Notas, Safari, Slack…).
- **Desliza** sobre las letras de una palabra sin soltar el botón y suelta al acabar: se inserta la mejor predicción, con espacio automático entre palabras. Mientras deslizas, la barra superior muestra en vivo la palabra que se va formando.
- La **barra superior** muestra hasta 4 candidatas; haz clic en otra para sustituir la palabra recién insertada.
- Encima de las candidatas hay una fila en *cursiva* con **predicciones de la palabra siguiente**, que se actualiza tras cada palabra (modelo de bigramas: corpus + lo que tú escribes, guardado en `~/Library/Application Support/GlideBoard/`). Haz clic para insertarla; encadenando clics construyes frases enteras.
- **Clic corto** en una tecla = pulsación normal (letra, espacio, `.` `,` ⏎).
- **⌫** justo después de un glide borra la palabra entera; después, borra letra a letra.
- Botón **ES/EN** (o el menú de la barra) cambia de idioma (español con ñ y ~30.000 palabras; inglés con ~10.000).
- **Ajustes…** (menú ⌨︎ de la barra): cambiar el atajo de mostrar/ocultar (clic en el botón y pulsa la combinación nueva), idioma por defecto y tamaño del teclado (70–160 %). Se guardan en las preferencias del usuario.
- Arrastra el asa superior para mover el teclado. **✕** lo oculta.

## Cómo funciona

- `NSPanel` con `.nonactivatingPanel` para flotar sin activar la app.
- Reconocimiento de gestos estilo **SHARK2**: el trazo se remuestrea y se compara (posición + forma + frecuencia de la palabra) contra la polilínea ideal de cada palabra candidata, con poda por primera/última letra.
- El texto se inyecta con eventos `CGEvent` (por eso hace falta Accesibilidad).
- Atajo global con Carbon `RegisterEventHotKey` (no necesita permisos).

## Limitaciones (v0.1)

- Solo minúsculas (sin Shift); los acentos se escriben tal cual aparezcan en la candidata (el diccionario español incluye tildes).
- El diccionario de palabras es fijo (no aprende palabras nuevas), aunque las predicciones de palabra siguiente sí aprenden de tu uso.
