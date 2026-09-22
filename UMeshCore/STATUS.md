# UMeshCore — Estado y trabajo pendiente

Documento de referencia rápida. `ROADMAP.md` es el registro detallado y
crece con cada incremento; **este archivo es el resumen escaneable**: dónde
estamos, qué falta, y de dónde sacar cada referencia.

Última actualización: fase 4 en curso (`SceneProjection` portado).
33 binarios de test, 100% en verde.

---

## 1. El plan completo, en una página

El objetivo: una librería C++ compartida (`UMeshCore`) para que macOS y una
app Windows nueva tengan comportamiento **idéntico** de rig, mesh,
animación, editor y gizmos, mientras cada plataforma conserva su UI y su
renderer nativos.

| Fase | Qué es | Estado |
|---|---|---|
| 0 | Andamiaje del repo (CMake, dirs, tests) | ✅ Completa |
| 1 | Math + modelo de datos | ✅ Completa salvo 3 conveniencias de editor |
| 2 | Lógica de editor (tools, gizmos, picking, undo) | ✅ Completa salvo lo bloqueado por Fase 4/5 |
| 3 | Serialización (binario UMSH, `.umesh` nativo, UMJSON) | ✅ Completa salvo lo de Fase 5 |
| **4** | **Capa de geometría de render compartida** | **🔨 En curso — 1 de ~8 piezas** |
| 5 | Scene compositing, luces, física secundaria, export | ⬜ No empezada |
| 6a | Migrar la app Mac a consumir UMeshCore | ⬜ No empezada |
| 6b | Shell Windows (WinUI 3 + DirectX) | ⬜ No empezada |

### Principios que rigen todo el port

Estos ya están aplicados de forma consistente y conviene no romperlos:

1. **Cero dependencias externas.** Math, harness de tests, JSON y SHA-256
   están escritos a mano. La razón está en `ROADMAP.md` § *Repository
   layout*: los call sites de `simd` son lo bastante idiosincráticos como
   para que traducir a otra librería fuese en sí una fuente de bugs de
   transcripción.
2. **"Inyectar lo necesario"** en vez de portar los god objects
   (`SceneManager`, 7376 líneas; `AssetManager`). `EditorScene` es el
   agregado mínimo; los assets se pasan como parámetro explícito.
3. **Una divergencia nunca es silenciosa.** Cuando el port se aparta del
   Swift (bug arreglado, formato desambiguado, campo diferido) queda
   documentado *en el archivo* con el porqué, y con test.
4. **Los tests afirman propiedades documentadas**, no re-derivan la
   implementación. Los valores esperados se derivan a mano del Swift, no
   de la salida de este port.

---

## 2. Qué falta para terminar la Fase 4

Es la fase actual. Objetivo: geometría/batching/culling/proyección/luz
agnóstica de plataforma, expuesta como buffers POD que consumen backends
finos de Metal y DirectX.

### Hecho

- **`Render/SceneProjection.h/.cpp`** ← `Render/SceneProjection.swift` (479 L).
  La única conversión world→pixels: view matrix, proyección perspectiva,
  división por w, recorte near/far en espacio de clip, rayos para arrastre
  de gizmos. 20 tests.

### Pendiente, en orden sugerido

El orden importa: cada pieza depende de la anterior.

| # | Portar | Referencia Swift | L | Notas |
|---|---|---|---|---|
| 1 | Frustum culling | `Render/SceneCulling.swift` | 145 | Los planos se **extraen de la misma view-projection matrix** por la que divide el dibujo (Gribb & Hartmann) — reconstruirlos desde la cámara los deja derivar. Regla asimétrica: puede conservar algo invisible (trabajo perdido), nunca descartar algo visible (objeto que desaparece). |
| 2 | Base de cámara de vuelo | `Render/SceneViewProjection.swift` | 177 | `cameraBasis` ya está portado dentro de `SceneProjection.h`; falta el resto (órbita, eye). |
| 3 | Structs POD de GPU | `Render/SceneGPU/SceneGPUTypes.swift` | 278 | **Leer primero el comentario de cabecera**: el padding está deletreado a mano porque Metal alinea `float3` a 16 bytes. El drift aquí produce una luz leyendo el radio de su vecina. |
| 4 | Paleta de skinning | `Render/SceneGPU/SceneSkinPalette.swift` | 170 | |
| 5 | Layout + mallas de gizmo | `SceneGizmoLayout.swift` (135) + `SceneGizmoMeshBuilder.swift` (478) | 613 | Depende de `worldLengthForPixels` (ya portado). |
| 6 | Geometría auxiliar | `ArcGeometryBuilder.swift` (152) + `SphereGeometryBuilder.swift` (140) | 292 | |
| 7 | Matemática de luces | `Render/SceneLighting.swift` | 544 | Solapa con Fase 5; portar la *matemática*, no el modelo `SceneLight`. |
| 8 | Presupuesto de frame | `Render/SceneRenderBudget.swift` | 174 | |
| 9 | Shader math de referencia | `Render/SceneGPU/SceneShaders.metal` | 1022 | Autorar **una vez** en C++ y transcribir a MSL y HLSL, con cross-check numérico (ROADMAP Riesgo #5). |

### Qué NO portar de `Render/`

Es shell de plataforma, se queda en cada app:
`MetalRenderer.swift` (2159), `SceneMetalRenderer.swift` (1922),
`SceneFrameRenderer.swift` (2009), `TouchInputMTKView`/`ToolInputMTKView`,
`SceneMetalView`, `PlayheadView`, `KeyframeDiamondIcon`, `DisplayClock`.

### ⚠️ Advertencia sobre las referencias de verificación

Los archivos Swift de `Render/` citan repetidamente harnesses de
verificación — `verify_scene_perspective.py`, `verify_scene_near_clipping.py`,
`verify_scene_culling.py`, `verify_scene_gizmo_drag.py`,
`verify_scene_gpu_transcription.py`, todos bajo `Editor/` — con cifras
concretas ("313 px", "51 capas de 20 000 cámaras", "1.4e-08 px").

**Esos archivos NO existen en este repo.** Ni en `Editor/`, ni en ningún
otro sitio (verificado con `find . -name "verify_*.py"`). Las cifras que
citan los comentarios son la mejor evidencia disponible de que esa
matemática fue validada, pero **no se pueden re-ejecutar desde aquí**. Al
portar culling y los structs de GPU conviene tenerlo presente: el
comentario describe una verificación que no está a mano.

---

## 3. Pendientes de fases anteriores

Cada uno está documentado en su archivo con el porqué. Ninguno es un hueco
silencioso.

### Fase 1 — quedan 3 conveniencias de editor

De `Data/Mesh.swift`, todas de tiempo de edición (no de runtime por frame):

- `generated()` / `generatedGrid` — generación procedural de puntos
  interiores para un mesh recién creado.
- El flujo de triángulos manuales: `sanitizedManualTriangles`,
  `triangulatedIndicesWithInternalEdges`.
- La heurística de puntuación de Auto-Bind (qué huesos *sugiere* un
  sprite). Distinta de `autoBindWeights`, que sí está portado.

### Fase 2 — bloqueado por el pipeline de assets (Fase 4/5)

La raíz común: **`CanvasPicking.imageHit` necesita muestrear el canal alfa
de una textura cargada**, y no hay pipeline de decodificación de imágenes.

- `hitTestScreen`, `hitTestRect`, `hitTestSelectionTarget`,
  `boundsForScene`, `boundsForImage`.
- El marquee de *sprites* en `ToolManager` (el de huesos sí está: es
  geometría pura).
- **`MeshTool`** (`Core/Tools/MeshTool.swift`, 672 L) — la tool más grande.
  Cada submodo (Bind Mode, Weight Paint, creación de hull, edición de
  vértices) pasa por el pipeline de alfa **o** por mutadores de mesh que no
  existen (`updateMeshVertex`, `insertMeshVertex`,
  `deleteSelectedMeshVertices`, …), que a su vez necesitan
  `Mesh::clampedPositionInsideHullIfNeeded` → `hullVertexIndices`,
  `pointInsideHull`, `pointOnHullBoundary`.

### Fase 2 — bloqueado por otras razones

- **`PhysicsPreviewTool`** (`Core/Tools/PhysicsPreviewTool.swift`, 59 L) —
  mecánicamente trivial, pero su override de pose no tiene consumidor:
  `EditorScene` no posee una instancia viva de `PhysicsConstraintSystem`.
  Se desbloquea en Fase 5.
- Los intercepts de IK-builder y Bind-Mode en `ToolManager` — ninguno de
  los dos subsistemas está modelado en `EditorScene`.
- `solveRigPose` / `rigPose(atFrame:)` de `SceneAnimator` — muestrear un
  rig en un frame arbitrario para una instancia de Scene compositing.
  Fase 5.

### Fase 2 — deuda marcada, no empezada (Riesgo #6 del ROADMAP)

`SceneGizmoOverlay.swift` (1732 L) y `TimelineView.swift` (4326 L) tienen
**matemática real de hit-testing y curvas dentro de cuerpos de vista
SwiftUI**. Hay que extraerla a UMeshCore *antes* de que la UI de Windows
necesite lógica equivalente: portar desde un cuerpo de vista SwiftUI
directamente es mucho más arriesgado que extraer primero en el Mac.

### Fase 2 — decidido no portar

Los cuatro métodos privados de rotación-hover de `ToolManager`
(`updateRotationHover`, `handleRotationMouseDown`, `handleRotationMouseDrag`,
`syncRotationState`): verificado por grep en todo el árbol Swift que tienen
**cero call sites**. Código muerto demostrable.

### Fase 3 — lo que queda es de Fase 5 o permanente

- `writeScenesChunk` (chunk SCENES del binario) y las secciones de
  Scene-compositing del manifiesto → Fase 5.
- Embebido base64 de texturas en UMJSON — `AssetRecord` lleva ruta, no
  bytes.
- **Permanente:** `SavedEditorState` (escalares de UI de `AppState`). Es
  estado de shell, no del core. Se preserva textualmente vía
  `ProjectDocument::unrecognized`, testeado de punta a punta.

---

## 4. Fase 5 — de dónde partir cuando llegue

Todo el namespace de Scene compositing, en `Data/Scene/`. Ninguno tiene
equivalente en UMeshCore todavía:

`SceneComposition.swift` (241), `SceneLayer.swift` (282),
`SceneLight.swift` (390), `SceneCamera.swift`, `SceneMaterial.swift`,
`ScenePersistence.swift`, `ScenePlayback.swift`, `SceneSelection.swift`.

Al portarlos se cierran de golpe tres pendientes: el chunk SCENES, las
secciones de manifiesto que hoy viven en `unrecognized`, y los dos
constructores de conveniencia de `SceneProjection`.

Export: `Export/ExportManager.swift` (135) + `Export/ExportSettings.swift`.

---

## 5. Referencias — dónde está cada cosa

| Qué | Dónde |
|---|---|
| Registro detallado, fase por fase | `UMeshCore/ROADMAP.md` |
| Riesgos nombrados (god object, física, exactitud, shaders, deuda SwiftUI) | `ROADMAP.md` § *Named risks* |
| Fuente Swift original | `../UltraMesh 2d animation/` |
| Contrato del formato UMJSON | `../UltraMesh 2d animation/Export/JSON/ULTRAMESH_JSON_FORMAT.md` ✅ existe |
| Harnesses `verify_*.py` citados por los comentarios Swift | ❌ **no existen en el repo** — ver § 2 |
| Estrategia de validación (golden-dump, aún no construido) | `ROADMAP.md` § *Testing / validation strategy* |

### Cómo leer un archivo portado

Cada header de UMeshCore abre con un comentario que dice **qué archivo
Swift porta**, qué se dejó fuera y por qué. Ese comentario es la
documentación primaria: si algo parece raro, casi siempre está explicado
ahí, normalmente citando el bug que lo causó.

### Construir y testear

```sh
cd UMeshCore
cmake --build build -j4
cd build && ctest --output-on-failure
```

---

## 6. La advertencia que sigue vigente

De `ROADMAP.md` § *Testing / validation strategy*, y sigue siendo cierta:

> Los tests usan **valores golden derivados a mano** del Swift, no de la
> salida de este port. Eso atrapa bugs de C++ pero **no** sustituye al diff
> real Swift-vs-C++. Nadie debería confundir "los tests pasan" con
> "verificado idéntico a la app Swift".

El golden-dump harness (una CLI Swift que serialice salidas deterministas a
JSON para diffear contra ellas) necesita un toolchain Mac/Xcode que este
entorno Linux no tiene. Es la pieza de validación que falta, y es
independiente de las fases.
