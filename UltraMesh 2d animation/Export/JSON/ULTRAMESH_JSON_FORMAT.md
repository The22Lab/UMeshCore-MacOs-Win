# UltraMesh JSON Interchange Format — v1.0.0

The official, engine-agnostic format exported by UltraMesh for the Unity runtime
and every future runtime (Unreal, Godot, C++, WASM). It is designed the way a
rig interchange format has to be: **versioned, deterministic, lossless,
sectioned, and extensible**.

## Contract guarantees

- **Versioned.** `format` is always `"UltraMesh"`; `version` is the format
  semver. A reader must check `format` and refuse unknown formats, tolerate a
  newer `version` by ignoring unknown keys, and consult `compatibility` for
  capability probing. New keys and new sections are always additive.
- **Deterministic.** Exporting an unmodified project twice yields byte-identical
  JSON (with `includeExportDate = false`). The encoder sorts keys; the builder
  sorts every collection derived from a hash map (bones by DFS with id-sorted
  children, weights by bone id, inverse-bind matrices by bone id, skins/slots by
  name). No array-index identity is ever used — everything is keyed by UUID.
- **Lossless.** Every authorable value is present. Angles are stored in the
  editor's **internal unit**, documented per field, so a runtime reproduces the
  rig with zero conversion drift.
- **Precision.** Floats are rounded to `floatPrecision` decimals (default 6 —
  lossless for 32-bit floats at typical magnitudes). Raise it to keep every bit.

## Units & conventions

- Coordinates are in **pixels**, Y-up, origin at the scene center.
- Matrices are **column-major** 4×4, 16 floats, composed `T·Rz·Ry·Rx·Skew·Scale`.
- **Bone** `rotation` and `shear` are **radians**.
- **Attachment / bone-binding** `rotation` is **radians**; `shear` is **degrees**
  (the sprite shear convention). This asymmetry is intentional and matches the
  editor; a runtime must honor it.
- Rotate keyframe values are radians; translate/scale/shear keyframe values are
  `[x, y]` in the same units as the corresponding pose field.

## Top-level object

```jsonc
{
  "format": "UltraMesh",
  "version": "1.0.0",
  "engineVersion": "UltraMesh 1.0",
  "generator": "UltraMesh JSON Exporter 1.0.0",
  "exportDate": "2026-07-24T00:00:00Z",   // "" when reproducible builds requested
  "compatibility": { "minRuntimeVersion": "1.0.0", "featureFlags": [ ... ] },
  "metadata":    { ... },
  "atlas":       { "regions": [ ... ] },
  "bones":       [ ... ],
  "slots":       [ ... ],
  "attachments": [ ... ],
  "meshes":      [ ... ],
  "skins":       [ ... ],
  "constraints": { "ik": [ ... ], "transform": [ ... ], "path": [ ... ] },
  "physics":     [ ... ],
  "events":      [ ... ],
  "animations":  [ ... ]
}
```

### metadata
`projectName`, `framesPerSecond`, `playbackStartFrame`, `playbackEndFrame`,
`units` (`"pixels"`), `drawOrder` (setup attachment order, back→front),
`custom` (string map, preserved verbatim).

### atlas.regions[]
`id` (== attachment `region`), `name`, `width`, `height`, `embedded`,
and then either `dataBase64` (PNG bytes, when embedded) or `path` (filename
relative to the exported file).

### bones[]
`id`, `name`, `parent?`, `length`, `color` `[r,g,b,a]`, `root` (bool), and
`transform` = `{ position:[x,y], rotation, scale:[x,y], shear:[x,y], depth? }`.
`depth` is present only when 3D components are non-default:
`{ positionZ, rotationX, rotationY, scaleZ }`. This is the **setup** pose;
animations blend away from it.

### slots[]
`name`, `attachments` (attachment ids that can occupy the slot — the skin
variants). A slot with one attachment is a plain sprite, not a real variant.

### attachments[]  (sprites)
`id`, `name`, `slot`, `region` (atlas id), `mesh?` (mesh id), `hidden`,
`animationSpace` (`"world"|"boneLocal"`), `animationSpaceBone?`,
`setupPose` (`{position,rotation,scale,shear}` — used when unbound),
and `boneBinding?` = `{ bone, localPose }` (used when parented to a bone).

### meshes[]
`id`, `name`, `vertices` (flat `[x,y,…]`), `uvs` (flat, v grows downward),
`triangles` (index list), `hull`, `edges` (flat `[a,b,…]`),
`manualTriangles` (flat `[a,b,c,…]`). Skinned meshes additionally carry
`bindVertices`, `weights` (`[[{bone,weight}…]…]`, per vertex),
`inverseBindMatrices` (`[{bone, matrix[16]}]`), and `bindPose`
(sprite pose at bind time; rotation radians, shear degrees).

### skins[]
`id`, `name`, `includes` (skin ids, nearest-first), and `slots` = explicit
per-slot choices `[{slot, attachment?}]`. `attachment: null` means the skin
**empties** the slot; a slot absent from the array means the skin has no opinion
and defers to `includes`, then the setup pose.

### constraints
- **ik[]**: `bones` (chain root→effector), `target`, `bendPositive`, `stretch`,
  `compress`, `uniformScale`, `softness`, plus `mix`/`order`/`enabled`.
  1 bone = look-at, 2 = analytic law-of-cosines, 3+ = FABRIK.
- **transform[]**: `target`, `bones`, per-channel `copy*` flags and `*Mix`,
  `offsetPosition[x,y]`, `offsetRotation` (rad), `offsetScale[x,y]`,
  `offsetShear` (rad).
- **path[]**: `pathBones` (spline control points), `bones` (followers),
  `position`, `spacing`, `spacingMode` (`length|percent|proportional|fixed`),
  `positionMix`, `rotateMix`, `offsetRotation` (rad), `closed`, `reversed`,
  `rotateMode` (`tangent|chain|chainScale`).

### physics[]
`type` (`spring|jiggle|rope|pendulum|cloth`), `bones` (root pinned → tips),
`settings` = `{ mass, damping, stiffness, gravity, drag, wind[x,y],
stretchLimit, angleLimitMin, angleLimitMax }` (angle limits in radians).
Physics is stateful secondary motion; it runs last (order ≥ 100) and is
simulated sequentially by the runtime.

### events[]
`id`, `name`, default payload `int`/`float`/`string`, plus `audioPath`,
`volume`, `balance`.

### animations[]
`name`, `durationFrames`, and:
- `bones[]` = `{ bone, translate?, rotate?, scale?, shear? }`
- `attachments[]` = `{ attachment, translate?, rotate?, scale?, shear?, color?, alpha?, deform? }`
- `constraints[]` = `{ constraint, properties:[{property, keys[]}] }`
  where `property` is one of `constraintMix`, `ikSoftness`, `ikBendPositive`,
  `ikStretch`, `ikCompress`, `transformRotateMix`, `transformTranslateMix`,
  `transformScaleMix`, `transformShearMix`, `pathPosition`, `pathSpacing`,
  `pathPositionMix`, `pathRotateMix`, `physicsMass`, `physicsDamping`,
  `physicsStiffness`, `physicsGravity`, `physicsDrag`, `physicsWind`.
- `drawOrder[]` = `{ frame, order:[attachmentId…] }` (stepped)
- `events[]` = `{ event, keys:[{frame, int?, float?, string?}] }`

**Keyframe**: `{ frame, interp, … }` where `interp` ∈ `linear|stepped|bezier`.
The payload is exactly one of `scalar`, `vector[x,y]`, or `flag`. Bézier keys add
`inTangent`/`outTangent` (and `secondaryInTangent`/`secondaryOutTangent` for the
Y channel of vector tracks), each an `[frameDelta, valueDelta]` offset.

**Deform keyframe**: `{ frame, interp, vertices:[x0,y0, x1,y1, …] }` — its own
shape, because the payload is a whole vertex array rather than one value.

- `vertices` are **absolute** positions in the attachment's local space, the
  same space as `meshes[].vertices`, not offsets from the rest shape. Absolute
  positions cost more bytes than deltas but leave no question about which rest
  shape a delta belongs to when a skin swaps the mesh underneath.
- `interp` is only ever `linear` or `stepped`. Deformation never consults
  Bézier tangents, so a Bézier-authored key is exported as `linear` rather than
  claiming a curve the runtime would have to invent.
- A key whose vertex count disagrees with the mesh is dropped at export: the
  editor ignores such a key at playback, so exporting it would hand a runtime
  data the editor itself would never draw.
- **Before the first key the first key's shape is held.** A deform timeline
  does not fade out of the rest shape the way a transform track fades out of
  the setup pose.
- On a **weighted** mesh the deformation is ignored: skinning recomputes every
  vertex from the bind shape. In UltraMesh deform and skinning are
  alternatives, not layers.

## Extension points (forward compatibility)

New constraint types, animation layers, blend trees, masks, audio tracks,
timeline markers, compression, and streaming metadata all fit as **new sections
or new record keys**. A conforming reader ignores keys it does not know, and
gates behavior on `compatibility.featureFlags`, so older runtimes keep loading
newer files (minus the features they predate). Never repurpose or remove an
existing key — add a new one.
```
