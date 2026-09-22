# Nota de traspaso — fin de la Fase 4

Escrita el 2026-09-22, al cerrar la Fase 4. Para el agente que siga.

**Esto no repite el estado del port.** Ese vive en `../CLAUDE.md` (que se
carga solo) y el porqué largo en `ROADMAP.md`. Mantener una tercera copia
garantizaría que las tres se separen — el modo de falla que este repo
documenta desde el primer día. Aquí solo va lo que una nota de traspaso
tiene que decir y los otros dos archivos no: **qué decidí, qué dejé
abierto, y con qué me tropecé.**

---

## Dónde está el trabajo

Rama `claude/continuacion-plan-anterior-b1w2m4`, con `main` sincronizado
por fast-forward. Seis commits, del más viejo al más nuevo:

```
c3d15f8  SceneCulling + la cámara de vuelo          (piezas 1 y 2)
dd2d916  structs POD de GPU + paleta de skinning    (piezas 3 y 4)
4927773  layout + mesh builder del gizmo            (pieza 5)
6aa336e  la pieza 6 es código muerto — sin portar   (pieza 6)
422f33b  matemática de luces                        (pieza 7)
03b85c3  presupuesto de frame                       (pieza 8)
325275c  shader math de referencia                  (pieza 9)
```

41 binarios de test, todos en verde. `cd UMeshCore && cmake --build build -j4
&& cd build && ctest --output-on-failure`.

---

## La decisión que NO tomé, y que es tuya (o del usuario)

**El sampler de falloff y la tabla de CPU leen entradas distintas de la
misma tabla.** `Render/SceneShaderMath.h` lo explica entero y
`SceneShaderMathTests.cpp` lo mide: la GPU direcciona `u*n − 0.5` (centros
de téxel) y la CPU `u*(n−1)`. Peor diferencia sobre 256 entradas:

| curva | diferencia |
|---|---|
| `smooth` (por defecto) | 0.29 / 255 |
| `linear` | 0.50 / 255 |
| **`inverseSquare`** | **3.21 / 255** en u ≈ 0.025 |

Tres pasos de cuantización en la parte más empinada del preset más
empinado. El arreglo es una línea, en el lado que se declare **normativo**:

- tabular la curva en las posiciones del sampler (cambia la CPU), o
- direccionar la tabla por centros de téxel (cambia la CPU igualmente), o
- aceptar la diferencia y documentarla en el shell.

No lo toqué porque cualquiera de los dos lados **diverge del Swift en
silencio**, y eso rompe la convención #3. Está como número en un test,
no como frase. Cuando el Mac o Windows embarque los dos caminos a la vez,
hay que resolverlo; antes, no hace falta.

---

## Lo que dejé escrito en los headers y conviene leer antes de tocar

- `Render/SceneShaderMath.h` — es la **referencia normativa** del shader.
  `gpu_mirror.py` y `lighting_mirror.py`, que el `.metal` cita como tal, no
  existen en este repo (no hay ni un `.py`). Si escribes MSL o HLSL:
  transcríbelo de aquí y **diffea numéricamente**, no por inspección.
- `Render/SceneGPUTypes.h` / `SceneGizmoTypes.h` — los `static_assert` de
  tamaño/alineación/offset son el sustituto de
  `verify_scene_gpu_transcription.py`. Si mueves un campo, no compila. Eso
  es deliberado; no los relajes.
- `Render/SceneLighting.h` — la aritmética del `composite` de CoreGraphics
  (que no se porta) está transcrita en el comentario de cabecera, porque es
  lo que hace el fragment shader.

---

## Tres cosas con las que me tropecé (para que no te cuesten lo mismo)

1. **Verifica los call sites antes de portar.** La pieza 6 entera
   (`ArcGeometryBuilder`, `SphereGeometryBuilder`, `ArcMath`, `ArcHitTest`,
   ~475 L) es código muerto: cero referencias fuera de sus archivos, y su
   único consumidor son métodos de `ToolManager` que este port ya había
   descartado por lo mismo. Un `grep` de dos minutos ahorró un día.
2. **Un test que falla puede tener razón.** Tres expectativas mías eran
   falsas, no el código: un gizmo con `scale = 0` no sale vacío (las
   esquinas del quad de plano son *offsets*, no radios, y no hay guarda en
   ningún lado del port); una máquina de 40 ms descansa en el escalón 1 y
   nunca llega al 2, así que el camino de subida hay que ejercitarlo con un
   transitorio; y el anillo de influencia de una luz conserva el radio del
   artista, sin escalar por la escala screen-constant del gizmo.
3. **Las cifras de los harness ausentes a veces SÍ se pueden recuperar.**
   La de `shapedLambert` (3 327 de 20 001 muestras, hasta 1.5e-08) sale
   exacta al recalcularla, porque los dos lados son float32. Antes de dar
   una cifra por irrecuperable, prueba a reproducirla: si depende solo de
   aritmética, está a tu alcance.

---

## Por dónde seguir: Fase 5

**Pasos 1-3 y 5a hechos** (ver `../CLAUDE.md` § Fase 5): el modelo está
portado — `SceneLayer`, `SceneComposition`, `SceneCamera`, `SceneMaterial`,
el modelo de `SceneLight`, y los adaptadores que cierran
`cardCorners`/`cardPoint` y los dos constructores de conveniencia de
`SceneProjection`. Quedan, en este orden:

1. **`ScenePersistence.swift` (463)** — cierra `writeScenesChunk` y saca de
   `ProjectDocument::unrecognized` las secciones de Scene. Ojo: el test de
   punta a punta de `unrecognized` debe seguir pasando para lo que *siga*
   sin modelarse.
2. **`ScenePlayback.swift` (105)** y **`SceneSelection.swift` (47)**.
3. **El muestreo por frame.** `SceneComposition` NO tiene atajo `lighting()`
   a propósito — el Swift registra que existió un commit y era una trampa:
   construía la iluminación de las luces *autoradas*, así que cualquiera que
   usara la propiedad obvia renderizaba una escena cuyas pistas de luz no
   hacían nada. El muestreo vive en `SceneManager`; inyecta lo necesario.
4. **`PhysicsPreviewTool`** (Fase 2) — solo necesita que `EditorScene` tenga
   una instancia viva de `PhysicsConstraintSystem`.
5. `Export/ExportManager.swift` (135) + `ExportSettings.swift`.

Y la deuda que sigue ahí (Riesgo #6): de `SceneGizmoOverlay.swift` ya salió
`ringFrame` y las constantes de geometría; lo que **construye** un layout
(`gizmoState`, `handleSet`, `gizmoScale`, la matemática de arrastre)
necesita el modelo de Fase 5 y debería salir en cuanto exista.

---

## La advertencia que no ha cambiado

Los tests siguen usando valores golden derivados a mano del Swift. Eso
atrapa bugs de C++ pero **no** sustituye al diff real Swift-vs-C++, que
necesita un toolchain Mac que este entorno Linux no tiene. Que 41 binarios
pasen no es "verificado idéntico a la app Swift".
