# Nota de traspaso — Fase 6a, etapa B en curso

Escrita el 2026-09-23, para el agente que siga. Sustituye a la nota de fin
de Fase 5 (sigue en el historial de git: `git show 70c6f93:UMeshCore/HANDOFF.md`).

**Cómo usar esta nota.** Es el punto de arranque: con ella y `../CLAUDE.md`
(que se carga solo) tienes que poder saber qué hacer primero y cómo
comprobarlo. No repite el detalle, que vive en tres sitios y conviene no
copiar una cuarta vez:

- `../CLAUDE.md` — estado del port fase por fase y las cuatro convenciones.
- `bindings/swift/MIGRATION.md` — el plan de 6a, la arquitectura, los bugs
  de Swift arreglados y los hallazgos fijados.
- `ROADMAP.md` — el porqué largo de cada decisión.

---

## 1. Qué es esto y qué pidió el usuario

`UltraMesh 2d animation/` es una app Swift/SwiftUI/Metal de animación 2D
por mesh esquelético (~69 000 líneas). `UMeshCore/` es su core portado a
C++ (cero dependencias), para que el Mac y una futura app de Windows
tengan exactamente el mismo comportamiento.

La decisión vigente del usuario, textual:

> "quiero que desconectes el Swiftcore original por completo del interfaz,
> al compilar la app en Mac solo quiero ver el interfaz con el nuevo core
> c++, no quiero nada del original core en función, solo mantenlo para que
> lo uses de referencia"

Es decir:

- La interfaz SwiftUI **no se reescribe**; se queda como está.
- Debajo de la interfaz corre el core C++.
- El core Swift acaba en `Reference/SwiftCore/`, fuera del target.
- La app de Windows (6b) viene después, sobre el mismo core.

El usuario escribe en español y compila en su Mac (Xcode, macOS 26/27 SDK,
Swift 6.2 en modo de lenguaje 5).

---

## 2. Dónde está el trabajo

- **Rama:** `claude/umeshcore-cpp-port-qpk10t`.
- **`main`:** se mantiene sincronizado por fast-forward después de *cada*
  commit (ver § 9).
- **Suite C++:** 68 binarios, todos en verde. Se ejecuta con
  `cd UMeshCore && cmake --build build -j4 && cd build && ctest --output-on-failure`.
  Si `build/` no existe, primero `cmake -S . -B build`.

Commits de la fase 6a, del más nuevo al más viejo:

```
7de0d2e  fix: los 5 errores de compilación de BridgeRoundTripTests (Mac)  ← ÚLTIMO
a40d7ac  B-1a/b: el puente Swift↔C++ del rig y los sprites
d9145e4  fix: test Swift de contorno plegado desactualizado (Mac lo confirmó)
30c138f  fix: los tests importan el módulo `UltraMesh` (no UltraMesh_2d_animation)
a7d798f  A6d: MeshTool + ToolManager completo — ETAPA A COMPLETA
9441c8e  picking por alfa (AssetAlphaStore)
7142f70  A6c: Auto-Mesh sobre AlphaMask
c9aefa9  A6b + A2: operaciones de Mesh mode y Auto Bind
52abf38  A6a: mitad de edición de Mesh.swift sin texturas
6037ccd  A1: espejado de huesos y pesos
94fe58b  A7 + A8: Scene y abrir/guardar proyecto
d2a7e2e  A5: animación y transporte
2f58970  A4: constraints
62ab340  A1–A3: núcleo estructural de EditorScene
0cbe392  cambio a desconexión total + SwiftBridge (A0)
06ea345  fix pbxproj: nombres de target viejos
eb86360  rebanada 0: UMeshCore cableado en el proyecto Xcode
```

---

## 3. Estado por fases

| Fase | Qué es | Estado |
|---|---|---|
| 0 | Estructura del repo, CMake, tests | ✅ |
| 1 | Matemáticas y modelo de datos | ✅ |
| 2 | Lógica de editor: 8 herramientas, gizmos, picking, undo | ✅ |
| 3 | Formatos: binario UMSH, `.umesh`, UMJSON | ✅ (falta base64 de texturas en UMJSON) |
| 4 | Geometría de render compartida | ✅ |
| 5 | Scene: composición, luces, física, export | ✅ |
| 6a, etapa A | `EditorScene` hace todo lo que la UI le pide a `SceneManager` | ✅ |
| **6a, etapa B** | **`SceneManager` Swift pasa a ser un adaptador sobre el core** | **🔨 en curso, tramo B-1** |
| 6b | App de Windows (WinUI 3 + DirectX) | ⬜ sin empezar |

---

## 4. Cómo se trabaja en la etapa B (léelo antes de tocar Swift)

**En este entorno no hay compilador de Swift.** No existen `swift`,
`swiftc` ni `xcodebuild`, así que todo el Swift llega sin haberse
compilado nunca. Solo el Mac del usuario lo verifica. El bucle es:

1. Escribes el Swift, y la parte C++ que necesite, con sus tests aquí.
2. Commit, push y fast-forward de `main`.
3. Le pides al usuario: `git pull`, ⇧⌘K (limpiar) y ⌘U. Que te pegue
   **solo lo que salga en rojo**: errores de compilación o tests
   fallidos, con archivo:línea y mensaje.
4. Corriges y vuelves al paso 2.

Por eso cada tramo tiene que dejar la app compilable, y conviene que sea
pequeño: así un error apunta al área que se acaba de tocar.

**Lo aprendido en los ciclos de ⌘U anteriores:**

- **El módulo de la app se llama `UltraMesh`**, no `UltraMesh_2d_animation`.
  El target es `UltraMesh` y su `PRODUCT_NAME` es `$(TARGET_NAME)`. Los
  tests usan `@testable import UltraMesh`.
- **Teclas accidentales en el editor de Xcode del usuario.** Dos veces
  aparecieron errores que no estaban en el repo: `reAAlipped` en
  `MeshKernel.swift` y `pointxs` en `MeshKernelTests.swift`. Antes de
  buscar un bug, compara con el repo (`grep`). El arreglo es que el
  usuario haga `git restore "<ruta>"`. Pídele un `git status` si lo que
  pega no cuadra con el código.
- **Los warnings amarillos de `@MainActor` se ignoran.** El proyecto tiene
  `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` y está en Swift 5, así que el
  core viejo genera decenas de warnings del tipo "Call to main
  actor-isolated … in a nonisolated context". Son de archivos que van a
  salir del target; no hay que arreglarlos. `UIRequiresFullScreen` y
  `onChange(of:perform:)` tampoco importan.
- **`UUID(core:)` no resuelve desde el target de tests.** El compilador
  solo ofrecía `UUID()`, mientras `SIMD2<Float>(core:)` y `id.core` sí
  resolvían en el mismo archivo. Desde otro módulo, usa `CoreUUID.uuid(_:)`
  (en `Bridge/LeafBridge.swift`). No se sabe si el problema es de
  visibilidad de miembros o de aislamiento dentro del autoclosure de
  `XCTAssert`, así que también se sacan las conversiones fuera de las
  autoclosures.
- **Diccionarios con valores opcionales.** En un literal
  `[String: UUID?]`, un slot vacío se escribe `nil as UUID?`, no
  `.some(nil)`. Para comparar un `UUID??`, declara el tipo explícitamente.
- **Un test Swift que falla puede estar desactualizado.**
  `MeshKernelTests.testFoldedOutlineIsRejected` esperaba `.ringFoldsBack`,
  y el algoritmo lanza `.ringSelfIntersecting` antes. El port C++ lo había
  predicho y el Mac lo confirmó (`d9145e4`).
- **Lo que ya funciona en el Mac** (y por tanto se puede usar sin miedo):
  - `import UMeshCore` y `CxxStdlib`;
  - structs C++ con sus campos;
  - `std::vector` con `map`/`for` y `push_back`, a través de alias
    nombrados;
  - `std.string` ↔ `String`;
  - `switch` sobre casos de `enum class` C++ (`.Translate`…);
  - pasar `&x` a parámetros `T&`;
  - `UnsafeMutablePointer<EditorSession>` con `pointee`;
  - los ajustes del proyecto (`SWIFT_OBJC_INTEROP_MODE = objcxx`, las
    rutas de include), que no hay que tocar.

---

## 5. Lo hecho en la etapa B (tramo B-1, el puente)

**Objetivo del tramo:** convertir en los dos sentidos cada tipo de modelo
entre el struct Swift que usan las vistas y su gemelo C++. Es el paso
previo a que `SceneManager` guarde su estado en C++. En este tramo la app
no cambia de comportamiento: nada llama todavía al puente.

**Lado C++** (con tests aquí, en `tests/SwiftModelBridgeTests.cpp`):

- `include/umeshcore/Interop/EditorSession.h`: `EditorSession { EditorScene scene; AssetAlphaStore assets; }`,
  creado con `makeEditorSession()` y liberado con `destroyEditorSession()`.
  **La escena vive en el heap de C++ y Swift guarda un puntero.**
  `EditorScene` se puede copiar y lleva dentro el historial de undo (80
  snapshots en cada sentido), y Swift copia valores cuando quiere. A través
  de `pointee` no se copia nada salvo el campo que se nombra.
- `include/umeshcore/Interop/SwiftModelBridge.h`:
  - **Opcionales**, con `makeOptionalX` / `optionalHasX` / `optionalX`.
    Swift no importa el constructor plantilla de `std::optional`.
  - **Mapas como listas ordenadas**, con getter y setter:
    `meshInverseBinds`, `skinSlotEntries`, `skeletonBones`, `clipTracks`.
  - **Enums emparejados por nombre**: `xCaseCount` / `xCase` /
    `xCaseIndex`, más el nombre de formato de archivo que ya usan los
    serializadores.
  - **Constraints como structs planos** (`IKConstraintData`…), porque las
    clases tienen virtuales.
  - Contenedores con nombre (`U16List`, `VertexWeightTable`…).
- `SwiftBridge.h` (A0) ya tenía la forma plana de los tres `std::variant`.
- `Bone` ganó `operator==`.

**Lado Swift** (`UltraMesh 2d animation/Bridge/`, en el grupo
sincronizado, así que compila sin tocar el `.pbxproj`):

- `LeafBridge.swift`: UUID, SIMD, `simd_float4x4`, `Transform3D2D`,
  escalares, `CoreEnumTable` y `CoreEnums`.
- `RigBridge.swift`: `KeyframeValue`, `Keyframe`, `AnimationTrack`,
  `AnimationClip`, `Bone`, los 4 constraints, `PhysicsSettings`,
  `Skeleton`.
- `SpriteBridge.swift`: `Mesh` y sus partes, `BoneImageBinding`,
  `TransformAnimationSpace`, `SceneImage`, `HierarchyItem`, `Skin`,
  `AnimationEvent`.
- `CoreSession.swift`: dueño del `EditorSession` (lo destruye en `deinit`).
- Convención: `X(core: c)` convierte de C++ a Swift, y `x.core` de Swift a
  C++. El puente **copia, nunca decide**.
- Tests: `UltraMesh 2d animationTests/BridgeRoundTripTests.swift`, que
  comprueba `X(core: x.core) == x` con **todos** los campos distintos de
  su valor por defecto.

**`ToolManager` se dejó fuera de la sesión a propósito.** Guarda
`unique_ptr<Tool>`, no se puede copiar y Swift lo importa como
`~Copyable`. Se prueba aparte cuando lleguen las herramientas.

---

## 6. Punto exacto en que se deja ⚠️

- El último commit es `7de0d2e`. Corrige los 5 errores de compilación que
  dio `BridgeRoundTripTests.swift` en el Mac.
- **La app ya compila con `Bridge/` dentro** (confirmado en el Mac).
- **`BridgeRoundTripTests` todavía no se ha ejecutado nunca:** el target de
  tests aún no había compilado. El usuario tiene pendiente `git pull` + ⌘U
  sobre `7de0d2e`.

**Lo primero que tienes que hacer:** preguntar al usuario por el resultado
de ese ⌘U, o pedirle que lo ejecute. Si hay errores o tests en rojo,
corrígelos antes de seguir. Si un test del puente falla, el fallo está en
`Bridge/*.swift` o en el helper C++ correspondiente. El test C++ de ese
helper dice cuál de los dos lados es.

---

## 7. Lo que falta, en orden

Cada punto termina con ⌘U en verde en el Mac y la app funcionando igual.

1. **Confirmar el ⌘U de `7de0d2e`** (§ 6).

2. **B-1c, Scene en el puente.**
   - Tipos: `SceneComposition`, `SceneLayer` (su contenido cruza a través
     de `FlatSceneLayerContent`, que ya existe en `SwiftBridge.h`),
     `SceneLight`, `SceneCamera`, `SceneMaterial`, `SceneSelection`,
     `SceneViewCamera`, `SceneFrontView`.
   - Headers C++ en `include/umeshcore/Scene/*.h`; Swift en
     `UltraMesh 2d animation/Data/Scene/*.swift`.
   - Mismo patrón: helpers C++ con tests aquí, `Bridge/SceneBridge.swift`,
     y casos nuevos en `BridgeRoundTripTests`.
   - Los enums con raw value `String` de Scene ya tienen nombre en C++:
     `sceneLightKindName`, `sceneLightBlendName`, `sceneParallaxModeName`.

3. **B0, `SceneManager` guarda el estado de modelo en `CoreSession`.**
   Hechos medidos que hay que respetar:
   - Todo el estado de modelo se muta desde métodos de `SceneManager`:
     `images` es `private(set)` y nadie fuera asigna `skeleton`.
   - `images` y `skeleton` son `var` con `willSet { announceChange() }`
     (limitador a 12 Hz durante playback) y `didSet` que sube
     `rigStateToken` / `skeletonToken`. `framePoseCache`, `rigPoseCache`
     y el `RenderKey` de `SceneFrameRenderer` dependen de esos tokens.
     **Tiene que haber un `syncFromCore()` que conserve las dos cosas.**
   - `applyAnimations()` tiene 48 llamadas, todas dentro de `SceneManager`.
   - Hay una sola instancia viva: `AppState.swift:146`,
     `self.sceneManager = SceneManager()`. Las demás son de previews.
   - Rendimiento: convertir todo el esqueleto y los sprites en cada frame
     de playback cuesta. Para los clips hay que reusar la conversión si no
     cambiaron; `AnimationClip::revision()` existe en C++ y
     `AnimationClip.revision` en Swift.
   - El inventario de las 26 propiedades de modelo, 38 de UI y 5 cachés
     está en `MIGRATION.md`, y el resumen en `CLAUDE.md` § convención #2.

4. **B1…B8: cada método de `SceneManager` pasa a ser una llamada a `core`**
   seguida de `syncFromCore()`.
   - Se hace área por área, en el orden A1–A8 de `MIGRATION.md`.
   - Cada operación ya existe en C++ en `src/Editor/EditorScene*.cpp`.
   - Donde la conducta de Swift tenía un bug arreglado en C++ (los 7 bugs
     de `MIGRATION.md`), la app pasa a tener la conducta corregida. Es lo
     esperado.
   - `applyAnimations()` pasa a ser el evaluador C++.

5. **Herramientas.**
   - El `ToolManager` C++ sustituye al Swift en `ViewportView.bindShared`
     (`ViewportView.swift:761`).
   - Hay que resolver cómo guarda Swift un tipo `~Copyable`, o dárselo al
     heap igual que la escena.
   - `AssetManager`, al decodificar cada PNG, rellena el `AssetAlphaStore`
     de la sesión (un `AlphaMask` por asset), y los eventos van por las
     sobrecargas `handleMouse*(…, const AssetAlphaStore&, …)`.

6. **Render y export.** Los gemelos Swift se sustituyen por el C++:
   `SceneProjection`, `SceneCulling`, `SceneLighting`, `SceneSkinPalette`,
   `SceneGizmoMeshBuilder`, `SceneRenderBudget`, `BinaryExporter`, UMJSON,
   `ExportSettings`, `GraphViewport`, etc. Lo que es plataforma se queda en
   Swift: los renderers Metal, `AssetManager` (PNG → `MTLTexture`),
   AVFoundation y el estado de UI de `AppState`.

7. **Desconexión final.**
   - `git mv` de `Data/`, `Core/` y los gemelos de `Render/`/`Export/` a
     `Reference/SwiftCore/`, fuera del grupo sincronizado de Xcode.
   - `MeshKernelTests.swift` se va con ellos: prueba el `MeshKernel` Swift,
     y su equivalente C++ ya existe.
   - Criterio de terminado: la app compila y funciona sin un solo archivo
     del core Swift en el target.

8. **6b, la app de Windows** (WinUI 3 + DirectX). Notas de consumo en
   `bindings/win/README.md`.

9. **Validación que falta:** un "golden dump", una CLI Swift que serialice
   salidas deterministas a JSON para comparar Swift con C++. Necesita el
   Mac y conviene hacerlo **antes** del paso 7, mientras el core Swift
   todavía compila.

10. **Menores:**
    - texturas en base64 dentro de UMJSON;
    - la lógica que quede en `TimelineView.swift`, que conviene extraer
      antes de 6b.

---

## 8. Decisiones que son del usuario (no las tomes solo)

1. **Cuatro hallazgos fijados por test y sin arreglar** (detalle en
   `MIGRATION.md`). El usuario decidió dejarlos así por ahora:
   - `connectingVertices` no puede insertar una arista; el kernel no tiene
     recuperación de aristas, igual que en Swift.
   - El grid 3×3 declara como outline solo las esquinas, y el validador lo
     marca.
   - El filtro de área opaca de Auto-Mesh rechaza todos los triángulos y
     cae siempre al relleno sin filtrar.
   - El sampler de falloff y la tabla de CPU leen entradas distintas:
     3,21/255 en `inverseSquare`.
2. **`physicsPreviewOverrides` no lo lee nadie, tampoco en Swift.** Es una
   feature a medio terminar, y hay que decidir qué debería leerlo.
3. **El binario UMSH no puede expresar animación de cámara por
   composición.** Cambiarlo es cambiar modelo y formato, con versión de
   chunk incluida.

---

## 9. Reglas que no se pueden romper (resumen; el detalle está en `CLAUDE.md`)

- **Cero dependencias externas.**
- **Inyectar lo necesario, no portar god objects.**
- **Ninguna divergencia con el Swift es silenciosa:** se documenta en el
  archivo, con el porqué y con test.
- **Los tests afirman propiedades derivadas a mano del Swift**, nunca
  la salida del propio port.
- **Nunca dejes la suite en rojo.** Antes de empezar, haz `git fetch` y
  mira `origin/main`: otro agente pudo haber subido trabajo.
- **Commits:** explican el *porqué* y registran los bugs encontrados.
  Terminan con las líneas de atribución `Co-Authored-By:` y
  `Claude-Session:` que indique el entorno.
- **Después de cada commit:**
  ```sh
  git push -u origin claude/umeshcore-cpp-port-qpk10t
  git checkout main && git merge --ff-only claude/umeshcore-cpp-port-qpk10t && git push origin main
  git checkout claude/umeshcore-cpp-port-qpk10t
  ```
- **Sin PR** salvo que el usuario lo pida.
- **Un header público nuevo** va a mano en `include/umeshcore/UMeshCore.h`:
  el umbrella no se genera por glob.
- **Un `.cpp` nuevo** va en `src/CMakeLists.txt` y su test en
  `tests/CMakeLists.txt`. Xcode compila `UMeshCore/src` solo, como grupo
  sincronizado.

---

## 10. La advertencia que no ha cambiado

Los tests C++ usan valores derivados a mano del Swift. Eso atrapa bugs de
C++, pero **no** sustituye a comparar de verdad las salidas de Swift y C++.
Que 68 binarios pasen aquí y ⌘U pase en el Mac no significa "idéntico a la
app Swift". Esa pieza es el golden dump del punto 9 de § 7.
