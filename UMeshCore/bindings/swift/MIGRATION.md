# Fase 6a — desconexión total del core Swift

Decisión del usuario (sesión de la Fase 6a, después de la rebanada 0):
**al compilar la app en el Mac, la interfaz tiene que correr sobre el core
C++ y nada del core Swift original puede estar en funcionamiento.** El core
Swift se conserva solo como referencia.

Esto reemplaza la estrategia anterior ("los dos cores conviven y se borra
cada archivo Swift cuando su rebanada tiene test de paridad"). La
consecuencia práctica: el core Swift no puede ser el juez de paridad en el
Mac, porque no va a estar compilado. La paridad se sigue afirmando como
hasta ahora — tests C++ con valores derivados a mano del Swift — y el Swift
original queda legible en `Reference/` para derivarlos.

---

## La arquitectura

```
┌────────────────────────── Mac (SwiftUI) ───────────────────────────┐
│  Vistas (≈42 000 L, SIN TOCAR)                                     │
│     │ leen/escriben structs Swift, Binding, closures inout         │
│  SceneManager (Swift)  = ADAPTADOR                                 │
│     · estado de UI puro (paneles, hover, notices): @Published      │
│     · modelo: propiedades computadas sobre `core`                  │
│     · cada operación: una llamada a `core`                         │
│     · announceChange() a 12 Hz + tokens: se conservan tal cual     │
│  Bridge/ (Swift): SIMD↔Vec, UUID↔Uuid, structs espejo ↔ C++        │
└──────────────────────────────┬─────────────────────────────────────┘
                               │  import UMeshCore
┌──────────────────────────────▼─────────────────────────────────────┐
│  umeshcore::EditorScene  = el SceneManager de verdad               │
│     · estado de modelo + todas sus operaciones, con tests          │
│     · el MISMO que usará el shell de Windows                       │
│  Interop/SwiftBridge.h: formas planas de los variants,             │
│     contenedores nombrados                                         │
└────────────────────────────────────────────────────────────────────┘
```

**Por qué `EditorScene` y no llamadas sueltas a algoritmos.** Si el estado
se quedara en Swift y solo se delegaran los algoritmos, las ~220
operaciones de `SceneManager` que *no* son algoritmos sueltos
(`reparentBone`, `deleteHierarchy`, `keySceneLight`, `pasteCopiedKeyframes`…)
seguirían siendo lógica del core Swift en funcionamiento — justo lo que el
usuario pidió que no quedara. Y el shell de Windows tendría que
reescribirlas en C#, que es exactamente lo que UMeshCore existe para
evitar. `EditorScene.h` ya lo anticipaba: "cada fase posterior absorbe más
de la superficie de SceneManager en esta clase".

**Por qué siguen existiendo structs Swift (`Bone`, `SceneImage`…).** Las
vistas sostienen copias de valor, SwiftUI diffea por `Equatable`, y hay
`Binding` encadenado sobre campos almacenados
(`InspectorPanelView.swift:1247`). Un tipo C++ importado no da nada de eso
sin reescribir las vistas. Así que quedan como **declaraciones de datos sin
lógica** — el equivalente de un header — y toda la lógica que tenían pasa
a C++.

---

## Las etapas

### A — `EditorScene` absorbe `SceneManager` (C++, verificable aquí)

La interfaz usa **264 miembros distintos** de `SceneManager` (medido con
grep sobre las vistas, `Render/` y `Export/`). `EditorScene` tiene hoy ~40.
Por área, en orden de dependencia:

| Área | Qué | Estado |
|---|---|---|
| A0 | `Interop/SwiftBridge.h`: formas planas de los 3 variants, contenedores nombrados | ✅ |
| A1 | Esqueleto y jerarquía: selección de huesos, `reparentBone`, `hierarchyItems` (mover/renombrar/borrar), `mirroredBone`/`mirrorBonePose`/`flipBonePose`, `duplicateSelected` | ✅ (con `mirrorMeshWeights`) |
| A2 | Imágenes y orden de dibujo: `updateImage`, `updateVisibility`, `imagesInDrawOrder`, `moveImageInDrawOrder`/`nudge`/`sortDrawOrderByBoneDepth`, `bindImage`/`unbindBoneFromImage`/`autoBindImage`, `addImage`, `captureCurrentArrangement` | ✅ (auto-bind en A6b) |
| A3 | Skins, slots, attachments (≈19 miembros) | ✅ |
| A4 | Constraints: crear/duplicar/borrar/renombrar los 4 tipos, cadenas, targets, valores, `bakePhysicsToKeys`; el **IK builder** (`IKBuilder.swift`, 201 L) | ✅ |
| A5 | Animación: selección/copia/pegado/movimiento de keyframes, tangentes, interpolación, claves de transform/constraint/draw order/attachment/eventos, transporte (`togglePlayback`, `stepFrames`, rango, `timecode`); los flags de modo de canvas, `leaveSpriteModes` y la escalera de Escape | ✅ |
| A6 | Mesh: `MeshTool` (672 L), generar/trazar/resetear, borrar vértices, pintura de pesos, auto-weight, normalizar/espejar/limpiar. **Necesita el pipeline de alfa**: se inyecta un muestreador (puntero a función C + `void*`) desde el shell | 🔨 A6a + A6b hechos: la mitad de edición de `Mesh` sin textura (`Mesh/MeshEditing.cpp`) y las ~45 operaciones de mesh/pesos/pincel/auto-bind de `SceneManager` (`EditorSceneMesh.cpp`). Falta: trazado por alfa (A6c) y `MeshTool` (A6d) |
| A7 | Scene: composiciones, capas, luces, claves de luz/cámara, `frameSceneView`, `alignSceneCameraToView`/`alignSceneViewToCamera` | ✅ |
| A8 | Persistencia: `ProjectDocument` ↔ `EditorScene` (`restoreProject`, `projectDocumentFrom`, la validación `restored*()`) | ✅ |

### Lo que salió portando (bugs de Swift arreglados, no replicados)

- **Deshacer borraba todas las claves de attachment.** `pruneSceneAnimationTracks`
  solo protege las pistas de dominio `.scene` y a todas las demás les pregunta
  "¿eres de un constraint vivo?". Una pista de attachment es de un **slot**,
  así que fallaba siempre — y el prune corre en cada `applySnapshot`, o sea en
  cada undo. Test: `testUndoKeepsAttachmentKeys`.
- **"Ordenar por profundidad de hueso" ordenaba al revés.** La lista de orden de
  dibujo va de delante hacia atrás (índice 0 = delante; `MetalRenderer` y los
  dos renderers de Scene la recorren `.reversed()` por eso). Swift ordena por
  profundidad **ascendente**: sprites sueltos delante y el antebrazo **detrás**
  del brazo — lo contrario de las tres cosas que su comentario promete. Test:
  `testSortByBoneDepthPutsTheDeeperBoneInFront`.

- **El primer auto-key de un constraint en Animator perdía el valor autorado.**
  `setConstraintScalar/Flag/Vector` escriben el valor nuevo **antes** de
  capturar el registro de setup, así que el registro guarda el valor
  *animado* — justo lo que el comentario de `ensureConstraintSetupCaptured`
  dice evitar. Nada captura antes (verificado por grep): quitar todas las
  claves después "restauraba" el valor animado. `keyConstraintProperty`, que
  captura sin escribir, siempre lo hizo bien. Test:
  `testAnEditAutoKeysInAnimatorAndKeepsTheSetupValue`.

- **Los eventos nunca se disparaban durante la reproducción.** `tickPlayback`
  escribe `currentFrame` directamente y no llama a `fireEventsCrossed`; sus
  dos únicos llamantes (grep) son `setCurrentFrame` y `setAnimationTime`, o
  sea arrastrar el playhead y los pasos de frame. Un evento de "pisada"
  sonaba al hacer scrub y jamás al darle a Play. La rama de salto de loop de
  `fireEventsCrossed` solo es alcanzable desde la reproducción: en Swift es
  código muerto. Al hacerla viva se corrigen dos cosas más de esa rama,
  documentadas en `EditorSceneAnimation.cpp`: usa los límites de la
  **sesión** (no el rango del proyecto, que dispararía claves que el loop
  nunca cruzó), y ordena cada tramo por separado (el orden por frame de la
  unión ponía el inicio de la vuelta nueva antes del final de la vieja).
  Tests: `testEventsFireWhilePlaying`,
  `testALoopWrapFiresTheEndOfTheOldLapThenTheStartOfTheNew`.

- **Abrir un proyecto conservaba el historial de undo del anterior.** El
  `SceneManager` es un `let` de `AppState` que vive toda la sesión, y ni
  `restoreProject` ni `AppState.restore` tocan su `undoRedoManager` (grep:
  solo push/undo/redo). Undo tras Abrir devolvía los sprites del proyecto
  anterior — con texturas que ya no están en el asset store. Test:
  `testOpeningAProjectStartsAFreshHistory`.
- **`pruneSceneSelection` no tenía ningún llamante.** Su comentario dice
  que se llama "donde una escena se reemplaza entera — abrir, undo"; grep
  encuentra solo la declaración. Deshacer "añadir luz" dejaba seleccionada
  una luz inexistente. Ahora la llaman `applySnapshot` y `restoreProject`.
  Test: `testUndoDropsASelectionWhoseLightIsGone`.

- **"Flip" y "Pose → partner" no hacían nada fuera del modo Pose.**
  Escriben solo `localTransform` y llaman `applyAnimations()`, que en
  Editor devuelve cada hueso a su `baseTransform` y en Animator re-muestrea
  el clip encima. Ahora siguen la regla de todos los setters de hueso:
  Editor escribe el setup, Animator keya los canales cambiados. Test:
  `testFlipSticksInEditorMode`.
- **Un nombre con una palabra parecida a un marcador no encontraba pareja.**
  `arm_lower_L` contiene "_l" (de "_lower"), se lee como `arm_rower_L` y
  se rinde. Ahora se prueban todos los marcadores en el orden de Swift y
  gana el primero que nombra un hueso (donde Swift encontraba pareja, es
  la misma). Y la convención `L_arm` que el comentario Swift promete y su
  tabla no tenía, anclada al inicio y probada al final. Test:
  `testAMarkerLikeWordDoesNotHideThePartner`.

Los ocho tests se comprobaron volviendo a poner la conducta Swift: fallan.

**Encontrado y NO arreglado (decisión pendiente, pinned por test):**

- `connectingVertices` no puede **insertar** una arista: el kernel trata
  las restricciones como "aristas que el paso de Lawson no puede voltear",
  sin recuperación de aristas. Unir dos vértices que el ear-clip no unió
  registra la arista y no cambia ningún triángulo — igual en Swift. Solo
  protege una arista que ya existe. Arreglarlo es añadir recuperación de
  aristas (CDT) al kernel: un algoritmo, no un parche. Test:
  `testAConnectedEdgeIsNeverFlippedAway`.
- El grid 3×3 de `generated()` (sprite que aún es un quad) declara como
  outline solo las **cuatro esquinas**, con los cuatro puntos medios de
  arista encima de él: el validador lo marca (I5). Así lo construye Swift;
  el render no lo nota, pero el indicador de salud del mesh sí debería. Se
  deja como está hasta confirmar en el Mac qué muestra la app.

**Rarezas de Swift replicadas a propósito, con nota en el código:** el
`didSet` de `projectFramesPerSecond` se dispara dos veces ante un valor
fuera de rango y reinicia la sesión aunque la tasa efectiva no cambie; el
reinicio es un `play()` pelado (rango del proyecto, no el de la sesión);
`duplicateSelectedKeyframes` escribe `currentFrame = minFrame` sin mover
`animationTime` ni el playhead. Y una divergencia de determinismo: la
selección de keyframes es un `Set` en Swift y cinco sitios leen su
`.first`, que no está especificado; aquí es un vector sin duplicados y el
"primero" es el primero seleccionado.

**Lo que el core no puede hacer y el shell sí.** El reloj se inyecta (como
en `ScenePlayback`): `play`/`togglePlayback`/`setProjectFramesPerSecond`
devuelven los segundos hasta el único wake que Swift programa con un
`Task` (el fin de un clip sin loop), y el shell llama a `tickPlayback`
entonces. `leaveSpriteModes` termina en Swift con
`toolManager?.setTool(.select)`; el core no ve al `ToolManager`, así que
deja `requestedToolChange = .select` y el adaptador lo ejecuta y lo
limpia. `meshEditNotice` pasa al core porque lo escriben operaciones de
mesh (A6) que viven aquí.

**Closures de Swift que no cruzan.** `updateIKConstraint(id) { $0.x = … }`
pasa a `replaceIKConstraint(valor)`: el adaptador lee, aplica su closure a
la copia y la devuelve. Mismo efecto (un paso de undo y re-animar). Es el
patrón para todos los `update…(id) { … }`.

Cada área: leer el Swift, portar a `EditorScene` (o un hermano si el área
es grande), tests con valores derivados a mano. **Ningún archivo Swift se
toca durante la etapa A**, así que la app del Mac sigue compilando igual
que hoy.

### B — `SceneManager` pasa a adaptador (Swift, SIN compilador aquí)

1. **Bridge/**: conversiones de tipos hoja y de cada struct espejo.
2. **B0 — el estado se muda a C++**: las propiedades de modelo de
   `SceneManager` pasan a ser computadas sobre `core` (con caché del espejo
   Swift invalidada por token — `skeleton` se lee 82 veces en las vistas y
   el renderer lo lee por frame). Los métodos Swift viejos siguen
   funcionando a través de los setters: cada paso compila y se comporta
   igual.
3. **B1…Bn — la lógica se muda**, área por área: el cuerpo de cada método
   pasa a una llamada a `core`.
4. **Los originales a `Reference/SwiftCore/`** (`git mv`, conserva la
   historia). Fuera del grupo sincronizado de Xcode, así que no compilan.
5. **`Render/` y `Export/`**: los archivos Swift que tienen gemelo C++
   (`SceneProjection`, `SceneCulling`, `SceneLighting`, `SceneSkinPalette`,
   `SceneGizmoMeshBuilder`, `SceneRenderBudget`, `BinaryExporter`, UMJSON,
   `ExportSettings`, `GraphViewport`, etc.) se sustituyen por el gemelo.

**Lo que se queda en Swift porque es shell, no core**: `AssetManager`
(PNG → `MTLTexture`), `TextureAsset`, `MetalDeviceProvider`,
`PlatformColors`, `PlatformFeedback`, `KeyboardShortcutHost`,
`ProjectFolderAccess` (bookmarks con ámbito de seguridad), los renderers
Metal, y el estado de UI de `AppState`.

---

## Restricciones de interop (escribir el lado C++ para ellas)

- **Ningún `std::variant` en una firma que Swift llame.** Usar las formas
  planas de `SwiftBridge.h`.
- **Swift no instancia templates.** Todo contenedor que Swift tenga que
  *construir* necesita un `using` en C++ (`UuidList`, `BoneList`…). Los
  que solo *lee* no.
- **Nada de `std::function`.** Puntero a función C + `void* context`.
- **Por valor, no por referencia**, lo que una vista lee.
- **Sin argumentos por defecto** en lo que Swift llame: no siempre se
  importan. Pasar todo explícito.

---

## Cómo se verifica

- Etapa A: CMake + ctest aquí, como todo el port.
- Etapa B: **solo en el Mac**. Aquí no hay `swift`/`swiftc`/`xcodebuild`.
  El bucle es: se escribe el Swift, el usuario compila, pega los errores,
  se corrigen. Por eso B va por áreas y cada commit deja la app
  compilable — un error se localiza en el área que se acaba de tocar.
- **Bloqueante previo**: los 4 tests de `UMeshCoreInteropSmokeTests.swift`
  tienen que pasar en el Mac. Si el interop en sí no funciona, todo lo de
  B está escrito sobre una suposición.
