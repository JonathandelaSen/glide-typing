# Plan — STT local (dictado)

**Prioridad: 3 · Fase 2 del roadmap.** No atacar como "otro Superwhisper con más botones": la diferenciación es el pipeline de contexto AX, no la lista de features.

## Objetivo

Hotkey (push-to-talk o toggle) → captura de micrófono → transcripción con modelo local → el texto pasa por el pipeline de contexto de GlideBoard (formateo según app/campo destino) → inyección en el campo enfocado.

## Posicionamiento

Mercado rojo: Wispr Flow y Superwhisper están pulidos tras años. Competir en transcripción cruda es perder. El ángulo propio:

- **Dictado consciente del destino**: el `targetDescription` + contexto AX formatea la salida — dictar en Slack produce tono casual, en Mail saludo y párrafos, en un campo "Asunto:" una línea. Nadie hace esto bien hoy.
- **Dictado + transform en un paso**: "…y tradúcelo al inglés" al final del dictado ejecuta la acción del plan A.
- Integración con el board: el dictado aterriza como borrador editable con ghosts, no como texto irrevocable.

## Stack (todo nuevo — nada reutilizable del código actual salvo inyección y contexto)

- Captura: `AVAudioEngine` + permiso de micrófono (`NSMicrophoneUsageDescription`).
- Modelo: whisper.cpp vía SPM (`whisper.spm`) o WhisperKit (CoreML, mejor en Apple Silicon). Decidir con benchmark propio: latencia y WER en español con `base`/`small`/`large-v3-turbo`.
- VAD para auto-parada en modo toggle.
- Post-proceso: pasada LLM opcional (limpieza de muletillas + formateo según contexto AX) — aquí se enchufa la diferenciación.

## Fases

1. Spike (1–2 días): whisper.cpp vs WhisperKit en la máquina objetivo; medir latencia de `small` en español con clips de 10 s. Si > 2 s, replantear modelo/enfoque.
2. Push-to-talk → transcripción cruda → inyección vía `TextInjector`. Sin UI más allá de un indicador de grabación.
3. Post-proceso con contexto AX (formateo por destino). Esta fase es el producto; la 2 es plomería.
4. Modo board: dictado como borrador editable.
5. Streaming (transcripción incremental mientras hablas) — solo si la latencia de la fase 2 lo exige.

## Riesgos

- Peso: modelos = cientos de MB–GB → descarga bajo demanda, no en el bundle.
- Latencia/batería en Macs Intel → declarar Apple Silicon como requisito y evitar la matriz de soporte.
- El pulido invisible (números, puntuación, code-switching ES/EN, vocabulario propio) es donde mueren los clones de Whisper — presupuestar la fase 3 como la mayor, no la 2.

## Criterio de éxito

Dictar 30 s en español en Mail y en Slack produce texto correctamente formateado para cada destino, con latencia total < 3 s tras soltar la tecla, 100% offline.

## Prerrequisito

Planes A y B en producción: reutilizan mercado (usuarios ya instalados) y pipeline (contexto + inyección + board) que este plan necesita.
