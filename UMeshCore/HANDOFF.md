# Nota de traspaso — fin de la Fase 5

Escrita el 2026-09-22, al cerrar la Fase 5. Para el agente que siga.
Sustituye a la nota de fin de Fase 4 (sigue en el historial de git si la
necesitas).

**Esto no repite el estado del port.** Ese vive en `../CLAUDE.md` (que se
carga solo) y el porqué largo en `ROADMAP.md`. Mantener una tercera copia
garantizaría que las tres se separen — el modo de falla que este repo
documenta desde el primer día. Aquí solo va lo que una nota de traspaso
tiene que decir y los otros dos archivos no: **qué decidí, qué dejé
abierto, y con qué me tropecé.**

---

## Dónde está el trabajo

Rama `claude/umeshcore-cpp-port-qpk10t`, con `main` sincronizado por
fast-forward. Del más viejo al más nuevo:

```
ebc28f9  fix: FrameRegion::bounding perdía capas por un NaN         (Fase 4)
570aefc  modelo de capa: SceneLayer + SceneMaterial + SceneLightMask
9895930  SceneComposition + SceneCamera + modelo de SceneLight
b0e402e  ScenePersistence — las secciones de Scene salen de `unrecognized`
b9d7fbb  chunk SCENES — la última pieza diferida del binario
e83cdb7  ScenePlayback + SceneSelection
bbe049d  PhysicsPreviewTool (y la corrección de por qué estaba bloqueado)
1105a63  ExportSettings — Fase 5 completa
```

47 binarios de test, todos en verde. `cd UMeshCore && cmake --build build -j4
&& cd build && ctest --output-on-failure`.

---

## Las decisiones que NO tomé, y que son tuyas (o del usuario)

**1. El sampler de falloff y la tabla de CPU siguen leyendo entradas
distintas de la misma tabla.** Heredado de la Fase 4 y sin tocar: la GPU
direcciona `u*n − 0.5` (centros de téxel) y la CPU `u*(n−1)`. Peor caso
3.21/255 con `inverseSquare` en u ≈ 0.025 — tres pasos de cuantización en
la parte más empinada del preset más empinado. El arreglo es una línea en
el lado que se declare **normativo**. Sigue sin tocarse por la misma razón:
cualquiera de los dos lados **diverge del Swift en silencio**, y eso rompe
la convención #3. Está como número en un test (`SceneShaderMathTests`), no
como frase.

**2. `physicsPreviewOverrides` no lo lee nadie, y hay que decidir qué
debería leerlo.** Ver abajo — es un hallazgo, no un pendiente mecánico.

**3. El formato binario no puede expresar animación de cámara por
composición.** El chunk SCENES escribe las pistas de cámara **una vez por
composición** y todas reciben las mismas, porque salen del único
`sceneAnimationClip` del proyecto. Es la forma del formato en Swift, se
reproduce tal cual y hay un test que lo fija. Si alguna vez se quiere
animación de cámara por shot, es un cambio de modelo *y* de formato
(versión del chunk incluida), no un arreglo.

---

## Tres cosas con las que me tropecé

**1. Comprueba `origin/main` antes de empezar a portar.** Mi copia local
estaba desactualizada y porté `SceneCulling` **en duplicado** sobre trabajo
que otro agente ya había subido. Se descartó el duplicado y se conservó el
suyo. Lo único que sobrevivió fue un bug real que encontró mi versión (ver
abajo). Dos minutos de `git fetch` habrían ahorrado el rodeo.

**2. "Sin terminar" y "muerto" se parecen en un diff, y grep los
distingue.** `PhysicsPreviewTool` escribe un override de pose que **no lee
nadie — tampoco en Swift**: `physicsPreviewOverrides` tiene exactamente
tres menciones en todo el código, la declaración y los dos escritores. El
header del propio archivo Swift afirma que `baseWorldMatrices()` lo lee;
no lo hace. Pero el tool **está vivo** (la tecla "y" y el menú de
constraints lo seleccionan), así que no es código muerto como
`ArcGeometryBuilder` — es una feature a medio terminar, y se porta. La
nota anterior del port decía que estaba bloqueado por falta de un
`PhysicsConstraintSystem` vivo; esa conclusión era correcta y **el motivo
era falso**. Lo que falta es la *lectura*, y eso es una decisión de diseño.

**3. Un test que falla puede tener razón — tres veces esta vez.**
`sanitized` de `SceneMaterial` sustituye un no-finito por el **defecto** y
solo después recorta, así que un `parallaxDepth` infinito vuelve 0.05 y no
0.5 (yo afirmé el recorte). `frontSortingOrder` usaba el `-1` de Swift como
*semilla* del máximo en vez de como caso vacío — ahí el bug era **mío** y
lo cazó el test. Y cuatro tests de `ScenePlayback` afirmaban bordes de
frame exactos: la resta `now - startTime` de dos doubles grandes pierde
~4e-14, así que una muestra tomada justo en el borde cae un frame antes.
Inherente a la aritmética, idéntico en Swift, e inofensivo **precisamente
por la regla del archivo** (nada se acumula) — así que el test ahora afirma
el comportamiento acotado en vez de fingir exactitud.

---

## Por dónde seguir

Fase 5 está cerrada. Lo que queda son las fases 6a/6b **y deuda arrastrada
de fases anteriores**, que conviene mirar antes de andamiar shells:

1. **Deuda SwiftUI (Riesgo #6), y es la más urgente de las tres.**
   `SceneGizmoOverlay.swift` (1732 L) y `TimelineView.swift` (4326 L)
   tienen matemática real de hit-testing y de curvas **dentro de cuerpos de
   vista SwiftUI**. De la primera ya salieron `ringFrame` y las constantes
   de geometría (Fase 4, pieza 5); lo que **construye** un layout
   (`gizmoState`, `handleSet`, `gizmoScale`, la matemática de arrastre) ya
   no está bloqueado — necesitaba el modelo de Fase 5, que ya existe.
   Extraerlo **antes** de que la UI de Windows necesite el equivalente es
   el orden que el propio archivo pide.
2. **Pipeline de alfa / assets (Fase 2).** Es la raíz común de casi todo lo
   que sigue pendiente: `CanvasPicking::imageHit`, `hitTestScreen`/`Rect`,
   el marquee de sprites, y **`MeshTool` entero** (672 L). Necesita una
   decisión de arquitectura sobre decodificación de imágenes que no es
   portable tal cual desde `CGImage`/`MTLTexture`.
3. **Mutadores de mesh** que `MeshTool` necesita y no existen
   (`updateMeshVertex`, `insertMeshVertex`, `deleteSelectedMeshVertices`),
   con `Mesh::clampedPositionInsideHullIfNeeded` debajo.
4. **Las 3 conveniencias de `Data/Mesh.swift`** (Fase 1) y el **base64 de
   texturas en UMJSON** (Fase 3).
5. **6a / 6b**: migrar la app Mac a leer de UMeshCore, y andamiar el shell
   WinUI 3 + DirectX.

---

## La advertencia que no ha cambiado

Los tests siguen usando valores golden derivados a mano del Swift. Eso
atrapa bugs de C++ pero **no** sustituye al diff real Swift-vs-C++, que
necesita un toolchain Mac que este entorno Linux no tiene. Que 47 binarios
pasen no es "verificado idéntico a la app Swift".
