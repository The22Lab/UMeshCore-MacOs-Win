#pragma once

// 1:1 port of `Data/Scene/ScenePersistence.swift` (463 L) -- the JSON
// conversions for the Scene-compositing model.
//
// This file closes one of the port's oldest open loops. Until now the
// manifest's `sceneCompositions` / `selectedSceneCompositionID` /
// `sceneViewCamera` sections were kept VERBATIM in
// `ProjectDocument::unrecognized`, precisely so that a load/save cycle
// through UMeshCore would not destroy a real project's Scene mode. They
// are modelled now; `unrecognized` keeps doing its job for what is still
// not (today, `editorState`), and the end-to-end test that proves it
// still passes.
//
// ## Every concession here is per FIELD, and each one names a scenario
//
// The Swift file's rule -- and this port's -- is that a project saved
// before a feature existed must decode untouched, and a project saved by
// a LATER build must decode in this one rather than failing the whole
// document. So optionality is not tidiness, it is compatibility, and each
// default is chosen to reproduce what the older file actually looked
// like:
//
//   - A missing `material` restores the FLAT surface, which is what Scene
//     always drew. Not a neutral-ish guess: `isFlat` gates a branch the
//     shader never enters, so "renders bit for bit as before" survives.
//   - A missing `sortingOrder` restores the layer's INDEX IN THE FILE.
//     Before layers had numbers the stacking WAS the array order, so the
//     index reproduces exactly the draw order the file was saved with.
//     Defaulting to zero would put every card on one layer and leave the
//     tie-break to sort them -- the same order by luck, and no longer so
//     the moment anybody touched one number.
//   - A missing `lightMask` restores channel 1 and `receivesLight` true,
//     which is what makes a light added to an old scene later actually
//     reach anything.
//   - A `parallaxMode` this build does not know falls back to `off`, NOT
//     to a nearby guess. A file written by a later build naming a march
//     this one cannot run has to draw the surface it drew before marches
//     existed; picking the closest mode would render the artist a scene
//     they never composed and then let them save it back.
//   - A layer whose kind-specific payload is missing is DROPPED, not
//     restored as something it never was -- so a future layer type does
//     not brick an older editor, it just does not appear.
//
// ## Ranges are enforced on the way IN, not only in the inspector
//
// A hand-edited or truncated file must not be able to produce a camera
// that divides by `tan(0)`, a light with a zero band, a cone whose inner
// angle exceeds its outer (the smoothstep between them would run
// backwards, which reads as a spot lit inside out), or a mask that
// decoded as nothing (a light that lights nothing is indistinguishable
// from the file being wrong, so an empty mask restores to ALL channels --
// note that a LAYER's empty mask restores to channel 1 instead, because
// the two are answering different questions).
//
// ## An empty Scene writes NOTHING
//
// `sceneCompositions` and `sceneViewCamera` are omitted entirely when
// there are no compositions, which is what keeps files byte-stable for
// projects that never touch Scene mode. The view camera is tied to the
// compositions and not to its own emptiness, deliberately: it is where
// the artist was standing, and there is nowhere to stand in a project
// with no set.
//
// `SceneViewCamera` is editor convenience and never scene data -- not
// keyframed, not exported, and dropping it from a file loses nothing but
// a viewpoint. It is saved the way a window position is.

#include <optional>
#include <vector>

#include "umeshcore/Render/SceneViewCamera.h"
#include "umeshcore/Scene/SceneCamera.h"
#include "umeshcore/Scene/SceneComposition.h"
#include "umeshcore/Scene/SceneLayer.h"
#include "umeshcore/Scene/SceneLight.h"
#include "umeshcore/Scene/SceneMaterial.h"
#include "umeshcore/Serialization/Json.h"

namespace umeshcore {

JsonValue toJson(const SceneFill& fill);
SceneFill sceneFillFromJson(const JsonValue& j);

JsonValue toJson(const SceneCamera& camera);
SceneCamera sceneCameraFromJson(const JsonValue& j);

JsonValue toJson(const LightFalloffStop& stop);
LightFalloffStop lightFalloffStopFromJson(const JsonValue& j);

JsonValue toJson(const SceneLight& light);
SceneLight sceneLightFromJson(const JsonValue& j);

JsonValue toJson(const SceneAmbient& ambient);
SceneAmbient sceneAmbientFromJson(const JsonValue& j);

JsonValue toJson(const SceneMaterial& material);
SceneMaterial sceneMaterialFromJson(const JsonValue& j);

JsonValue toJson(const SceneLayer& layer);
// nullopt when the payload this layer's kind needs is missing -- the
// layer is dropped rather than restored as something it never was.
// `fallbackOrder` is its index in the file, used as its layer number when
// the file predates layer numbers.
std::optional<SceneLayer> sceneLayerFromJson(const JsonValue& j, int fallbackOrder);

JsonValue toJson(const SceneComposition& composition);
SceneComposition sceneCompositionFromJson(const JsonValue& j);

JsonValue toJson(const SceneViewCamera& camera);
SceneViewCamera sceneViewCameraFromJson(const JsonValue& j);

} // namespace umeshcore
