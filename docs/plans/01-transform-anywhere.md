# Plan A — Transform-anywhere

**Prioridad: 1** · Subsume traducción, corrección ortográfica/gramatical y cambio de tono como acciones de un mismo motor.

## Objetivo

Hotkey global sobre texto seleccionado (o el contenido del campo enfocado) → menú de acciones de transformación → el resultado reemplaza la selección o se previsualiza en el board antes de inyectar.

Acciones v1: corregir gramática/ortografía, traducir (ES↔EN configurable), cambiar tono (formal/casual), acortar, alargar.

## Por qué primero

Reutiliza ~80% de lo que existe: lectura AX del campo (`FocusedFieldReader`), inyección (`TextInjector`), hotkeys (`HotKey`), provider LLM (`CompletionProvider`), panel no-activante. Uso diario universal — es la feature que convierte el board en útil para quien no usa glide typing.

## Modos de entrada

1. **In-place**: hotkey → transformación directa sobre la selección, reemplazo inmediato. Para acciones de resultado predecible (corregir, traducir).
2. **Board (preview)**: el resultado se muestra en el panel composer antes de inyectar; se puede iterar ("más formal", "más corto") y confirmar. Para todo lo demás.

## Arquitectura

- `TextTransformer.swift` (nuevo): orquesta leer selección → prompt → inyectar. Independiente del pipeline de ghosts.
- Lectura de selección: `kAXSelectedTextAttribute` del elemento enfocado (nuevo método en `FocusedFieldReader`, mismo patrón que `textBeforeCursor`, con el mismo veto a campos seguros). Fallback: ⌘C simulado sobre un pasteboard temporal restaurando el clipboard (último recurso, marcarlo en debug).
- Reemplazo: `AXSelectedText` set cuando el campo lo soporte; fallback pegar-sobre-selección vía `TextInjector`.
- Prompts de transformación: plantillas por acción en `CompletionProvider` o provider hermano (`TransformProvider`) — misma infraestructura Apple/Ollama, distinto system prompt (salida = solo el texto transformado, sin comillas ni explicación).
- UI: mini-menú flotante junto a la selección (panel no-activante — **el campo destino debe conservar el foco AX**, mismo gotcha que el board).
- Registro en `QueryLog` con `kind: "transform"` para depurar igual que los ghosts.

## Fases

1. **Validación AX previa** (bloqueante, compartida con el plan B): pasada de pruebas de la matriz (Notas, Mail, Slack, Chrome, Word, 1Password) mirando `context`/`source`/`target` en QueryLog. Añadir a la debug window un volcado "contexto AX ahora" si hace falta.
2. Leer/escribir selección vía AX en apps nativas + Electron. Probar con `Tests/` script shell (patrón existente).
3. Motor de transformación + 2 acciones (corregir, traducir) en modo in-place.
4. Modo board con preview e iteración.
5. Resto de acciones + acción "instrucción libre" (puente hacia el plan B).

## Riesgos

- Apps que no exponen `AXSelectedText` escribible → medir en fase 1; si es mayoría, el modo board+pegar es el camino principal.
- Latencia LLM en in-place: >1.5 s mata la UX. Apple on-device para corregir; Ollama para traducir si hace falta calidad.
- Restaurar clipboard en el fallback ⌘C: obligatorio y con test.

## Criterio de éxito

Corregir y traducir funcionan de forma fiable en Notas, Mail, Slack y Chrome, con latencia in-place < 1.5 s (corrección) y sin corromper el clipboard.
