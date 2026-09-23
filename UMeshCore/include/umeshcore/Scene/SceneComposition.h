#pragma once

// 1:1 port of the `SceneComposition` half of
// `Data/Scene/SceneComposition.swift` -- a scene: some layers at some
// depths, seen through a camera.
//
// (`SceneViewCamera` and `SceneFrontView` live in the same Swift file.
// `SceneViewCamera` is already ported, in `Render/SceneViewCamera.h`.
// `SceneFrontView` -- corrected in Phase 6a, this comment used to claim it
// was ported there too and it was not -- is ported in
// `Editor/SceneViewport.h` instead, beside the viewport-fit math that
// reads it, the same file that closed the gap. Both are EDITOR STATE --
// saved with the project the way a window position is, never keyframed,
// never exported -- while everything here is scene data. The Swift file
// keeps them together; this port keeps them apart, because the line
// between "renders" and "does not render" is the one that matters when a
// Windows shell has to decide what to persist.)
//
// A project can hold several compositions -- a walk cycle staged three
// ways, or three shots of one film -- so they are a LIST with a selection,
// not a single slot bolted onto the document. Retrofitting that later
// would mean touching persistence twice.
//
// ## The order of `layers` is NOT the draw order
//
// It was, and the change of side is recorded rather than deleted. The list
// used to decide who covers whom, on the grounds that a list is what a
// compositor shuffles; the author overruled it, and stacking is now a
// NUMBER on each layer (`SceneLayer::sortingOrder`), because naming a
// layer's place is something you do once while dragging rows is something
// you redo every time the set grows.
//
// What did NOT change is the part that rule was really protecting: DEPTH
// STILL DOES NOT REORDER ANYTHING. Pushing a card back in Z changes how
// big it draws and how fast it slides, and nothing about who covers whom.
//
// The array keeps exactly one job: it BREAKS TIES. Two cards on the same
// layer draw in the order they appear here, which is stable, is the order
// the artist created them in, and is something a set could never provide.
// That is why `drawOrderedLayers` is a stable sort written out rather than
// a sort on the number alone -- see its note.

#include <optional>
#include <string>
#include <vector>

#include "umeshcore/Core/Uuid.h"
#include "umeshcore/Math/Vec.h"
#include "umeshcore/Scene/SceneCamera.h"
#include "umeshcore/Scene/SceneLayer.h"
#include "umeshcore/Scene/SceneLight.h"

namespace umeshcore {

struct SceneComposition {
    Uuid id;
    std::string name = "Scene";

    // The scene's cards. THE ORDER OF THIS VECTOR IS NOT THE DRAW ORDER --
    // see the header.
    std::vector<SceneLayer> layers;

    SceneCamera camera;

    // The set's lights, IN THE ORDER THEY ARE APPLIED.
    //
    // A vector, and the order is the artist's. `multiply` and `screen`
    // lights do not commute with the others, so "which light first" is a
    // real question with a visible answer -- and in Swift a Set would have
    // answered it differently on each launch, since Swift seeds hashing
    // per process. The reason survives the port even though C++ would not
    // reshuffle: the order is authored, so it is data.
    std::vector<SceneLight> lights;

    // The light that is there when nothing is pointed at something.
    // Defaults to full white at strength 1, which multiplies by exactly
    // one, so a scene composed before lighting existed renders through the
    // same code and comes out identical -- not nearly, identically,
    // because `SceneLighting`'s identity check skips the arithmetic.
    SceneAmbient ambient;

    // Rendered behind every layer, so a scene is never composited onto
    // nothing.
    SceneFill background = SceneFill::neutral();

    int durationInFrames = 90;
    int fps = 30;

    // Output size. INDEPENDENT OF THE WINDOW: the shot is a fixed frame,
    // and what the artist sees while flying must not change what renders.
    Vec2 renderSize = Vec2(1920.0f, 1080.0f);

    bool operator==(const SceneComposition&) const = default;

    const SceneLayer* layer(const Uuid& id) const;
    const SceneLight* light(const Uuid& id) const;

    // Every layer in DRAW ORDER: back first, front last. Sorted by
    // `sortingOrder` ascending, TIES BROKEN BY THE VECTOR'S OWN ORDER.
    //
    // The tie-break is the whole reason this is a stable sort rather than
    // a comparison on the number alone. Swift's `sorted(by:)` is not
    // guaranteed stable and `std::sort` is explicitly not, so two cards on
    // one layer could swap between runs and an artist would see their set
    // restack itself for no reason. Written out with the index as the
    // second key, so it cannot depend on which sort the standard library
    // happens to use.
    std::vector<SceneLayer> drawOrderedLayers() const;

    // The same order reversed: front-most first. What the hierarchy lists,
    // because that is the convention the Editor's own hierarchy already
    // uses ("top row = front-most") -- and the two disagreeing about which
    // end is the front is a bug this project has already shipped once.
    std::vector<SceneLayer> frontToBackLayers() const;

    // Layers in draw order, hidden ones dropped. The opacity threshold is
    // the Swift one: a layer at 0.001 or less contributes nothing a viewer
    // could see, and skipping it early saves a full lighting pass over it.
    std::vector<SceneLayer> visibleLayers() const;

    // The number a new layer should take to land in front of everything.
    int frontSortingOrder() const;

    // NO `lighting` CONVENIENCE HERE, deliberately, and the Swift comment
    // is worth keeping verbatim in spirit: it existed for one commit and
    // it was a trap. It built a lighting solve from the AUTHORED lights,
    // so any caller reaching for the obvious property would render a scene
    // whose light TRACKS did nothing. Lighting is asked for AT A FRAME,
    // after the animator has sampled the tracks, and there is no shortcut
    // past the sampling.
};

} // namespace umeshcore
