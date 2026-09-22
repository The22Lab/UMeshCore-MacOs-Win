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

33 binarios de test, 100% en verde. **Nunca dejes la suite en rojo.**

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
| **4** | **Capa de geometría de render compartida** | **🔨 En curso — 1 de ~9 piezas** |
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

**Deuda marcada, no empezada** (Riesgo #6 del ROADMAP):
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

### Pendiente, en orden de dependencia

| # | Portar | Referencia Swift | L | Notas |
|---|---|---|---|---|
| 1 | Frustum culling | `Render/SceneCulling.swift` | 145 | Los planos se **extraen de la misma view-projection matrix** por la que divide el dibujo (Gribb & Hartmann); reconstruirlos desde la cámara los deja derivar. Regla asimétrica: puede conservar algo invisible (trabajo perdido), **nunca** descartar algo visible (objeto que desaparece). |
| 2 | Cámara de vuelo | `Render/SceneViewProjection.swift` | 177 | `cameraBasis` ya está dentro de `SceneProjection.h`; falta órbita y `eye`. |
| 3 | Structs POD de GPU | `Render/SceneGPU/SceneGPUTypes.swift` | 278 | **Leer primero su cabecera**: el padding está deletreado a mano porque Metal alinea `float3` a 16 bytes. El drift produce una luz leyendo el radio de su vecina. |
| 4 | Paleta de skinning | `Render/SceneGPU/SceneSkinPalette.swift` | 170 | |
| 5 | Layout + mallas de gizmo | `SceneGizmoLayout.swift` (135) + `SceneGizmoMeshBuilder.swift` (478) | 613 | Depende de `worldLengthForPixels` (ya portado). |
| 6 | Geometría auxiliar | `ArcGeometryBuilder.swift` (152) + `SphereGeometryBuilder.swift` (140) | 292 | |
| 7 | Matemática de luces | `Render/SceneLighting.swift` | 544 | Solapa con Fase 5: portar la *matemática*, no el modelo `SceneLight`. |
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
conveniencia de `SceneProjection`, y `PhysicsPreviewTool`.

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
