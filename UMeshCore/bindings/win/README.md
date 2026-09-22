# Windows (WinUI 3 + DirectX) — cómo consume UMeshCore

Fase 6b. Como `bindings/swift/README.md`, esto es la nota de consumo, no
código todavía.

## Cómo se enlaza

No hace falta módulo ni interop: C++ consume C++.

```cmake
find_package(UMeshCore REQUIRED)
target_link_libraries(UMeshShell PRIVATE UMeshCore::umeshcore)
```

El target exportado ya lleva el include path, así que
`#include "umeshcore/UMeshCore.h"` resuelve. Verificado con un proyecto
externo real contra un `cmake --install`.

`UMeshCoreConfig.cmake` **no tiene** `find_dependency` y no debería
tenerlo nunca: la convención #1 del port es cero dependencias externas.

## Lo que el shell tiene que traer

Todo lo que `CLAUDE.md` lista como shell de plataforma. En concreto, el
backend de render: UMeshCore entrega **buffers POD** —
`Render/SceneGPUTypes.h`— y el shell los sube. Los `static_assert` de
tamaño/alineación/offset de ese header son el contrato; si un compilador
los dispusiera de otra forma, la librería no compila, que es exactamente
lo que se quiere.

Para el shader: `Render/SceneShaderMath.h` es la **referencia normativa**.
El HLSL se transcribe de ahí y se diffea **numéricamente** contra él, no
por inspección visual (Riesgo #5 del ROADMAP). El `.metal` del Mac tiene
esa misma relación con el mismo archivo, que es lo que impide que los dos
backends deriven.

## El hallazgo que hay que resolver antes de embarcar los dos caminos

`CLAUDE.md`, Fase 4 pieza 9: el sampler de falloff de la GPU direcciona
`u*n − 0.5` (centros de téxel) y la tabla de CPU `u*(n−1)`. Peor caso
medido: 3.21/255 con `inverseSquare`. Está sin tocar a propósito —
arreglar cualquiera de los dos lados divergiría del Swift en silencio— pero
el primer shell que embarque GPU y CPU a la vez tiene que decidir cuál es
normativo. Es una línea.
