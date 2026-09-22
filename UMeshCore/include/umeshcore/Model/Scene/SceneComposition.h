#pragma once

// 1:1 port of `SceneComposition` and `SceneFrontView` from
// `Data/Scene/SceneComposition.swift`. (`SceneViewCamera`, the third type
// in that file, was ported in Phase 4 -- it is the fly camera, and it
// lives in `Render/SceneViewCamera.h` beside the projection it feeds.)
//
// A scene: some layers at some depths, seen through a camera. A project
// can hold several -- a walk cycle staged three ways, or three shots of
// one film -- so they are a list with a selection rather than a single
// slot bolted onto the document.

#include <optional>
#include <string>
#include <vector>

#include "umeshcore/Core/Uuid.h"
#include "umeshcore/Model/Scene/SceneCamera.h"
#include "umeshcore/Model/Scene/SceneLayer.h"
#include "umeshcore/Model/Scene/SceneLight.h"
#include "umeshcore/Render/SceneLighting.h"

namespace umeshcore {

struct SceneComposition {
    Uuid id;
    std::string name = "Scene";

    // The scene's cards. THE ORDER OF THIS ARRAY IS NOT THE DRAW ORDER.
    //
    // It was, and the Swift source keeps the record of changing sides
    // rather than deleting the old rule: stacking is now a NUMBER on each
    // layer (`sortingOrder`), because naming a layer's place is something
    // you do once while dragging rows is something you redo every time the
    // set grows. What did not change is what that rule was protecting --
    // DEPTH STILL DOES NOT REORDER ANYTHING.
    //
    // The array keeps one job: it BREAKS TIES. Two cards on the same layer
    // are drawn in the order they appear here, which is stable, is the
    // order the artist created them in, and is something a set could never
    // provide.
    std::vector<SceneLayer> layers;
    SceneCamera camera;

    // The set's lights, IN THE ORDER THEY ARE APPLIED. `multiply` and
    // `screen` do not commute with the others, so "which light first" is a
    // real question with a visible answer, and an unordered container
    // would answer it differently on each run.
    std::vector<SceneLight> lights;
    // The light that is there when nothing is pointed at something.
    // Defaults to full white at strength 1, which multiplies by exactly
    // one -- so a scene composed before lighting existed renders through
    // the same code and comes out identical, because
    // `SceneLighting::isIdentity` skips the arithmetic entirely.
    SceneAmbient ambient;
    // Rendered behind every layer, so a scene is never composited onto
    // nothing.
    SceneFill background = SceneFill::neutral();
    int durationInFrames = 90;
    int fps = 30;
    // Output size. Independent of the window: the shot is a fixed frame,
    // and what the artist sees while flying around must not change what
    // renders.
    Vec2 renderSize = Vec2(1920, 1080);

    const SceneLayer* layer(const Uuid& id) const;
    const SceneLight* light(const Uuid& id) const;

    // Every layer in DRAW ORDER: back first, front last. Sorted by
    // `sortingOrder` ascending, ties broken by the array's own order.
    //
    // The tie-break is the whole reason this is a STABLE sort written out
    // rather than a plain sort on the number: two cards on one layer could
    // otherwise swap between runs, and an artist would see their set
    // restack itself for no reason.
    std::vector<SceneLayer> drawOrderedLayers() const;

    // The same order reversed: front-most first. What a hierarchy lists,
    // because that is the convention the Editor's own hierarchy already
    // uses -- and the two disagreeing about which end is the front is a
    // bug this project has already shipped once.
    std::vector<SceneLayer> frontToBackLayers() const;

    // Layers in draw order, hidden ones dropped.
    std::vector<SceneLayer> visibleLayers() const;

    // The number a new layer should take to land in front of everything.
    int frontSortingOrder() const;

    // NO `lighting()` CONVENIENCE HERE, deliberately, and the Swift source
    // records why: it existed for one commit and it was a trap. It built a
    // `SceneLighting` from the AUTHORED lights, so any caller reaching for
    // the obvious property would render a scene whose light tracks did
    // nothing. Lighting is asked for AT A FRAME, after sampling, and there
    // is no shortcut past that.
};

// Where the artist is looking in the FRONT view.
//
// A plain 2D pan and zoom over the rendered shot -- it changes nothing
// about the shot itself, which is why it is editor state beside
// `SceneViewCamera`, never keyframed and never exported.
struct SceneFrontView {
    // View points, added to where the image would otherwise sit.
    Vec2 pan;
    float zoom = 1.0f;

    // Far enough out to see a set laid wide, far enough in to place a card
    // by its corner. Clamped because an unclamped zoom is a viewport
    // nobody can get back to.
    static constexpr float kMinZoom = 0.15f;
    static constexpr float kMaxZoom = 12.0f;

    void zoomBy(float factor);
    bool isIdentity() const { return pan == Vec2::zero() && zoom == 1.0f; }

    bool operator==(const SceneFrontView&) const = default;
};

} // namespace umeshcore
