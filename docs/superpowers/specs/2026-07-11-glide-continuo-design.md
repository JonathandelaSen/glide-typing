# Glide continuo (v2 experimental)

Fecha: 2026-07-11
Estado: aprobado, pendiente de plan de implementación

## Objetivo

Variante experimental del glide donde no se levanta el puntero entre palabras:
el trazo continúa y la palabra se corta al pasar por una tecla delimitadora de
la fila inferior (espacio, `,`, `.`, `?`), que además emite ese carácter. Se
prueba en paralelo con el glide clásico mediante un switch, y el diseño
garantiza que borrar cualquiera de las dos variantes al final del experimento
sea trivial y sin riesgo para la otra.

## Decisión de alcance

- Aplica a **ambos** modos de entrada: botón pulsado y arrastre (hover glide).
- **Tocar la tecla delimitadora basta** para cortar (sin dwell). La fila
  inferior no se cruza por accidente al glidear letras; si aparecieran falsos
  positivos, el dwell queda como ajuste futuro.
- Switch: **botón en la barra del teclado** (junto al ∿/● de arrastre), con
  flash visual, **persistido** en Settings. Arranca desactivado.
- **Sin captura de evals** en v0: primero sensaciones; la instrumentación se
  añade después si la idea promete.
- Delimitadores v0: espacio, `,`, `.`, `?` — solo la página de letras.

## Idea clave para el borrado

El modo continuo **necesita** el final de trazo clásico: la última palabra de
una frase no termina en delimitador, termina al soltar/tap, y eso es
exactamente el `didGlide` actual. v1 no es un hermano paralelo de v2: es un
subconjunto. Por eso la arquitectura es **aditiva** (opción elegida frente a
protocolo-con-dos-estrategias y fork del pipeline): no se mueve ni una línea
del flujo actual, y todo lo nuevo es greppable por `ContinuousGlide` /
`continuousGlide`.

## Diseño

### 1. `ContinuousGlideSegmenter.swift` — nuevo, lógica pura

Sin dependencias de UI; testeable en GlideBoardChecks. Recibe
`(punto, tecla bajo el puntero)` en cada movimiento del trazo y decide:

- Al **entrar** en una tecla delimitadora: emite un corte con los puntos
  acumulados hasta la frontera de la región, más el delimitador.
- Mientras el puntero siga **dentro** de la región: ningún corte adicional
  (dudar encima del espacio no repite cortes).
- Al **salir** de la región: empieza el segmento siguiente.
- Lleva la cuenta de cortes del trazo en curso (la necesita un caso borde del
  final corto, ver abajo).

### 2. `AppDelegate+ContinuousGlide.swift` — nuevo, handler del corte

Implementa el nuevo callback del delegado
`didGlideSegment(points:delimiter:)`:

- Decodifica el segmento con el `decoder.decode(...)` existente (mismo
  contexto de bigramas y personal) y llama al `insertGlideWord` existente.
- Delimitador **espacio**: no emite nada. El espacio perezoso existente
  (`needsSpace` en `insertGlideWord`) lo antepone a la siguiente palabra.
  Ventaja: las alternativas de la palabra recién cortada siguen activas hasta
  el siguiente commit — se puede corregir mientras se viaja a la siguiente.
- Delimitador **puntuación** (`,`, `.`, `?`): se emite por la ruta de tap
  existente, heredando auto-mayúsculas tras `.`/`?`, invalidación de
  `lastInsertedWord`, etc. — exactamente lo que hoy pasa al tapear esa tecla
  tras un glide.
- Segmento con recorrido `< unit * 0.8` (umbral de `decodePartial`): no se
  decodifica palabra, solo se procesa el delimitador. Permite encadenar
  `.`→espacio sin palabras fantasma.

### 3. `Settings.swift` — nueva propiedad

`continuousGlideEnabled: Bool`, por defecto `false`, persistida como el resto.

### 4. `KeyboardView.swift` — enganches mínimos guardados por flag

- Botón nuevo en la barra (junto a ∿/●) que togglea el modo con flash y avisa
  al delegado para persistir.
- En los dos puntos donde se acumulan puntos del trazo (`mouseDragged` y
  `mouseMoved` en hover): `if continuousGlide → segmenter.ingest(...)`; si hay
  corte, dispara `didGlideSegment`. `tracePoints` se vacía en el corte y
  vuelve a acumular cuando el segmenter abre el segmento nuevo (al salir de la
  región del delimitador), de modo que estela visual, preview y contenido del
  segmento coinciden siempre. La tecla delimitadora se ilumina al cortar
  (feedback de que cortó).
- Nuevo método en el protocolo `KeyboardViewDelegate`.

### Sin cambios

`GestureDecoder`, `Lexicon`, `BigramModel`, `GestureRanking`,
`insertGlideWord`, el final de trazo (`mouseUp`, `endTapTrace`,
`mouseExited` → `didGlide`) y el preview en vivo (`didUpdateGlide` opera sobre
`tracePoints`, que siempre contiene solo el segmento en curso).

## Errores y casos borde

- **Final corto tras un corte:** tanto en hover (`endTapTrace(typeLetterIfShort:
  true)`) como en modo pulsado (`mouseUp` con recorrido corto → `dispatchTap`),
  un trazo final corto escribiría la letra donde empezó el trazo (fantasma).
  Guard en ambos modos: si el segmenter registró ≥1 corte en este trazo, un
  final corto es no-op.
- **Contaminación de segmentos (limitación conocida de v0):** los tramos de
  viaje última-letra→delimitador y delimitador→primera-letra quedan dentro del
  segmento, y el decoder pondera fuerte los endpoints. Es el mayor riesgo de
  precisión percibida. Mejora futura apuntada: recortar el segmento en la
  última inflexión antes de entrar al delimitador. **No juzgar el experimento
  por la precisión de la primera build.**
- **Salir del teclado en hover:** sin cambios (cierra trazo, comitea el último
  segmento si supera el umbral).
- **Teclas no delimitadoras** en el camino (backspace, retorno…): ignoradas,
  como hoy.

## Pruebas

- GlideBoardChecks (`./test.sh`), casos sintéticos del segmentador: entrar en
  región produce exactamente un corte; permanecer dentro no produce más; salir
  y reentrar produce el segundo; el corte respeta la frontera; el contador de
  cortes se reinicia por trazo.
- Manual: `build.sh` + relanzar, A/B con el botón de la barra en ambos modos
  de entrada.

## Plan de borrado (compromiso del experimento)

- **Si v2 pierde:** borrar `ContinuousGlideSegmenter.swift`,
  `AppDelegate+ContinuousGlide.swift`, el método del protocolo, el botón de la
  barra, `continuousGlideEnabled` y los ~5 enganches en `KeyboardView`.
  Verificación: `git grep -i continuousglide` vacío y `./test.sh` verde.
- **Si v2 gana:** borrar solo el switch (botón + setting) y dejar el modo
  fijo. No queda código muerto: el flujo v1 restante (fin de trazo,
  `insertGlideWord`, decoder) es parte de v2.
