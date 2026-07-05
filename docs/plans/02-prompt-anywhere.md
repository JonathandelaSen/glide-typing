# Plan B — Prompt-anywhere

**Prioridad: 2** · Se construye sobre el motor del plan A; comparten hotkey, panel y provider.

## Objetivo

Hotkey en cualquier campo de texto → escribes una instrucción libre ("redacta una respuesta declinando la reunión", "resume esto en 3 puntos") → el LLM genera usando el contexto AX del destino → preview en el board → inyectar al confirmar.

Es `ComposerFocus` llevado a su conclusión natural: el board como zona de redacción asistida para cualquier app.

## Diferencia con el plan A

A transforma texto que ya existe con acciones predefinidas; B genera texto nuevo desde una instrucción libre. Mismo pipeline (leer contexto → prompt → preview → inyectar), distinto prompt y distinta UI de entrada.

## Modos de entrada

1. **In-place rápido**: hotkey → campo de instrucción de una línea flotante → genera → inyecta directo. Para peticiones cortas de confianza.
2. **Board (por defecto)**: instrucción + resultado editable en el panel composer, con glide typing y ghosts activos sobre el borrador. Iterar antes de inyectar.

## Contexto: el trabajo real de este plan

Lo que hoy llega al modelo (ver `FocusedFieldReader`): texto antes del caret (450 chars), `app — título ventana — etiqueta campo`. Suficiente para tono y tema; **insuficiente para "responde a este mensaje"** — los mensajes del hilo/canal están fuera del campo enfocado.

Ampliación propuesta (`FocusedFieldReader.surroundingContext`, nuevo):
- Caminar el árbol AX hacia arriba desde el campo enfocado y recolectar `AXStaticText`/`AXValue` de elementos hermanos visibles (mensajes del chat, email citado), con tope de caracteres y timeout duro (el árbol AX puede ser enorme y lento — muestrear, no recorrer entero).
- Mantener el veto a campos seguros y añadir lista de apps excluidas (gestores de contraseñas, banca) en `Settings`.
- Todo lo recolectado, visible en la debug window: el usuario debe poder auditar qué se envía al modelo.

Los resultados de la matriz de validación AX (fase 1 del plan A) deciden cuánto de esto es viable por app.

## Fases

1. Depende de: plan A fases 1–3 (validación AX + motor + inyección).
2. Campo de instrucción + generación con el contexto actual (450 chars + target). Ya es útil sin ampliar contexto.
3. `surroundingContext`: hermanos AX con tope y timeout. Medir por app (Slack sí expone mensajes en el árbol; web depende de la página).
4. Modo board completo: instrucción → borrador editable → iterar → inyectar.
5. Historial de instrucciones recientes (semilla del plan 04 — snippets).

## Riesgos

- Recorrer el árbol AX es lento en apps grandes → timeout duro (p. ej. 150 ms) y caché por ventana.
- Privacidad: leer contenido de pantalla más allá del campo requiere opt-in explícito en Settings y visibilidad total en debug.
- El foco AX del destino debe sobrevivir a la interacción con el panel (gotcha conocido del panel no-activante).

## Criterio de éxito

"Responde que no puedo el jueves" en Slack/Mail produce una respuesta coherente con el hilo visible, sin tocar el ratón, en < 5 s de principio a fin.
