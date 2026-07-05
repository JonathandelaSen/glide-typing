# Plan C — Snippets inteligentes

**Prioridad: 4 · Bloqueado hasta completar las mejoras y pruebas de AX** (plan A fase 1 + plan B fase 3). Sin `surroundingContext` validado, un snippet inteligente no ve más que 450 chars del propio campo y el título de la ventana — y entonces no es mejor que TextExpander.

## Objetivo

Snippets con trigger determinista (`;meet`, `;nogracias`) cuyo contenido es una **instrucción guardada** que el LLM ejecuta con el contexto AX del campo donde se dispara. Mismo trigger, salida adaptada a la app, el hilo y el interlocutor.

Es literalmente el plan B con prompts persistidos: B fase 5 (historial de instrucciones) es la semilla — "guardar esta instrucción como snippet con trigger `;x`".

## Ejemplos objetivo (validados contra lo que el contexto AX realmente ve)

- `;meet` → "propón 2-3 huecos de 30 min la semana que viene, tono según el hilo" — formal en Mail, casual en Slack.
- `;nogracias` → rechazo educado que menciona la propuesta concreta — **requiere** leer el hilo (plan B fase 3); con el contexto actual solo vería el asunto.
- `;factura` → datos fiscales fijos, formateados según pida el formulario destino.
- Slots explícitos: `;intro {nombre}` → el resto lo rellena el contexto.

## Arquitectura

- Detección de trigger: `KeyInterceptor` ya observa el teclado (patrón del interceptor de Tab existente) — buffer de últimos N chars, match por prefijo `;`.
- Al disparar: borrar el trigger tecleado (backspaces vía `TextInjector`), ejecutar la instrucción con el pipeline del plan B, inyectar o previsualizar en el board según configuración del snippet.
- Persistencia: JSON en Application Support (mismo patrón que `PhraseMemory`); editor CRUD en `SettingsWindow`.
- Cada snippet declara: trigger, instrucción, modo (inyectar directo / preview en board), y si usa contexto ampliado.

## Fases

1. **Bloqueante**: plan B en producción con `surroundingContext` funcionando en Mail y Slack.
2. Motor de triggers + snippets estáticos (paridad TextExpander básica). Útil por sí solo y valida el interceptor.
3. Snippets con instrucción LLM + contexto, con preview en board por defecto.
4. "Guardar como snippet" desde el historial de instrucciones del plan B.
5. Slots `{...}` y snippet por-app (mismo trigger, instrucción distinta según app destino).

## Riesgos

- Falsos disparos del trigger mientras se escribe → prefijo `;` obligatorio + confirmación configurable.
- Borrar el trigger con backspaces sintéticos es frágil en apps web → medir en la matriz AX; alternativa: seleccionar-y-reemplazar vía AX donde se pueda.
- Sin contexto rico, la feature decepciona → por eso el bloqueo explícito sobre el plan B fase 3.

## Criterio de éxito

`;meet` disparado en Mail y en Slack produce propuestas de reunión con tono correcto para cada medio y coherentes con el hilo visible, sin editar nada a mano en ≥ 70% de los usos.
