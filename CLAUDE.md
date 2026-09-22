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

45 binarios de test, 100% en verde. **Nunca dejes la suite en rojo.**

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

`SceneManager` tiene 7376 líneas y ~400 `@Published` mezclando datos de
modelo con estado de UI. **No intentes partirlo.** En su lugar:

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
| **5** | **Scene compositing, luces, física secundaria, export** | **🔨 En curso — el modelo de capa** |
| 6a | Migrar la app Mac a consumir UMeshCore | ⬜ No empezada |
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

- **`PhysicsPreviewTool`** (59 L) — mecánicamente trivial, pero su
  override de pose no tiene consumidor: `EditorScene` no posee una
  instancia viva de `PhysicsConstraintSystem`. Se desbloquea en Fase 5.
- Los intercepts de IK-builder y Bind-Mode en `ToolManager` — ninguno de
  los dos subsistemas está modelado en `EditorScene`.
- `solveRigPose` / `rigPose(atFrame:)` de `SceneAnimator` — Fase 5.

**Deuda marcada, primera mordida hecha** (Riesgo #6 del ROADMAP):
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

## Fase 5 — la fase actual

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

### Pendiente, en el orden que recomienda `HANDOFF.md`

| # | Portar | Referencia Swift | L | Notas |
|---|---|---|---|---|
| 1 | `PhysicsPreviewTool` | Fase 2, bloqueado | 59 | Solo necesita que `EditorScene` tenga una instancia viva de `PhysicsConstraintSystem`. |
| 2 | Export | `Export/ExportManager.swift` (135) + `ExportSettings.swift` | — | |

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
