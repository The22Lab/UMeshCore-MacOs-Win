# Swift interop — qué cruza y qué no

Fase 6a. Esto no es código todavía: es la **auditoría** de la superficie
pública de UMeshCore contra lo que Swift/C++ interop puede importar, con la
forma que debería tomar cada cosa que no cruza limpia. Escribirlo antes de
tocar la app del Mac es deliberado — la decisión de qué API ve Swift es más
cara de deshacer que cualquiera de las piezas portadas.

## Cómo se importa

Swift importa una librería C++ como **módulo**, no como un montón de
headers. Las dos piezas que lo hacen posible:

- `include/umeshcore/UMeshCore.h` — el umbrella: toda la superficie pública
  en un `#include`.
- `include/module.modulemap` — declara el módulo `UMeshCore` y lo apunta a
  ese umbrella.

El `module.modulemap` va **junto** al árbol de headers, no dentro: Clang lo
busca en la raíz de un header search path, así que `include/module.modulemap`
al lado de `include/umeshcore/` es el layout que funciona.

Desde el target de Swift:

```
-I <prefix>/include
-cxx-interoperability-mode=default
```

y entonces `import UMeshCore`.

El `requires cplusplus20` del module map no es decoración: sin él, un target
que se olvide del flag de interop recibe un muro de errores de parseo desde
dentro de `<variant>` en vez de un diagnóstico claro.

Desde CMake/MSVC (Fase 6b) es `find_package(UMeshCore)` y enlazar
`UMeshCore::umeshcore`; el target exportado ya lleva el include path.

**Verificado de punta a punta**: `cmake --install` seguido de un proyecto
externo que hace `find_package` + `target_link_libraries` compila y corre.

## Lo que cruza sin tocar nada

La mayor parte, y es la parte que importa. Todos los tipos de valor —
`Vec2`/`Vec3`/`Vec4`, `Mat4`, `Transform3D2D`, `Uuid`, `Bone`, `SceneImage`,
`SceneLayer`, `SceneCamera`, `SceneLight`, `ExportSettings`, los structs POD
de `Render/SceneGPUTypes.h`— son agregados de campos triviales o de
`std::vector`/`std::string`/`std::optional`, y Swift los importa como
structs con sus miembros accesibles. Las funciones libres
(`sceneProjection`, `lightDirection`, `sanitized`, los `toJson`/`*FromJson`)
también.

Que esto sea así **no es casualidad**: es la convención #1 del port. Cero
dependencias externas significa que no hay un tipo de una librería de
terceros en ninguna firma, y eso es exactamente lo que hace que la
superficie sea importable.

## Los cuatro que no, y qué hacer con cada uno

Son un conjunto **pequeño y acotado** — por eso la respuesta es una fachada
y no una reescritura.

### 1. `std::variant` (3 sitios)

`KeyframeValue` (`Animation/Keyframe.h`), `GizmoHandle`
(`Editor/GizmoHandle.h`), `SceneLayerContent` (`Scene/SceneLayer.h`).

Swift los importa como opacos: no hay `switch` sobre los casos, ni
`std::get_if` utilizable. Y son precisamente los tipos que una vista
SwiftUI querría desestructurar.

**Forma recomendada**: un discriminante `enum class` + accesores
`std::optional<T>` por caso, **junto** al variant y no en su lugar. En C++
el variant sigue siendo la representación (nada del core cambia); el
`enum` + accesores es una vista de lectura que Swift sí puede usar. La
alternativa —convertir a struct con tag— pierde la exhaustividad que el
compilador C++ da hoy en cada `std::visit`, y este port tiene varios.

> **Corrección (Fase 6a, al escribirlo de verdad).** Esa forma no sirve
> tal cual: los accesores toman el variant *como parámetro*, y Swift no
> importa una función cuya firma menciona un tipo que no puede importar.
> Lo escrito en `Interop/SwiftBridge.h` es una **forma plana** por variant
> (tag + los payloads de todos los casos) y un par de funciones entre esa
> forma y el tipo de modelo que contiene el variant (`Keyframe`,
> `SceneLayer`), de modo que ningún variant aparece en una firma que Swift
> llame. El razonamiento de abajo sobre conservar el variant en C++ sigue
> en pie.

Precedente que ya existe: `SceneSelection` está escrito como
kind + id *justamente* porque sus dos casos comparten payload; el header
lo dice. Aquí es al revés — los payloads difieren — así que el variant se
queda y la fachada se añade.

### 2. El typedef de `std::function` (1 sitio)

`ImageHitTestFn` (`Editor/CanvasPicking.h`), y un parámetro
`std::function` en `Render/SceneLighting.h`.

Swift no puede pasar un closure donde se espera un `std::function`.

**Forma recomendada**: una sobrecarga que tome un puntero a función C +
`void* context`. Es el patrón que un shell nativo usa de todos modos, y
`ImageHitTestFn` es *el* punto de inyección del pipeline de alfa que la
Fase 2 dejó pendiente — así que esta decisión y aquella se toman juntas,
no por separado.

### 3. Bases con virtuales puras (3 sitios)

`Tool` (`Editor/Tool.h`), `Constraint` (`Constraints/Constraint.h`),
`CanvasActivity` (`Editor/CanvasActivity.h`).

Swift **no puede heredar** de una clase C++ ni implementar una virtual
pura. Consumirlas (llamar a un `Tool` que el core construyó) sí funciona.

**Forma recomendada**: nada, para `Tool` y `Constraint`. El shell no
necesita implementar tools ni constraints — los construye `ToolManager` y
el shell solo le manda eventos, que es la dirección que sí cruza. Si algún
día un shell quiere una tool propia, la fachada es un struct de punteros a
función, no una jerarquía.

### 4. Accesores que devuelven referencia (14 sitios)

`AnimationClip::tracks()`, `AnimationLibrary::animations()`,
`LightFalloffCurve::stops()`, los `name()` de los cuatro constraints, etc.

Swift los importa, pero como puntero inseguro y **sin garantía de
lifetime**: nada impide que el objeto dueño muera mientras Swift sostiene
la referencia. Este port ya se ha llevado dos mordiscos de exactamente esa
clase de bug **en C++** (`BinaryExporter` con `orderedBones()`,
`SavedSkeleton` con `valueOr`), donde al menos el compilador ayudaba.

**Forma recomendada**: para los que una vista va a leer, un accesor que
devuelve **por valor**. Para los grandes (una lista de tracks completa),
mejor un par count/at que copiar un vector por frame. Lo que no debe
hacerse es que SwiftUI sostenga una referencia a través de un redraw.

## Lo que NO hay que hacer

**No** una capa C ABI sobre todo. Sería miles de líneas de transcripción a
mano — exactamente la fuente de bugs que este port lleva cinco fases
evitando— para resolver cuatro construcciones. La auditoría existe para
poder decir eso con números: 3 variants, 1 typedef de función, 3 bases
virtuales, 14 accesores por referencia, contra ~97 headers que cruzan
enteros.

## Estado

Auditoría hecha; fachadas **no** escritas. El orden razonable es
escribirlas *cuando una vista concreta del Mac las pida*, no antes: una
fachada especulativa es una segunda API que mantener, y la migración de
6a es progresiva por decisión explícita del usuario.
