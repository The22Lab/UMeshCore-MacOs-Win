# UMeshCore — orientación para trabajar en este repo

Este archivo se carga automáticamente. Es la fuente única de verdad sobre
el estado del port y las reglas que lo rigen. Léelo entero antes de tocar
código: hay cuatro convenciones que, si no se conocen, se rompen sin
darse cuenta.

---

## Qué es esto

`../UltraMesh 2d animation/` es un editor de animación 2D de mesh
esquelético en Swift/SwiftUI/Metal, funcional y pulido (~69 000 líneas).

El objetivo es **`UMeshCore`**, una librería C++ compartida, para que macOS
y una app Windows nueva tengan comportamiento **idéntico** de rig, mesh,
animación, editor y gizmos — mientras cada plataforma conserva su UI y su
renderer nativos.

Decisión explícita del usuario: la UI SwiftUI existente del Mac se migra a
*leer de* UMeshCore progresivamente, **nunca se reescribe**. La UI de
Windows (WinUI 3) se andamia temprano, en paralelo, no al final.

```
UMeshCore-MacOs-Win/
├── CLAUDE.md                    ← este archivo
├── UltraMesh 2d animation/      ← fuente Swift original (referencia)
└── UMeshCore/
    ├── ROADMAP.md               ← registro largo: el porqué de cada decisión
    ├── HANDOFF.md               ← traspaso: decisiones abiertas y por dónde seguir
    ├── README.md
    ├── bindings/swift/          ← auditoría de interop Swift (Fase 6a)
    ├── bindings/win/            ← notas de consumo WinUI 3 (Fase 6b)
    ├── include/module.modulemap ← el módulo Clang: `import UMeshCore`
    ├── include/umeshcore/<Módulo>/*.h
    ├── src/<Módulo>/*.cpp
    └── tests/                   ← un binario por archivo portado
```

`include/` y `src/` espejan la estructura de carpetas del Swift, para que
el equivalente C++ de cualquier archivo se encuentre por nombre.

---

## Construir y testear

```sh
cd UMeshCore
cmake --build build -j4
cd build && ctest --output-on-failure
```

53 binarios de test, 100% en verde. **Nunca dejes la suite en rojo.**

---

## Las cuatro convenciones — no negociables

Están aplicadas de forma consistente en todo el port. Romperlas produce
inconsistencia que después cuesta mucho deshacer.

### 1. Cero dependencias externas

Math, harness de tests, JSON y SHA-256 están escritos a mano, a propósito.
La razón (`ROADMAP.md` § *Repository layout*): los call sites de `simd` son
lo bastante idiosincráticos que traducir a otra librería sería en sí mismo
una fuente de bugs de transcripción. Si necesitas algo nuevo, escríbelo.

### 2. "Inyectar lo necesario", no portar los god objects

`SceneManager` tiene 7376 líneas y **87 ocurrencias de `@Published`** (77
declaraciones) mezclando datos de modelo con estado de UI. **No intentes
partirlo.** En su lugar:

> **Corrección (Fase 6a).** Este archivo y `EditorScene.h` decían "~400
> `@Published`". Es falso, y la cifra inflada importa: hacía parecer
> imposible una adaptación que medida resulta ser **26 propiedades de
> modelo, 38 de UI pura y 5 cachés derivadas**. Y las dos propiedades de
> modelo más cargadas —`images` y `skeleton`— **no son `@Published` en
> absoluto** (`SceneManager.swift:22` y `:42`): son `var` con
> `willSet { announceChange() }`, donde `announceChange()` es un limitador
> a **12 Hz** durante playback. Es deliberado: `applyAnimations()` tiene 49
> call sites, y publicarlas dispararía 60 notificaciones/segundo a 12
> vistas. Cualquier migración tiene que preservar ese `willSet`/`didSet` a
> mano, porque `framePoseCache`, `rigPoseCache` y `RenderMeshCache` se
> indexan por los tokens que incrementa el `didSet`.

- `EditorScene` es el agregado mínimo que las tools necesitan.
- Los assets se pasan como parámetro explícito (`AssetRecord`), igual que
  Swift pasa `AssetManager` aparte de `SceneManager`.
- Lo que hace falta de una API se recibe ya resuelto (un `const Skeleton&`,
  un `hitScale` explícito) en vez de un objeto entero.

### 3. Ninguna divergencia es silenciosa

Cuando el port se aparta del Swift — bug arreglado, formato desambiguado,
campo diferido, código muerto no portado — queda documentado **en el
archivo**, con el porqué, y con test. Ejemplos vivos:

- El bug de `.meshDeform` en el exportador binario (escribía cero bytes y
  desincronizaba el stream) está arreglado y versionado, no replicado.
- Los cuatro métodos de rotación-hover de `ToolManager` no se portaron:
  verificado por grep que tienen **cero call sites**. Código muerto
  demostrable, documentado como tal.
- `ProjectDocument::unrecognized` preserva textualmente las secciones del
  manifiesto que el port aún no modela, para que un ciclo abrir→guardar no
  destruya el modo Scene de un proyecto real.

### 4. Los tests afirman propiedades, no re-derivan la implementación

Los valores esperados se derivan **a mano del Swift**, nunca de la salida
de este port. Un test que re-calcula lo mismo que el código solo repite la
implementación; uno que afirma la propiedad documentada (project/unproject
son inversos exactos, un quad parcialmente visible da un polígono) atrapa
errores reales.

---

## El plan completo, fase por fase

| Fase | Qué es | Estado |
|---|---|---|
| 0 | Andamiaje del repo (CMake, dirs, tests) | ✅ Completa |
| 1 | Math + modelo de datos | ✅ Completa salvo 3 conveniencias de editor |
| 2 | Lógica de editor (tools, gizmos, picking, undo) | ✅ Completa salvo lo bloqueado por Fase 4/5 |
| 3 | Serialización (binario UMSH, `.umesh` nativo, UMJSON) | ✅ Completa salvo lo de Fase 5 |
| 4 | Capa de geometría de render compartida | ✅ Completa (1 pieza descartada: código muerto) |
| **5** | **Scene compositing, luces, física secundaria, export** | **✅ Completa** |
| **6a** | **Migrar la app Mac a consumir UMeshCore** | **🔨 En curso — la librería ya es consumible** |
| 6b | Shell Windows (WinUI 3 + DirectX) | ⬜ No empezada |

### Fase 1 — Math + modelo de datos ✅

Portado y testeado: `Transform3D2D`, `MatrixUtilities`, `Bone`/`Skeleton`
(+ caché de índice de hijos), los cuatro solvers de constraints
(IK 1-hueso/2-huesos/FABRIK, Path, Transform, Physics), `MeshPredicates`
(aritmética exacta), `MeshKernel` (triangulación), `MeshValidator`, `Mesh`
(skinning/sanitización/auto-bind), `Skin`/`SkinResolver`, `AnimationCurve`,
`Keyframe`, `AnimationClip`, `AnimationEvent`, `AnimationLibrary`.

**Pendiente** — 3 conveniencias de tiempo de edición, de `Data/Mesh.swift`:

- `generated()` / `generatedGrid` — generación procedural de puntos
  interiores para un mesh recién creado.
- El flujo de triángulos manuales: `sanitizedManualTriangles`,
  `triangulatedIndicesWithInternalEdges`.
- La heurística de puntuación de Auto-Bind (qué huesos *sugiere* un
  sprite). Distinta de `autoBindWeights`, que sí está portado.

### Fase 2 — Lógica de editor ✅

Portado: `ToolInput`, `EditorEscape`, `CameraState`, `UndoRedoManager`,
métricas de gizmos, `GizmoHandle`, `SceneImage`, casi todo
`ToolUtilities`, `SceneAnimator` completo (el evaluador de animación por
frame), `ConstraintAnimation`, `EditorScene`, `CanvasPicking::target`,
`ToolManager` y 6 de las 8 tools (Select, Move, Scale, Skew, Rotate, Bone).

**Pendiente, bloqueado por el pipeline de assets** (Fase 4/5). La raíz
común: `CanvasPicking.imageHit` necesita muestrear el canal alfa de una
textura **cargada**, y no hay pipeline de decodificación de imágenes.

- `hitTestScreen`, `hitTestRect`, `hitTestSelectionTarget`,
  `boundsForScene`, `boundsForImage`.
- El marquee de *sprites* en `ToolManager` (el de huesos sí está: es
  geometría pura).
- **`MeshTool`** (`Core/Tools/MeshTool.swift`, 672 L). Cada submodo (Bind
  Mode, Weight Paint, creación de hull, edición de vértices) pasa por el
  pipeline de alfa **o** por mutadores de mesh inexistentes
  (`updateMeshVertex`, `insertMeshVertex`, `deleteSelectedMeshVertices`),
  que necesitan `Mesh::clampedPositionInsideHullIfNeeded` →
  `hullVertexIndices`, `pointInsideHull`, `pointOnHullBoundary`.

**Pendiente, por otras razones:**

- **`PhysicsPreviewTool`** (59 L) — **portado en Fase 5**, y el
  diagnóstico que había aquí estaba equivocado a medias. Decía que estaba
  bloqueado hasta que `EditorScene` tuviera un `PhysicsConstraintSystem`
  vivo. No lo está: un sistema vivo leería `baseWorldMatrices()` igual que
  el de Swift y **seguiría sin ver el override**, porque en Swift
  *tampoco* lo lee nadie. Verificado por grep: `physicsPreviewOverrides`
  tiene exactamente tres menciones — la declaración y los dos métodos que
  la escriben. Es una feature sin terminar aguas arriba, no un hueco de
  traducción, así que se porta con la misma forma y el mismo efecto
  (ninguno), documentado en el header.
- Los intercepts de IK-builder y Bind-Mode en `ToolManager` — ninguno de
  los dos subsistemas está modelado en `EditorScene`.
- `solveRigPose` / `rigPose(atFrame:)` de `SceneAnimator` — Fase 5.

**Deuda marcada, el gizmo de Scene ya fuera de la vista** (Riesgo #6):
`Editor/SceneGizmoState.h` extrae la **forma** (basis por herramienta,
cámara estabilizada, escala única, ejes/anillos/planos proyectados) y
`Editor/SceneGizmoDrag.h` el **hit-test y el arrastre de una capa**. Toda
medida se hace donde vive la pregunta: rayo-eje para trasladar, rayo-plano
para los handles de plano, ángulo en el plano del propio anillo para rotar.
Los tests reproducen el método de pantalla que sustituyen y lo muestran
discrepando.

Dos cosas documentadas y **no** arregladas: la cámara estabilizada
magnifica el manipulador (los 19,5 px nominales dibujan 154), y el handle
**central** (free-move / escala uniforme) es **inalcanzable** mientras haya
un eje dibujado — los ejes empiezan *en* el origen, así que su distancia
nunca es mayor, y el empate lo gana el eje. Medido: 2618 agarres alrededor
del origen, **cero** al centro.

**`Editor/SceneLightGizmo.h/.cpp`** ← `Render/SceneLightGizmo.swift`
(253 L) + `lightWorldGeometry` sacado del overlay, más el arrastre de
**luces** y de **cámara** en `SceneGizmoDrag`. 12 tests.

Los handles de una luz se responden en el plano de mundo que **mira a la
cámara**, y el header Swift lo justifica contando grados de libertad: un
puntero da dos números, un radio quiere uno y una dirección dos, así que el
mapa puntero→valor solo es biyectivo cuando se fija el grado que falta — y
fijarlo al plano que el artista está mirando es lo que mantiene el punto
agarrado bajo el puntero.

Detalles que el port conserva y testea: al estirar el radio se preserva la
**banda** en unidades de mundo (no la fracción, o la luz cambiaría de forma
al redimensionarla); los ángulos del cono se leen en el **plano del propio
cono**, no en el que mira a la cámara; y `aimLight` deja el azimut **quieto**
en el polo, porque `atan2(0,0)` lo aplastaría a cero y sacar la luz del polo
la lanzaría a donde nunca apuntó.

`lightWorldGeometry` es **una sola geometría con dos consumidores**: los
puntos que agarra el artista y los anillos/arcos que dibuja la GPU
(rellena el `SceneGizmoLayout::LightDiagram` que la Fase 4 dejó definido y
sin llenar).

**`Editor/GraphViewport.h/.cpp`** ← `GraphViewport.swift` (302 L) +
`GraphMetrics.swift` (59 L). 9 tests. Primer trozo de la deuda del
timeline, y el correcto para empezar: los dos archivos ya estaban limpios
(tipos de CoreGraphics y aritmética, sin cuerpo de vista) y el resto de
`TimelineView.swift` los lee.

El viewport existe por un bug concreto: el rango vertical se derivaba de
los **valores de los keyframes**, y una cúbica entre dos claves no está
acotada ni por sus claves ni por sus puntos de control — lo está por sus
**propios extremos**. La curva se recortaba para caber en un rectángulo
derivado de algo que no es la curva. La regla que el tipo impone: la curva
y el viewport son independientes; nada recorta un valor para que quepa,
`fitting` mueve la **vista**.

El test no re-deriva la cuadrática: compara los extremos resueltos contra
un muestreo denso de la curva (200 001 muestras) y exige que coincidan.

Dos propiedades más, ambas con test: **toda proyección tiene inversa
exacta** (un arrastre lee un píxel, guarda un valor y vuelve al mismo
píxel), y el **suelo del zoom ensancha la vista sin moverla** — sin el
ancla, re-centrarse en el suelo arrastra la imagen en cada paso (el harness
Swift lo midió en 262% del ancho tras noventa pasos).

Divergencia: `touchScale` es `#if os(iOS)` en Swift; aquí es un parámetro.
El core no tiene plataforma, y además un shell Windows en modo tablet
quiere la escala táctil en la misma máquina que quiere la de puntero.

**`Editor/TimelineGraphMath.h/.cpp`** ← el editor de curvas, sacado del
cuerpo de vista de `TimelineView.swift`. 14 tests. Segunda mordida de la
deuda del timeline y la que cierra el editor de curvas: tangentes, puntos
de control, las dos proyecciones de pantalla del gráfico, y el hit-test de
handle / keyframe / curva.

La propiedad que sostiene el archivo: **el gráfico dibuja la curva que
suena**. Los puntos de control pasan por `AnimationCurve::segment`, la
misma llamada que hace la reproducción. El header Swift cuenta las tres
formas en que la geometría propia del gráfico discrepaba del evaluador, y
cada una es una curva que el artista veía y nunca oía: sin clamp de punto
de retorno dibujaba 100,65 sobre una clave de 100; sin clamp del punto de
control al segmento, una S de 90 unidades de diferencia; y un fallback de
0,35/0,65 contra el tercio del evaluador. Los tests **construyen la
respuesta rota al lado de la portada** y las muestran discrepando — una
aserción que solo dijera "el port se parece a sí mismo" pasaría igual de
contenta con el bug de vuelta.

Detalles conservados y testeados: un keyframe que **no** es bézier no se
dibuja con su out-tangent guardado (la interpolación describe el segmento);
los vecinos se pasan al evaluador porque **de ellos sale una auto-tangente**
y el gráfico los tiene, mientras que el evaluador, trabajando segmento a
segmento, no; y el suelo de 0,001 en escala no es cosmético — una escala
cero es una matriz que deja de invertirse, y skinning, picking y gizmos la
invierten.

Los dos ejes se mapean con **reglas distintas a propósito**: X sigue siendo
la fracción del clip porque el gráfico comparte mapeo con la regla y el
playhead que tiene encima — pasarlo por el viewport sacaría los números de
frame de registro con las claves debajo. Y es también la regla que decide
qué par de tangentes usa un canal (`.x`/`.scalar` → primario, todo lo demás
→ secundario): el caso que la rompió la primera vez fue `constraint.flag`,
que no es ninguno de los dos.

Dos divergencias, ambas forzadas por la plataforma:

- El hit-test de una curva lo resolvía SwiftUI, dándole un `strokedPath`
  como `contentShape`. Ese servicio no existe en el core ni en un shell
  Windows, así que la pregunta se responde numéricamente
  (`distanceToCurve`, aplanando el trazo), con el mismo ancho de agarre
  (`GraphMetrics::curveGrabPx`).
- Las tres funciones Swift equivalentes van a buscar los keyframes al
  `sceneManager`. Aquí nada recibe una escena (convención #2): el llamante
  pasa las muestras, el keyframe o los frames que ya tiene.

No portado, y no por olvido: `smoothAutoTangent` ya está **borrado** en el
Swift — su propio comentario explica que era la segunda respuesta, y
discrepante, a lo que contesta `AnimationCurve::autoSlope`.

Falta de la deuda SwiftUI: de `TimelineView.swift` (4326 L) queda lo que es
cuerpo de vista de verdad (gestos, Paths, colores, llamadas a
`sceneManager`).
`ringFrame` y las constantes de geometría que el mesh builder del gizmo
necesita ya están extraídas a `Render/SceneGizmoLayout.h` (Fase 4, pieza
5). Lo demás sigue dentro de las vistas:
`SceneGizmoOverlay.swift` (1732 L) y `TimelineView.swift` (4326 L) tienen
matemática real de hit-testing y curvas **dentro de cuerpos de vista
SwiftUI**. Hay que extraerla a UMeshCore *antes* de que la UI de Windows
necesite lógica equivalente — portar desde un cuerpo de vista SwiftUI
directamente es mucho más arriesgado que extraer primero en el Mac.

### Fase 3 — Serialización ✅

Tres formatos, los tres portados:

- **Binario UMSH**: formato, `BinaryWriter`, `BinaryReader` (código nuevo
  — el escritor Swift no tiene lector), y `BinaryExporter` con **los 7
  chunks** (SCENES cerrado en Fase 5).
- **`.umesh` nativo**: módulo JSON propio, todas las conversiones
  `Saved*`, el manifiesto `ProjectDocument`, y la capa de paquete
  (directorio + `Assets/` con deduplicación SHA-256, escritura atómica,
  sniffing de los tres formatos que comparten la extensión).
- **UMJSON**: modelo, builder y writer. Modelo deliberadamente separado de
  `Saved*` — IDs string, arrays planos, `"stepped"` en vez de `"hold"`, y
  unidades preservadas por campo (un hueso usa radianes para shear; un
  sprite usa **grados**).

**Pendiente:** embebido base64 de texturas en UMJSON (`AssetRecord` lleva
ruta, no bytes). `writeScenesChunk` y las secciones de Scene del manifiesto
ya están cerrados por Fase 5.

**Permanente:** `SavedEditorState` (escalares de UI de `AppState`) no se
porta — es estado de shell. Se preserva textualmente vía
`ProjectDocument::unrecognized`, testeado de punta a punta.

---

## Fase 4 — completa

Objetivo: geometría/batching/culling/proyección/luz agnóstica de
plataforma, expuesta como buffers POD que consumen backends finos de Metal
y DirectX. Se apunta al diseño GPU de `SceneMetalRenderer.swift`, **no** al
rasterizador CPU de CoreGraphics que reemplaza (no existe equivalente
Windows ni debería construirse).

### Hecho

**`Render/SceneProjection.h/.cpp`** ← `Render/SceneProjection.swift` (479 L).
La única conversión world→pixels: view matrix, proyección perspectiva,
división por w, recorte near/far en espacio de clip, rayos para arrastre de
gizmos. 20 tests.

Se eligió primero porque toda la fase cuelga de ella, y porque el header
Swift documenta por qué debe ser compartida: el lado del rig ya tenía
**tres** copias de world-to-screen y **ya discrepaban** — el exportador no
tenía término `rotation3D`, así que un sprite rotado en 3D se exportaba
distinto de como se veía. Dos backends de render re-derivando esto
reproducirían ese bug exacto.

**`Render/SceneCulling.h/.cpp`** ← `Render/SceneCulling.swift` (145 L).
`SceneFrustum` (seis planos extraídos de la view-projection, Gribb &
Hartmann) y `FrameRegion` (rectángulo entero del frame, redondeado hacia
**fuera**). 10 tests.

La regla asimétrica es el contrato: puede **conservar** algo invisible
(trabajo perdido) y **nunca** descartar algo visible (objeto que
desaparece). Por eso se descarta solo cuando el hull entero queda fuera de
**un** plano. El test principal no re-deriva coeficientes: comprueba contra
`SceneProjection` misma, sobre 4000 cámaras y puntos aleatorios, que nada
de lo que el proyector dibujaría se descarta.

Divergencia documentada: `Int(x.rounded(.down))` de Swift trapea fuera del
rango de `Int`; el cast en C++ satura antes (el llamante recorta al frame
igual).

**`Render/SceneViewCamera.h/.cpp`** ← `SceneViewCamera`
(`Data/Scene/SceneComposition.swift`) + la matemática de cámara de
`Render/SceneViewProjection.swift` (177 L). 9 tests.

Los dos Swift se unen aquí a propósito: el header dice que `basis` debe dar
**los mismos vectores** que usan `eye` y `pan`, porque "dos
transcripciones de forward es como el pivote acaba en otro sitio que el
centro de la pantalla". Aquí hay una sola: `cameraBasis`, ya en
`SceneProjection.h`. El test que lo cubre es exactamente ese: el pivote se
queda en el centro exacto tras dieciséis órbitas.

No portado: `cardCorners`/`cardPoint` — toman un `SceneLayer` y llaman a su
`liftToWorld`; eso es Fase 5, e inventar el tipo ahora obligaría a
re-transcribir ese lift, el fallo que el propio archivo advierte.

**`Render/SceneGPUTypes.h`** ← `Render/SceneGPU/SceneGPUTypes.swift` (278 L).
Los structs POD que lee el shader, byte a byte. 8 tests.

Son un **formato de cable**, no tipos normales: los mismos bytes se
declaran en Swift, en MSL y — con el backend DirectX — en HLSL. El header
Swift nombra el fallo: el drift "produce una imagen donde una luz está bien
y la siguiente lee el radio de su vecina".

El padding está deletreado porque Metal alinea `float3` a 16 bytes, y C++
es el raro aquí (`Vec3` son 12 bytes con alineación 4). Por eso cada struct
es `alignas(16)` y cada hueco es un campo `pad` con nombre.

**El harness que falta, sustituido**: `verify_scene_gpu_transcription.py`
no existe, así que la comprobación se metió **en el código** —
`static_assert` sobre tamaño, alineación y offset de cada campo, contra los
números derivados a mano del `.metal`. Un compilador que dispusiera esto de
otra forma no compila la librería. Los tests de runtime cubren lo que un
`sizeof` no ve: que un campo escrito por nombre cae en la **palabra** que
el shader lee.

No portado: `init(_ prepared:falloffRow:)` — transcribe un
`SceneLighting.PreparedLight` (pieza 7) de un `SceneLight` (Fase 5) y no
deriva nada. Sí están los **códigos** de `kind`/`blend` como enums: son el
contrato de cable. Lo que no debe hacerse nunca es mapear el enum del
modelo por cast — Swift usa un `switch` explícito porque los enums son
`String`-backed para el formato de archivo, y un raw value haría que el
orden de declaración cambiara en silencio cada escena guardada.

**`Render/SceneSkinPalette.h/.cpp`** ←
`Render/SceneGPU/SceneSkinPalette.swift` (170 L). 7 tests.

El fold: `N = rigToWorld · spriteToRig · A · (world · inverseBind) · B`,
una matriz por sprite y hueso. Treinta matrices en vez de 8320.

**La condición es el tipo entero**: el fold solo es exacto si los pesos
suman uno — meter un afín dentro de una suma ponderada añade su traslación
una vez por influencia en vez de una. El test central lo reproduce en vez
de describirlo: con los pesos crudos el vértice se va decenas de unidades,
y el delator está en la coordenada homogénea (la `w` de la suma **es** el
total de pesos).

Slot 0 es la identidad (`A·B`), escrito como el producto y no como
`Mat4::identity()`, para que un bind no exactamente invertible degrade como
degradan sus vértices. Se capa **antes** de normalizar, y el recorte se
cuenta (`truncatedVertices`) en vez de tragárselo.

Scoping: el init Swift toma un `Mesh` entero y lee un solo campo, así que
aquí se recibe ese campo — Render no depende de Mesh.

**`Render/SceneGizmoTypes.h` + `SceneGizmoLayout.h` + `SceneGizmoMeshBuilder.h/.cpp`**
← `SceneGPU/SceneGizmoTypes.swift` (38) + `SceneGizmoLayout.swift` (135) +
`SceneGizmoMeshBuilder.swift` (478). 12 tests.

La descripción CPU de la forma del gizmo y su conversión a triángulos:
conos y cilindros para las flechas, toros tubulares para los anillos, quads
translúcidos para los handles de plano, y el diagrama propio de una luz.
Todo en **espacio de mundo**; el vertex shader hace el recentrado y el
deslizamiento por `screenOffsetNDC`.

**Sin recorte de near-plane aquí**, a diferencia de `ringArcs` del overlay:
ese recorta a mano porque un stroke de `Canvas` es una polilínea sin
noción de clip space. Un triángulo entregado a la GPU no tiene ese
problema — el rasterizador recorta contra el frustum, exacto y gratis.
(Contrasta con `clipAndProject`, que **sí** recorta: alimenta picking en
CPU y el export, donde no hay rasterizador.)

**Primera mordida del Riesgo #6**: `ringFrame`, la colocación del quad de
plano, la escala del view ring y el `awayAlpha` salen de
`SceneGizmoOverlay.swift` (1732 L de SwiftUI) al core, que es exactamente
el orden que este archivo pide — extraer *antes* de que Windows necesite el
equivalente. Lo que construye un layout (`gizmoState`, `handleSet`,
`gizmoScale`, la matemática de arrastre) sigue allí: necesita el modelo de
Fase 5.

Diferido: `SceneGizmoTarget` y el payload del handle de luz (tipos de Fase
5). El builder nunca los lee — los handles de una luz le llegan como
posiciones — así que `kLight` es un caso único cuyo único trabajo es
**ordenar** el buffer.

El orden de emisión es contrato: diagrama de luz primero y debajo, luego
planos, ejes y anillos. El test lo afirma como propiedad de **prefijo**
(añadir una capa encima nunca mueve lo de abajo) y comprueba que barajar el
layout no cambia un solo vértice.

### Pieza 6 (geometría auxiliar) — NO se porta: código muerto demostrable

`ArcGeometryBuilder.swift` (152), `SphereGeometryBuilder.swift` (140),
`ArcMath.swift` (86) y `ArcHitTest.swift` (97) son el gizmo de rotación
**3D de arcos** — una implementación anterior, superada. Verificado por
grep, no por lectura:

- `ArcGeometryBuilder` y `SphereGeometryBuilder`: **cero** referencias
  fuera de sus propios archivos, en todo el proyecto (`.swift` y `.metal`).
- `ArcMath` solo lo usan esos dos y `ArcHitTest`.
- `ArcHitTest` solo lo usan `updateRotationHover` y
  `handleRotationMouseDown` de `ToolManager` — que son **dos de los cuatro
  métodos de rotación-hover que este port ya había descartado** por tener
  cero call sites (convención #3, arriba). Es la misma pista, llegando dos
  veces desde lados opuestos.

Lo que sí está vivo es otro gizmo: `GizmoRenderer.rotateGizmoVertices` /
`skewGizmoVertices` (anillo 2D + aguja), que `MetalRenderer` sí llama y
cuyo hit-testing es `ToolUtilities` → `.rotateRing` / `.skewEdge`, ya
portado en Fase 2. Portar los arcos habría añadido ~475 líneas de un
manipulador que la app no dibuja ni testea.

Si alguna vez se recupera ese diseño, el detalle que merece rescatarse es
que `ArcMath` era la copia **única** que compartían dibujo y hit-test — la
propiedad que este port persigue en todas partes.

Trampa registrada para ese caso: el índice de arco significa cosas
distintas en los dos archivos. En el builder, 0 es el anillo exterior; en
`ArcHitTest`, 0 es **"no hay hit"** y el anillo exterior es 4
(`RotationGizmoState.mouseDown` hace `guard hitArc > 0`). Un port
literal del `Int` heredaría esa ambigüedad; lo correcto sería un
`std::optional`.

### Pieza 7 — hecha

**`Render/SceneLighting.h/.cpp`** ← `Render/SceneLighting.swift` (544 L) +
`LightFalloffCurve` de `Data/Scene/SceneLight.swift`. 18 tests.

Dónde se resuelve la luz, que no es donde uno diría: **por capa, en espacio
de pantalla, contra el plano de la propia capa**. En espacio de textura
sería erróneo de forma visible — una capa puede ser un rig con sprites
deformados, así que la posición de un téxel dice poco de dónde acaba en el
mundo. Pero una capa Scene **es plana**, así que el rayo por un píxel corta
su plano en un punto exacto. Una retícula por capa, no por sprite.

La retícula se elige de la **banda de fade**, no del radio: la banda es
donde está la curvatura; fuera de ella el campo es plano o cero y la
interpolación es exacta.

**Primera cifra de un harness ausente que sí se pudo reproducir.** El
header Swift dice que `0.5 + (x - 0.5) * 1.0` mueve **3 327 de 20 001**
muestras, hasta **1.5e-08** — por eso `contrast == 0` toma una rama. El
test lo recalcula en la misma malla y sale exactamente 3327 y 1.49e-08.
Las dos ramas neutras parecen la misma regla y no lo son: `smoothness == 0`
no cambia ningún bit (está para ahorrar trabajo), `contrast == 0` **sí**.

También se cierra el `init` diferido de `SceneLightUniform`: los enums de
matemática (`SceneLightKind`/`SceneLightBlend`) y su `switch` explícito
hacia los códigos de cable viven aquí. Nunca un cast.

**No portado**: `LightField::composite(from:into:)` — lee un bitmap de
CoreGraphics y escribe otro; **es** el rasterizador CPU que esta fase
deliberadamente no cruza. Su aritmética no se pierde: es lo que hace el
fragment shader y queda escrita en el header para la pieza 9
(`lit = clamp(src*factor + additive*srcAlpha, 0, srcAlpha)`; el término
aditivo se escala por alfa porque se suma a la **superficie**, que solo
existe donde hay alfa — plano, encendería el margen transparente de cada
sprite).

### Pieza 8 — hecha

**`Render/SceneRenderBudget.h/.cpp`** ← `Render/SceneRenderBudget.swift`
(174 L). 10 tests.

La escalera de resolución: el cap **se mide**, no se elige. Un cap fijo hay
que elegirlo para la peor máquina y el set más pesado, y entonces está mal
para todas las demás combinaciones.

Se porta aunque el header Swift justifique la escalera con "Scene compone
en CPU": los dos fallos que evita son propiedades de **la escalera**, no
del rasterizador, y dos shells inventando la suya darían al mismo artista
dos parpadeos distintos en dos máquinas. Lo único que merece revisarse por
backend es el tiempo objetivo — y es una constante nombrada, no una
suposición escondida.

- **Oscilación**: se sube prediciendo el escalón de arriba (el coste va con
  los píxeles, y los píxeles con el cuadrado de la escala), no con un
  umbral. El test reproduce el ejemplo del header — 15 ms a media escala
  contra 33 ms "parece sitio de sobra"— y exige que el escalón no se mueva
  en 600 frames.
- **Trinquete**: un frame catastrófico no deja el canvas blando el resto de
  la sesión; en cuanto deja de haber motivo, vuelve arriba de golpe.

`FrameCostMeter` toma la **mediana**, no la media: un frame de 80 ms porque
la app arrancaba arrastra una media de seis frames y cuesta un escalón.

### Pieza 9 — hecha (y con ella la fase)

**`Render/SceneShaderMath.h/.cpp`** ← `SceneGPU/SceneShaders.metal` (1022 L)
+ `SceneGizmoShaders.metal` (80 L). 19 tests.

La matemática del shader **autorada una vez en C++** (Riesgo #5): MSL y
HLSL serán transcripciones que se diffean **numéricamente** contra esto, no
por inspección visual.

**Sustituye una pieza perdida.** El banner del `.metal` dice que está
"espejado por `Editor/gpu_mirror.py` y comprobado contra
`Editor/lighting_mirror.py`, que sigue siendo la referencia normativa de lo
que vale un píxel iluminado", porque no había toolchain Metal. En este repo
**no hay ni un solo `.py`**. Este archivo es esa referencia, y además se
ejecuta y se testea.

El muestreo de texturas está **modelado**, no aproximado: bilineal,
clamp-to-edge, centros de téxel — que es lo que hace un sampler de
Metal/D3D. De ahí salió el hallazgo de abajo.

#### ⚠️ Hallazgo: el sampler de falloff y la tabla de CPU no coinciden

El comentario del shader dice que el off-by-one "es asunto del sampler, no
nuestro". Lo es — y el asunto del sampler son los **centros de téxel**:
direcciona `u*n - 0.5` donde la CPU direcciona `u*(n-1)`. Leen entradas
distintas de la misma tabla. Medido sobre 256 entradas:

| Curva | Peor diferencia |
|---|---|
| `smooth` (la de por defecto) | 0.29 / 255 |
| `linear` | 0.50 / 255 |
| **`inverseSquare`** | **3.21 / 255** (en u ≈ 0.025) |

Tres pasos de cuantización en la parte más empinada del preset más
empinado: GPU y compositor CPU pondrían números visiblemente distintos en
el mismo píxel. El arreglo es **una línea** en el lado que se declare
normativo (tabular en las posiciones del sampler, o direccionar la tabla
por centros de téxel). Se deja al shell que primero embarque los dos
caminos — tocar cualquiera de los dos lados aquí divergiría en silencio del
Swift — pero ya es un número en un test y no una frase que nadie comprobó.

#### Los cross-checks que ahora existen

- `shapedLambert` y `lightLambert`: **idénticos bit a bit** entre
  `SceneShaderMath` y `SceneLighting`. Dos transcripciones de una fórmula
  que difieran *en algo* ya han derivado.
- `lightAttenuation`: igual salvo el hueco del sampler de arriba.
- **Un píxel iluminado entero**, de punta a punta, contra
  `SceneLighting::shade` + el composite. Eso es exactamente lo que
  `lighting_mirror.py` existía para comparar.

### Qué NO portar de `Render/`

Es shell de plataforma y se queda en cada app (≈9000 líneas):
`MetalRenderer.swift` (2159), `SceneMetalRenderer.swift` (1922),
`SceneFrameRenderer.swift` (2009), `TouchInputMTKView`,
`ToolInputMTKView`, `SceneMetalView`, `PlayheadView`,
`KeyframeDiamondIcon`, `DisplayClock`.

### ⚠️ Los harnesses de verificación citados NO existen

Los archivos de `Render/` citan repetidamente
`verify_scene_perspective.py`, `verify_scene_near_clipping.py`,
`verify_scene_culling.py`, `verify_scene_gizmo_drag.py`,
`verify_scene_gpu_transcription.py` — todos bajo `Editor/` — con cifras
concretas ("313 px", "51 capas de 20 000 cámaras", "1.4e-08 px").

**No existen en este repo.** Ni esos ni `gpu_mirror.py` /
`lighting_mirror.py` (que el `.metal` llama "la referencia normativa de lo
que vale un píxel iluminado"): no hay **ningún** `.py` en el repositorio.

Qué se hizo al respecto en la Fase 4, en vez de anotarlo y seguir:

- **Reproducida**: la cifra de `shapedLambert` (3 327 de 20 001 muestras,
  hasta 1.5e-08). El test la recalcula en la misma malla y sale exacta.
  Funciona porque los dos lados son float32 — la premisa de esta librería
  de math, así que el acuerdo es evidencia *sobre la premisa*.
- **Sustituida**: `verify_scene_gpu_transcription.py` → `static_assert` de
  tamaño/alineación/offset en el header. Un compilador que disponga los
  structs de otra forma no compila la librería.
- **Sustituida**: `gpu_mirror.py` / `lighting_mirror.py` →
  `Render/SceneShaderMath.h/.cpp`, que además se ejecuta y se diffea contra
  `SceneLighting` en los tests.
- **No reproducibles**: las cifras de culling (51 capas de 20 000), de
  skinning (652 / 700 / 1343 unidades) y de gizmo-drag (313 px). Los tests
  afirman la *propiedad* que medían, no el número.

Si aparecen en otra copia del proyecto, traerlos seguiría siendo valioso.

---

## Fase 5 — completa

Todo el namespace de Scene compositing, en `Data/Scene/`. Portarlo cierra
de golpe cinco pendientes: el chunk SCENES, las secciones de manifiesto
que hoy viven en `unrecognized`, los dos constructores de conveniencia de
`SceneProjection`, `cardCorners`/`cardPoint` de la cámara de vuelo, y
`PhysicsPreviewTool`.

### Hecho

**`Scene/SceneLayer.h/.cpp`** ← `Data/Scene/SceneLayer.swift` (282 L):
`SceneFill`, `SceneLayerContent` (variant de rig/plate/fill) y
`SceneLayer`. **`Scene/SceneMaterial.h`** ← `SceneMaterial.swift` (238 L).
**`Scene/SceneLightMask.h`**, sacado de `SceneLight.swift` a un header
propio porque lo necesitan tres cosas y solo una es una luz (la capa, el
material y la luz) — meterlo en el header de la luz obligaría a una capa a
incluir una luz para describirse. 31 tests.

Esto desbloquea `cardCorners`/`cardPoint` de `SceneViewCamera` y el
`orientation()` que espera `SceneLayerUniforms`.

**`Scene/SceneComposition.h/.cpp`** ← la mitad `SceneComposition` de
`SceneComposition.swift` (241 L). **`Scene/SceneCamera.h`** ←
`SceneCamera.swift` (59 L), que cierra `SceneProjection::init(camera:)`
(vive en el header de Scene, no en el de Render, para que la dependencia
apunte en un solo sentido). **`Scene/SceneLight.h`** ← la mitad *modelo*
de `SceneLight.swift`: la matemática ya estaba en `Render/SceneLighting.h`
y no se retranscribe — `SceneLight::params()` llena un `SceneLightParams`
y `direction()`/`innerRadius()`/`bandWidth()` se las pide a las funciones
que ya existen. `SceneAmbient` **tampoco** se re-declara: ya estaba en
`Render/SceneLighting.h`. 23 tests.

- **El orden del array de capas NO es el orden de dibujo.** Solo rompe
  empates. `drawOrderedLayers()` ordena por `(sortingOrder, índice)`
  explícitamente porque ni el sort de Swift ni `std::sort` son estables, y
  dos cartas de la misma capa intercambiándose entre arranques es un set
  que se reordena solo.
- **Un enum, dos nombres.** `SceneLightKind`/`SceneLightBlend` son los
  enums que ya declara `Render/SceneLighting.h`; el modelo solo añade sus
  `rawValue` de texto, que son la ortografía del **formato de archivo**.
  Nunca un cast: un cast haría que el archivo guardado dependiera del
  orden de declaración.

**`Serialization/SavedScene.h/.cpp`** ← `Data/Scene/ScenePersistence.swift`
(463 L), más el cableado en `ProjectDocument`. 26 tests.

Cierra uno de los pendientes más viejos del port: las secciones
`sceneCompositions` / `selectedSceneCompositionID` / `sceneViewCamera`
**salen de `ProjectDocument::unrecognized`** y pasan a campos reales.
`unrecognized` sigue haciendo su trabajo con lo que aún no se modela (hoy
solo `editorState`), y el test de punta a punta que lo demuestra sigue
pasando — ahora acompañado de otro que comprueba que el modo Scene
sobrevive un ciclo real a disco **como valores**, que es una garantía más
fuerte que JSON opaco.

Cada concesión de compatibilidad es **por campo** y nombra su escenario:

- `material` ausente → superficie **plana**. No es un "neutro aproximado":
  `isFlat` cierra una rama en la que el shader ni entra, así que "renderiza
  bit a bit como antes" sobrevive.
- `sortingOrder` ausente → **el índice en el archivo**. Antes de que las
  capas tuvieran número, el apilado *era* el orden del array. Cero daría el
  mismo orden por suerte, y dejaría de darlo en cuanto alguien tocara un
  número.
- `lightMask` ausente → canal 1 y `receivesLight` true, que es lo que hace
  que una luz añadida después a una escena vieja llegue a algo.
- Un `parallaxMode` que este build no conoce → **`off`**, nunca el más
  parecido: elegir el más parecido renderizaría al artista una escena que
  nunca compuso y le dejaría guardarla encima.
- Una capa sin el payload de su tipo se **descarta**, no se inventa.

Y los rangos se aplican **al entrar**, no solo en el inspector: un archivo
editado a mano no puede producir una cámara que divida por `tan(0)`, un
cono con el interior mayor que el exterior (el smoothstep correría al
revés: un foco iluminado del revés), ni una máscara vacía. Ojo al detalle
asimétrico: la máscara vacía de una **luz** restaura a *todos* los canales
y la de una **capa** al canal 1 — responden preguntas distintas.

Una escena vacía **no escribe nada**: sin composiciones no se emite
`sceneCompositions` ni `sceneViewCamera`, que es lo que mantiene los
archivos byte-estables para proyectos que nunca tocan el modo Scene.

**Chunk SCENES** (`BinaryExporter::writeScenesChunk`), diferido desde Fase
3 y ahora cerrado: el séptimo y último chunk del binario UMSH. Las
composiciones se **inyectan** en `exportScene` (igual que los assets), no
viven en `EditorScene`. Dos cosas que conviene saber:

- Las capas se escriben **en orden de dibujo**, de atrás hacia delante, y
  el chunk **no lleva número de capa**: lo que un player necesita es el
  orden, no la aritmética que lo produjo. Escribir el array crudo le daría
  al runtime un apilado que el editor nunca dibujó.
- Las pistas de cámara se escriben **una vez por composición** y todas
  reciben las mismas, porque salen del único `sceneAnimationClip` del
  proyecto. Es el comportamiento de Swift y la forma del formato: se
  reproduce, no se "arregla" — pero implica que hoy el formato no puede
  expresar animación de cámara por composición.
- El shear y el material **no** están en el chunk. Es el layout de Swift:
  el formato de runtime es anterior a ambos, y añadir campos a un chunk
  congelado sin subir la versión es como un lector empieza a parsear el
  siguiente registro como parte de este.

Un bug encontrado por un test durante este incremento: `frontSortingOrder`
usaba el `-1` de Swift como semilla del máximo en vez de como valor para
el caso vacío, así que una escena con todas las capas en órdenes negativos
devolvía 0 — poniendo la carta nueva *detrás* de las que debía encabezar.

Tres cosas que conviene saber antes de tocarlo:

- **La invariante fundacional: toda capa es PLANA.** Su Z es constante en
  toda la carta. Es lo que colapsa la perspectiva a un solo factor de
  escala, lo que hace que el parallax no cueste nada, y —menos obvio— lo
  que hace la **iluminación exacta**: `SceneLighting` interseca el rayo de
  un píxel con `lightingPlane()` y obtiene el punto de mundo que de verdad
  está ahí, contenga lo que contenga la capa.
- **`orientation()` existe aparte de `planePoint` por un bug entero.** El
  gizmo sacaba su frame diferenciando la transformada de la carta, que
  pasa por `planePoint` — escala, **shear**, roll. Normalizar los dos
  vectores arreglaba sus longitudes y no podía hacer nada con el **ángulo**
  entre ellos, así que una carta con shear le daba al gizmo un frame que
  no era una rotación. `orientation()` es roll y luego tilt: ni la escala
  ni el shear lo alcanzan.
- **`sortingOrder` y `positionZ` van al revés a propósito.** Mayor
  `sortingOrder` es **más al frente**; mayor `positionZ` es **más lejos**.
  Y la profundidad **no reordena nada**: empujar una carta en Z cambia
  cuánto mide y cuánto se desliza, nunca quién tapa a quién.

`planePoint` es escala → shear → roll, y **ese orden es la definición**:
el shear va en unidades ya escaladas, igual que `SceneImage` aplica skew.

**`Scene/ScenePlayback.h/.cpp`** ← `ScenePlayback.swift` (105 L) y
**`Scene/SceneSelection.h`** ← `SceneSelection.swift` (47 L). 18 tests.

- **Scene tiene su propio reloj**, y no es capricho: el rig reproduce a
  `projectFramesPerSecond` entre sus frames de playback; una escena tiene
  su `durationInFrames` y su `fps` — un shot a 24 puede montar un rig
  animado a 60. Y conducir la escena desde el playhead del rig rompería lo
  que Scene *es*: cada instancia mapea el frame de escena al suyo por
  velocidad/offset/loop, así que tres pájaros del mismo rig aletean
  desacompasados; con el reloj del rig se moverían todos igual.
- **Nada se acumula.** La sesión es `(startTime, startFrame, fps, bounds)`
  y el playhead es **función pura del tiempo**. Un transport que avanzara
  por delta correría *lento* en una máquina que pierde frames, convirtiendo
  un frame caído en tiempo perdido y separándose del audio y del export.
  Derivado del tiempo, un frame que no se puede entregar cuesta una
  *muestra* del movimiento, nunca un paso.
- **El reloj se inyecta.** Swift usa `CACurrentMediaTime()` por defecto; no
  hay equivalente portable y el core no tiene por qué tenerlo, así que cada
  entrada recibe el instante. Beneficio extra: el transport es exactamente
  testeable.

Documentado por un test: una muestra tomada **exactamente** en el borde de
un frame es ambigua por un ulp cuando el reloj va por los miles de segundos
(`(1000.0 + 1/24) - 1000.0` sale 4e-14 corto). Es inherente a la resta en
double, idéntico en Swift, y **inofensivo justamente por la regla de
arriba**: el error está acotado a una muestra y no se arrastra.

**`Editor/Tools/PhysicsPreviewTool.h/.cpp`** ← `PhysicsPreviewTool.swift`
(59 L), registrado ya en `ToolManager`. 11 tests.

El hallazgo: **el override de pose no tiene consumidor, tampoco en Swift**
(ver arriba). El tool sí está **vivo** —la tecla "y" y el menú de
constraints lo seleccionan—, así que no es código muerto como
`ArcGeometryBuilder`; es una feature a medio terminar, y se porta tal cual.
Un test afirma exactamente eso: arrastrar un hueso no cambia una sola
matriz de mundo. Si algún día se añade el lector, **ese** test es el que
debe fallar.

Su hit-test es geometría real y tiene reglas **propias**, distintas de las
de `BoneTool`: candidatos son los **dos extremos** de cada hueso (el
segmento entre ellos no es agarrable), gana el más cercano, y el radio es
un 14 fijo que **no** se escala para táctil.

**`Export/ExportSettings.h/.cpp`** ← `Export/ExportSettings.swift` (158 L)
+ los tres enums `String`-backed que sostiene. 16 tests.

Cruza porque **es un formato compartido**: el preset que escribe el botón
Save existe "para que la configuración de export viaje con el equipo", así
que el build de Mac y el de Windows tienen que coincidir campo por campo y
token por token, o un preset guardado en uno se abre mal en el otro.

Divergencia documentada: **todos los campos son opcionales al leer**, con
el valor de un `ExportSettings` recién construido como defecto, y un token
de enum desconocido conserva el defecto. El `Codable` de Swift es más
estricto y lanzaría ante una clave ausente — pero un preset viaja entre
máquinas y entre versiones de la app, así que rechazarlo entero por una
clave es justo el fallo que esto evita.

**`ExportManager.swift` (135 L) NO se porta**: es orquestación y casi todo
es plataforma (`PNGFrameSource` sobre un renderer offscreen de Metal,
`VideoExporter` sobre el escritor H.264 de AVFoundation,
`SceneFrameRenderer`, `URL`, `async`/`Task`). Lo único que es lógica y no
cableado son dos cosas, y ninguna vive ahí:

- La guarda que impide escribir un `.umesh` plano **encima de un paquete
  de proyecto**. Es real e importa —comparten extensión por diseño, así que
  el "¿reemplazar?" del panel de guardado parece razonable y decir que sí
  destruye el proyecto—, y este port ya la tiene como `classifyProjectFile`
  en `Serialization/ProjectPackage.h`, donde vive el sniffing.
- El nombrado de subdirectorio por clip del batch
  (`parentDirectory/{clipName}/`): una línea de join alrededor de un
  exporter de plataforma.

### Pendiente

Nada de Fase 5. Lo que sigue son las fases 6a/6b y la deuda arrastrada de
fases anteriores (Fase 1: 3 conveniencias de `Mesh`; Fase 2: todo lo
bloqueado por el pipeline de alfa, `MeshTool`, y la deuda SwiftUI de
`SceneGizmoOverlay`/`TimelineView`; Fase 3: base64 de texturas en UMJSON).

---

## Fase 6 — la fase actual

Lo primero que necesitan **6a y 6b** es lo mismo: que la librería sea
**consumible desde fuera**. Eso ya está.

### Hecho

- **`include/umeshcore/UMeshCore.h`** — el umbrella: los 102 headers
  públicos en un `#include`. Es para los shells, **no** para el código de
  dentro: un `.cpp` de `src/` sigue incluyendo solo lo que usa.
  Ojo: el umbrella **no** se genera por glob (`HeaderSelfContainmentTests`
  sí), así que un header nuevo hay que añadirlo a mano. Se había quedado
  atrás con cinco (`GraphViewport`, `SceneGizmoState`, `SceneGizmoDrag`,
  `SceneLightGizmo`, `TimelineGraphMath`) y están puestos.
- **`include/module.modulemap`** — el módulo Clang que hace que
  `import UMeshCore` resuelva. Va **junto** al árbol de headers y no
  dentro, porque Clang lo busca en la raíz de un header search path.
  Lleva `requires cplusplus20` a propósito: sin él, un target que se
  olvide de `-cxx-interoperability-mode=default` recibe un muro de errores
  desde dentro de `<variant>` en vez de un diagnóstico claro.
- **Reglas de `install` / `export`** + `UMeshCoreConfig.cmake`.
  Verificado de punta a punta: `cmake --install` y luego un proyecto
  externo real que hace `find_package(UMeshCore)` y enlaza
  `UMeshCore::umeshcore` compila y corre.
- **`HeaderSelfContainmentTests`** — compila **cada header público como su
  propia unidad de traducción**, solo. Los 102 pasan hoy; el target existe
  para que el primero que deje de pasar rompa *este* build y no el de un
  shell, meses después, con otro compilador.
- **`bindings/swift/README.md`** y **`bindings/win/README.md`** — las
  notas de consumo de cada plataforma.

### La auditoría de interop, en corto

La mayor parte de la superficie cruza a Swift **sin tocar nada**, y no es
casualidad: cero dependencias externas (convención #1) significa que no hay
un tipo de terceros en ninguna firma. Lo que no cruza limpio es un conjunto
**pequeño y acotado** — por eso la respuesta es una fachada y no una capa
C ABI sobre todo:

| Construcción | Sitios | Qué hacer |
|---|---|---|
| `std::variant` | 3 (`KeyframeValue`, `GizmoHandle`, `SceneLayerContent`) | Discriminante + accesores `optional<T>` **junto** al variant, no en su lugar: el `std::visit` de C++ conserva la exhaustividad. |
| typedef de `std::function` | 1 (`ImageHitTestFn`) + 1 parámetro | Sobrecarga con puntero a función C + `void*`. Se decide **junto** con el pipeline de alfa de Fase 2 — es el mismo punto de inyección. |
| Bases con virtuales puras | 3 (`Tool`, `Constraint`, `CanvasActivity`) | Nada: el shell las **consume**, no las implementa. |
| Accesores que devuelven referencia | 14 | Por valor los que lee una vista. Swift no da garantía de lifetime, y este port ya se llevó dos mordiscos de esa clase **en C++**. |

Detalle completo, con el porqué de cada decisión, en
`bindings/swift/README.md`.

### Rebanada 0 de 6a — hecha: el proyecto Xcode ya está cableado

**No lo rehagas.** `UltraMesh.xcodeproj/project.pbxproj` ya tiene las
cuatro cosas que hacían falta, y antes no tenía ninguna:

- `UMeshCore/src` como `PBXFileSystemSynchronizedRootGroup` del target de
  app — el mismo mecanismo que el proyecto ya usa para sus fuentes Swift.
  Xcode compila los ~53 TUs de C++ él mismo, para macOS **y** iPad. Se
  eligió sobre enlazar un `.a` de CMake para no gestionar archivos por
  slice ni meter un paso de build externo; CMake se queda para los tests
  del core.
- Un exception set que deja `CMakeLists.txt` fuera del bundle.
- `HEADER_SEARCH_PATHS` y `SWIFT_INCLUDE_PATHS` a `UMeshCore/include`.
- `SWIFT_OBJC_INTEROP_MODE = objcxx`.

Los cuatro van en los dos bloques de **proyecto**, no del target, para que
el bundle de tests los herede.

`UltraMesh 2d animationTests/UMeshCoreInteropSmokeTests.swift` es la
verificación, con cuatro tests graduados para que un fallo se localice
solo: constante de header vs. símbolo de `.cpp` (separa "headers visibles"
de "fuentes compiladas y enlazadas"), `Vec2` cruzando con sus campos, un
tipo con métodos (`SceneLightMask`), y un algoritmo real
(`ScenePlayback`).

### Pendiente

**Lo siguiente es que alguien con un Mac compile y ejecute esos cuatro
tests.** Hasta que eso esté confirmado, todo lo demás de 6a se escribiría
sobre una suposición: en este entorno Linux no hay `swift`, `swiftc` ni
`xcodebuild`, así que **todo el Swift de esta migración llega compilado
cero veces**.

El plan completo por rebanadas (1 puente de tipos → 2 esqueleto → 3
animación → 4 mesh → 5 serialización → 6 Scene) y el porqué de su forma
está en el mensaje del commit de la rebanada 0 y en el plan de la sesión.
La forma corta, que es lo que hay que no olvidar: **las vistas no pueden
hablar con objetos C++ opacos** —sostienen copias de structs Swift,
SwiftUI diffea por `Equatable`, y hay `Binding` encadenando sobre campos
almacenados (`InspectorPanelView.swift:1247`)—, así que **UMeshCore se
queda los algoritmos y los structs Swift se quedan como espejo de datos,
convertidos en la frontera**.

Las fachadas de interop **no** están escritas, a propósito: el orden
razonable es escribirlas *cuando una vista concreta las pida*. Una fachada
especulativa es una segunda API que mantener.

Sin empezar: el shell WinUI 3 + DirectX (6b).

---

## Riesgos nombrados

Detalle completo en `ROADMAP.md` § *Named risks*. En resumen:

1. **God object `SceneManager`** — no partirlo de una vez; que cada fase
   absorba lo que vuelve redundante.
2. **Física: singleton → por instancia de rig.** El Swift usa un
   `static let shared` real. El port **no** lo replica: varias instancias
   de rig no deben compartir un reloj de simulación. Divergencia
   deliberada y documentada.
3. **Predicados de mesh exactos** — la prueba de exactitud de `orient2d`
   requiere coordenadas `float` promovidas sin pérdida a `double`.
   Nunca "subirlo a double por seguridad".
4. **Gap del binario `.meshDeform`** — ya resuelto (arreglado, no
   replicado).
5. **Shader math en dos idiomas** — autorar en C++, transcribir a MSL y
   HLSL, verificar con cross-check numérico, no por inspección visual.
6. **Deuda SwiftUI** — `SceneGizmoOverlay` y `TimelineView`, ver Fase 2.

---

## Git

Desarrollar en la rama de feature designada, y mantener `main` sincronizado
por fast-forward después de cada commit:

```sh
git push -u origin <rama>
git checkout main && git merge --ff-only <rama> && git push origin main
git checkout <rama>
```

Cada commit explica el **porqué**, no solo el qué, y registra los bugs
encontrados durante el trabajo (varios de los más importantes de este port
salieron de tests que fallaron por razones inesperadas).

---

## La advertencia que sigue vigente

De `ROADMAP.md` § *Testing / validation strategy*:

> Los tests usan **valores golden derivados a mano** del Swift, no de la
> salida de este port. Eso atrapa bugs de C++ pero **no** sustituye al diff
> real Swift-vs-C++. Nadie debería confundir "los tests pasan" con
> "verificado idéntico a la app Swift".

El golden-dump harness (una CLI Swift que serialice salidas deterministas a
JSON para diffear contra ellas) necesita un toolchain Mac/Xcode que este
entorno Linux no tiene. Es la pieza de validación que falta, y es
independiente de las fases.

---

## Cómo leer un archivo portado

Cada header de UMeshCore abre con un comentario que dice **qué archivo
Swift porta**, qué se dejó fuera y por qué. Ese comentario es la
documentación primaria: si algo parece raro, casi siempre está explicado
ahí, normalmente citando el bug que lo causó.
