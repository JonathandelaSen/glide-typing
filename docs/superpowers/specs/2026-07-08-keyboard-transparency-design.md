# Transparencia ajustable del teclado

**Fecha:** 2026-07-08
**Estado:** aprobado en conversación

## Objetivo

Permitir que el panel flotante del teclado GlideBoard sea translúcido, con la
opacidad ajustable desde la ventana de Settings mediante un slider, igual que
el ajuste de tamaño existente.

## Decisión de alcance

Se aplica la transparencia a **todo el panel** vía `NSWindow.alphaValue`
(teclas, letras, trazo del glide y composer incluidos), no solo al fondo.
Se evaluó la alternativa "solo fondo" (modificar el alpha del fill en
`KeyboardView.draw()` manteniendo texto y teclas opacos) y el usuario eligió
explícitamente el panel completo, conocido el riesgo de legibilidad con
opacidades bajas. Migrar a "solo fondo" más adelante es sencillo y no queda
bloqueado por este diseño.

## Diseño

### 1. `Settings.swift` — nueva propiedad

```swift
/// Opacidad del panel del teclado (0.3–1.0).
static var opacity: Double {
    get {
        let v = defaults.double(forKey: "opacity")
        return v == 0 ? 1.0 : min(max(v, 0.3), 1.0)
    }
    set { defaults.set(newValue, forKey: "opacity") }
}
```

Mismo patrón que `scale`: clamp en el getter y valor por defecto cuando la
clave no existe (`double(forKey:)` devuelve 0). Mínimo 0.3 deliberado: por
debajo el teclado se pierde visualmente.

### 2. `AppDelegate.swift` — aplicar y actualizar en vivo

- En `buildPanel()`: `panel.alphaValue = Settings.opacity` junto al resto de
  configuración del panel.
- Conectar el callback `onOpacityChange` de la ventana de Settings para hacer
  `panel.alphaValue = newValue` en vivo. A diferencia de `scale`, no hay que
  reconstruir nada: es una propiedad barata de la ventana.

### 3. `SettingsWindow.swift` — slider

- Nuevo `NSSlider` "Transparencia:" en la misma fila-patrón que "Tamaño del
  teclado": rango 0.3–1.0, valor inicial `Settings.opacity`, etiqueta de
  porcentaje al lado (reutilizando el formato `scaleText`).
- `isContinuous = true` (a diferencia del de tamaño): la opacidad se
  previsualiza en vivo mientras se arrastra, porque elegir un valor visual
  sin feedback inmediato no tiene sentido y actualizarla es gratis.
- Acción `opacityChanged(_:)`: redondeo a pasos de 0.05, guarda en
  `Settings.opacity`, actualiza la etiqueta y llama a `onOpacityChange?`.
- Nueva closure pública `var onOpacityChange: ((Double) -> Void)?` siguiendo
  el patrón de `onScaleChange`.

## Sin cambios

- `KeyboardView.draw()`: el fondo mantiene su alpha 0.97 propio; el
  `alphaValue` de la ventana multiplica todo el contenido.
- `FloatingPanel` / comportamiento de foco: sin cambios.

## Errores y casos borde

- Valores corruptos o fuera de rango en UserDefaults quedan neutralizados por
  el clamp del getter.
- Con el panel oculto, el cambio se aplica igualmente y se ve al mostrarlo.

## Pruebas

No hay XCTest en el proyecto (se compila con `build.sh` y se relanza a mano).
Verificación manual: abrir Settings, arrastrar el slider con el teclado
visible y comprobar (1) cambio en vivo, (2) persistencia tras relanzar,
(3) que a 30% el teclado sigue siendo localizable y el slider recuperable.
