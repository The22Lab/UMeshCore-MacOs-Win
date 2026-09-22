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

39 binarios de test, 100% en verde. **Nunca dejes la suite en rojo.**

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
| **4** | **Capa de geometría de render compartida** | **🔨 En curso — 7 hechas, 2 restantes (1 descartada: código muerto)** |
| 5 | Scene compositing, luces, física secundaria, export | ⬜ No empezada |
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
  — el escritor Swift no tiene lector), y `BinaryExporter` con 6 de 7
  chunks.
- **`.umesh` nativo**: módulo JSON propio, todas las conversiones
  `Saved*`, el manifiesto `ProjectDocument`, y la capa de paquete
  (directorio + `Assets/` con deduplicación SHA-256, escritura atómica,
  sniffing de los tres formatos que comparten la extensión).
- **UMJSON**: modelo, builder y writer. Modelo deliberadamente separado de
  `Saved*` — IDs string, arrays planos, `"stepped"` en vez de `"hold"`, y
  unidades preservadas por campo (un hueso usa radianes para shear; un
  sprite usa **grados**).

**Pendiente:** `writeScenesChunk` y las secciones de Scene-compositing del
manifiesto → Fase 5. Embebido base64 de texturas en UMJSON (`AssetRecord`
lleva ruta, no bytes).

**Permanente:** `SavedEditorState` (escalares de UI de `AppState`) no se
porta — es estado de shell. Se preserva textualmente vía
`ProjectDocument::unrecognized`, testeado de punta a punta.

---

## Fase 4 — la fase actual

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

### Pendiente, en orden de dependencia

| # | Portar | Referencia Swift | L | Notas |
|---|---|---|---|---|
| 8 | Presupuesto de frame | `Render/SceneRenderBudget.swift` | 174 | |
| 9 | Shader math de referencia | `Render/SceneGPU/SceneShaders.metal` | 1022 | Autorar **una vez** en C++ y transcribir a MSL y HLSL con cross-check numérico (ROADMAP Riesgo #5). |

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

**No existen en este repo.** Verificado con `find . -name "verify_*.py"`.
Las cifras son la mejor evidencia de que esa matemática fue validada, pero
**no se pueden re-ejecutar desde aquí**. Tenlo presente al portar culling y
los structs de GPU: el comentario describe una verificación que no está a
mano. Si aparecen en otra copia del proyecto, traerlos sería valioso.

---

## Fase 5 — de dónde partir cuando llegue

Todo el namespace de Scene compositing, en `Data/Scene/`. Ninguno tiene
equivalente en UMeshCore: `SceneComposition.swift` (241),
`SceneLayer.swift` (282), `SceneLight.swift` (390), `SceneCamera.swift`,
`SceneMaterial.swift`, `ScenePersistence.swift`, `ScenePlayback.swift`,
`SceneSelection.swift`.

Portarlos cierra de golpe cuatro pendientes: el chunk SCENES, las secciones
de manifiesto que hoy viven en `unrecognized`, los dos constructores de
conveniencia de `SceneProjection`, `cardCorners`/`cardPoint` de la cámara
de vuelo, y `PhysicsPreviewTool`.

Export: `Export/ExportManager.swift` (135) + `Export/ExportSettings.swift`.

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
