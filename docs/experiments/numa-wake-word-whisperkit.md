# Experimento: wake word y comandos de Numa sobre WhisperKit

**Fecha:** 2026-07-15 · **Estado:** investigación cerrada, **integrado en la app**
(mismo día): ganancia + prompt + segmentación por frases + gramática de una
tirada + comandos configurables en Ajustes → Numa. Pendiente de validación en
uso real.

## Contexto

La detección "Numa" → "graba audio" con WhisperKit tiny sobre ventanas
deslizantes de 2 s no funcionaba en vivo (~3/20 de recall del wake). Se
construyó `Tools/NumaAttentionLab` (`swift run NumaAttentionLab`) para medir
qué transcribe realmente el modelo de atención: captura por frases (VAD:
pre-roll 0,5 s, corte a 0,8 s de silencio), con flags `--model`, `--prompt`,
`--no-gain`.

## Resultados clave

| Configuración | Frase | Resultado |
|---|---|---|
| tiny, sin ganancia, sin prompt | "Numa" | ~0/20 — se transcribe como otra cosa |
| tiny, sin ganancia, sin prompt | "Hola qué tal" | 2/8 — hasta frases comunes fallan |
| tiny, sin ganancia, sin prompt | "Venga vamos" | ~8/13 — la mejor sin guía (frecuente en corpus) |
| tiny, **ganancia + prompt "Numa, graba"** | "Numa, graba" | **9/10**, y el fallo fue un rechazo correcto ("y vamos a grabar" no disparó) |

Hallazgos:

- La voz llega a ~-30 dBFS (rms 0,02–0,11) y tiny se degrada mucho ahí; la
  normalización de pico (tope ×12) recupera parte.
- Clips de 1,5–2 s aislados son el peor caso de Whisper; sobre silencio
  alucina coletillas fijas ("Gracias.").
- El prompt inicial (initial-prompt biasing) es el factor decisivo: guía al
  decoder hacia el vocabulario esperado.

## Decisión

**Gramática cerrada de comandos guiada por prompt, en una sola frase.**
El usuario dice "Numa, graba" (y a futuro "Numa, abre X…") de una tirada;
cada comando soportado se incluye en el prompt del modelo de atención. Se
descarta el modo dos etapas ("Numa, escucha" → orden abierta) porque la
segunda etapa reintroduce reconocimiento sin guía, que es lo que falla.

Regla operativa: **cada comando nuevo pasa una batería de ~10 frases en
NumaAttentionLab antes de entrar al prompt** (el prompt tiene ~224 tokens de
límite y cada comando añadido diluye el sesgo de los demás; con pocos
comandos va sobrado, con decenas habrá que re-validar).

## Integración (hecha el 2026-07-15)

1. ✅ `biasPrompt` en el descriptor de la app, construido desde
   `Settings.voiceCommands` (`VoiceCommandGrammar.biasPrompt`).
2. ✅ Normalización de ganancia (`AttentionAudioGain`) antes de cada
   inferencia de atención; compartida con el lab.
3. ✅ Segmentación por frases en `NumaAudioPipeline` (pre-roll 0,5 s, cierre a
   0,8 s de silencio) con chequeos incrementales mientras la frase crece, para
   no perder el dictado continuo ("Numa, graba, mañana…").
4. ✅ Gramática de una tirada (`VoiceCommandGrammar`): el comando debe ser el
   prefijo de la frase. Eliminado el estado `awaitingCommand` de dos etapas.
5. ✅ Comandos configurables en Ajustes → Numa (acción fija, frase editable);
   cambiar una frase reconstruye el pipeline de atención.

## Revisión 2026-07-16: flujo de dos fases (decisión de Jon)

El recorte del prefijo sobre una única grabación resultó frágil: el modelo de
dictado escribe el nombre inventado a su manera ("Luma"…) y el prefijo exacto
fallaba (5/7 sesiones descartadas con `unsafeVoicePrefix`). Nuevo diseño:

- **Comando y dictado son grabaciones separadas.** Al cerrar la frase del
  comando (pausa de 0,8 s) con match exacto, la sesión de dictado arranca
  **desde el fin de esa frase** usando el ring (no se pierde nada aunque se
  hable antes del chime) y su audio no contiene el comando → sin recorte.
- Generaliza a futuros comandos ("Numa, apaga…"): un comando es una acción
  discreta, no un prefijo de otra cosa.
- **La continuación en la misma frase se rechaza** con un aviso pedagógico
  ("Di «Numa, graba», espera la señal y dicta"). El recorte de prefijo
  (`VoiceCommandPrefixTrimmer`) se eliminó por completo: la señal visual
  "Habla ahora" (overlay verde desde el chime hasta el fin de la grabación)
  hace de contrato con el usuario, y quien se adelante un poco no pierde
  palabras porque la sesión se alimenta del ring desde el fin del comando.
- El prompt del comando **nunca** se pasa al modelo de dictado: el prompt de
  Whisper es "contexto ya transcrito" y hace que el modelo omita el audio
  coincidente (sesiones vacías).

## Experimentos futuros (no descartados, por orden esfuerzo/beneficio)

| # | Idea | Esfuerzo | Notas |
|---|---|---|---|
| 3 | `--model base`/`small` en el lab | Nulo | Medir CPU con `Tests/numa_live_metrics.sh` antes de adoptar |
| 4 | Matching difuso (distancia de edición/fonética) | Pequeño-medio | Sube recall; proteger precisión |
| 6 | SpeechAnalyzer/SFSpeechRecognizer on-device como motor de atención | Medio | Candidato serio para escucha permanente barata; WhisperKit quedaría solo para dictado |
| 7 | Whisper como KWS real: forzar tokens del wake y umbral de log-prob | Alto | La forma técnicamente correcta de usar Whisper como detector |
| 8 | Clasificador de sonido CreateML (plan original, borrado) | Muy alto | Mejor perfil de CPU; requiere dataset propio |

## Cómo retomar

`swift run NumaAttentionLab --prompt "<frase>"` y repetir la batería de 10.
Comparar siempre contra la línea base de esta página en las mismas
condiciones (misma sala, mismo micrófono, mismo volumen).
