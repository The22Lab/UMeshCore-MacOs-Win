#pragma once

// 1:1 port of `Data/Scene/SceneSelection.swift` -- what is selected in
// Scene. ONE value, for everything.
//
// ## Why this is a type and not two optionals
//
// It WAS two: a `selectedLayerID` living in the workspace view and a
// `selectedSceneLightID` on the manager. Nothing stopped both being set at
// once and nothing made either clear the other, so selecting a light left
// the previous layer's gizmo on the canvas, and picking a card left the
// light inspector open on a light nobody was looking at. Every place that
// wanted to ask "what is selected" had to ask twice and decide which
// answer won -- and each of them decided differently.
//
// A selection is one thing at a time. Saying that as a TYPE is what makes
// the inspector, the gizmo, the canvas and the layer list agree without
// any of them coordinating. That is the whole of this file, and it is the
// reason to resist adding a second selection field next to it later.
//
// Editor state: not saved with the scene, never reaches an export.
//
// Modelled as a kind plus an id rather than as a `std::variant`, unlike
// `SceneLayerContent`: both cases carry the same payload type and neither
// carries anything else, so a variant would need two wrapper structs to
// stay distinguishable and would read as ceremony. The invariant that
// matters -- one thing at a time -- is enforced either way, because there
// is one id field and not two.

#include "umeshcore/Core/Uuid.h"

#include <optional>

namespace umeshcore {

struct SceneSelection {
    enum class Kind { None, Layer, Light };

    Kind kind = Kind::None;
    Uuid id;

    constexpr SceneSelection() = default;

    static SceneSelection none() { return SceneSelection{}; }
    static SceneSelection layer(const Uuid& id) { return SceneSelection{Kind::Layer, id}; }
    static SceneSelection light(const Uuid& id) { return SceneSelection{Kind::Light, id}; }

    bool operator==(const SceneSelection& other) const {
        // A `None` selection carries no id, so two of them are equal
        // whatever happens to be in the field. Comparing the id anyway
        // would make `none()` unequal to a cleared selection that still
        // held a stale id, which is the kind of difference nothing should
        // be able to observe.
        if (kind != other.kind) return false;
        return kind == Kind::None || id == other.id;
    }
    bool operator!=(const SceneSelection& other) const { return !(*this == other); }

    bool isEmpty() const { return kind == Kind::None; }

    std::optional<Uuid> layerID() const {
        return kind == Kind::Layer ? std::optional<Uuid>(id) : std::nullopt;
    }
    std::optional<Uuid> lightID() const {
        return kind == Kind::Light ? std::optional<Uuid>(id) : std::nullopt;
    }

    // Whatever is selected, without saying which kind it is -- for the
    // handful of callers that only need to know whether THIS row is the
    // selected one.
    std::optional<Uuid> selectedID() const {
        return kind == Kind::None ? std::nullopt : std::optional<Uuid>(id);
    }

private:
    SceneSelection(Kind kind_, const Uuid& id_) : kind(kind_), id(id_) {}
};

} // namespace umeshcore
