#pragma once

// 1:1 port of `Data/Scene/SceneLayer.swift` -- `SceneFill`,
// `SceneLayerContent` and `SceneLayer`: one card in a Scene, at its own
// depth.
//
// ## The founding invariant: every layer is FLAT
//
// A layer's Z is constant across the whole card. That is what makes the
// perspective collapse to a single scale factor, what makes parallax cost
// nothing, and -- less obviously -- what makes LIGHTING exact rather than
// approximate: `Render/SceneLighting.h` intersects the ray through a pixel
// with `lightingPlane()` and gets the world point that is actually there,
// whatever the layer contains and however its meshes are deformed. It is
// the After Effects model, and it is what the artist asked for.
//
// ## Why this file closes four things the port left open
//
// `SceneViewCamera`'s header names `cardCorners`/`cardPoint` as waiting on
// `planePoint`/`liftToWorld`/`worldOrigin`; `SceneLayerUniforms` waits on
// `orientation()`. They waited on purpose. Inventing a layer type inside
// Render would have meant re-transcribing this lift, which is the "two
// transcriptions of a rotation" failure `SceneProjection`'s header exists
// because of. There is one transcription, and it is here.
//
// ## The transform order IS the definition
//
// `planePoint` is scale, THEN shear, THEN roll. Shear after scale means it
// is expressed in the card's scaled units -- the same order `SceneImage`
// applies skew in on the rig side -- so a scaled card slants by the amount
// the number says rather than by that amount times its scale. The Swift
// header records that the shot's `cgPoint` and the fly view's `cardPoint`
// each used to inline this, and that two copies of a transform is how one
// of them ends up missing a term. It names the rig's own canvas-vs-exporter
// bug as the precedent.
//
// `orientation()` exists SEPARATELY from `planePoint` and that separation
// is the whole of a bug: the gizmo used to take its frame by differencing
// the card's transform, which runs points through `planePoint` -- scale,
// shear, roll. Normalising the two vectors that came back fixed their
// lengths and could do nothing about the ANGLE between them, so a sheared
// card handed the gizmo a frame that was not a rotation, and a matrix like
// that shears every arrow it multiplies. `orientation()` is roll then
// tilt, and no scale or shear can reach it.
//
// ## Two numbers that look interchangeable and do the opposite
//
// `sortingOrder` is HIGHER IS NEARER THE FRONT. `positionZ` is HIGHER IS
// FURTHER AWAY. Deliberately opposite: Z is a distance, and things further
// off have more of it, while a layer number is a stacking order and every
// tool that has one -- Photoshop, After Effects, Unity's Order in Layer --
// counts it upward towards the viewer. And DEPTH DOES NOT REORDER
// ANYTHING: pushing a card back in Z changes how big it draws and how fast
// it slides, and nothing about who covers whom.

#include <optional>
#include <string>
#include <variant>

#include "umeshcore/Core/Uuid.h"
#include "umeshcore/Math/Vec.h"
#include "umeshcore/Scene/SceneLightMask.h"
#include "umeshcore/Scene/SceneMaterial.h"

namespace umeshcore {

// A flat fill -- a sky, a fog bank, a colour card behind everything.
struct SceneFill {
    Vec4 topColor = Vec4(0, 0, 0, 1);
    Vec4 bottomColor = Vec4(0, 0, 0, 1);

    // True when both stops match, i.e. a plain colour rather than a ramp.
    bool isFlat() const { return topColor == bottomColor; }

    // A neutral GREY ramp. It used to be a dark blue, and a blue ground is
    // not neutral: every colour placed on the set was judged against a
    // tint, so a warm plate read warmer than it is. Grey is the standard
    // working ground for exactly that reason. Still a ramp rather than a
    // flat fill, so an empty scene reads as a space with a floor rather
    // than as a blank.
    static SceneFill neutral() {
        return SceneFill{Vec4(0.34f, 0.34f, 0.34f, 1.0f), Vec4(0.46f, 0.46f, 0.46f, 1.0f)};
    }

    static SceneFill solid(const Vec4& color) { return SceneFill{color, color}; }

    bool operator==(const SceneFill&) const = default;
};

// What a Scene layer actually draws.
//
// DELIBERATELY CLOSED. A Scene assembles work that already exists -- it
// does not author it -- so there is no case here for "a mesh being edited"
// or "a bone chain". Rigging stays in Editor and animation stays in
// Animator.
//
// A std::variant of wrapper structs, the idiom `KeyframeValue` already
// uses in this port, so the cases stay distinguishable by identity even
// where two would share a payload type.

// An instance of this project's rig, playing one of its clips.
//
// The same rig can appear more than once in a scene at different depths
// and different points in its clip -- three birds from one bird rig. That
// is only possible because `AnimationClip::pose` is a pure function of the
// frame, so a pose can be sampled without disturbing the scene the artist
// is editing.
struct SceneRigContent {
    Uuid clipId;
    float speed = 1.0f;
    int startFrame = 0;
    bool loops = true;
    bool operator==(const SceneRigContent&) const = default;
};

// A plain image: a backdrop, a foreground plate, a cloud bank.
struct ScenePlateContent {
    Uuid assetId;
    bool operator==(const ScenePlateContent&) const = default;
};

// A colour or vertical ramp, for skies and fog without needing a PNG.
struct SceneFillContent {
    SceneFill fill;
    bool operator==(const SceneFillContent&) const = default;
};

using SceneLayerContent = std::variant<SceneRigContent, ScenePlateContent, SceneFillContent>;

// Whether this is the atmosphere case, which the shot paints across the
// whole frame rather than as a card.
inline bool isFill(const SceneLayerContent& content) {
    return std::holds_alternative<SceneFillContent>(content);
}

// The layer's rotation as three orthonormal world axes -- see the header's
// note on why this is not `planePoint`.
struct SceneLayerOrientation {
    Vec3 x;
    Vec3 y;
    Vec3 z;
};

struct SceneLayer {
    Uuid id;
    std::string name;
    bool isHidden = false;
    float opacity = 1.0f;

    Vec2 position;
    // Depth. HIGHER IS FURTHER FROM THE CAMERA.
    float positionZ = 0.0f;
    // Roll, in radians -- the card spinning in its own plane.
    float rotation = 0.0f;
    // Pitch and yaw tilt the card out of its plane. The z component is
    // unused, because `rotation` already carries roll; kept as a Vec3 to
    // match the convention `SceneImage::rotation3D` established on the rig
    // side, so the same field means the same thing in both models.
    Vec3 rotation3D;
    Vec2 scale = Vec2(1.0f, 1.0f);
    // Slant, as a pair of tangents: x slides a point sideways by its
    // height, y slides it vertically by its width. The same shape
    // `SceneImage::skew` uses, so a number an artist learns in one place
    // means the same in the other.
    Vec2 shear;

    // Which layer this card draws on. HIGHER IS NEARER THE FRONT -- see
    // the header. Assigned in the inspector the way a compositor assigns
    // one, so an artist says "the foreground is layer 30" once and every
    // card they put there stacks correctly, instead of dragging rows.
    int sortingOrder = 0;

    // Which light channels this layer sits on.
    SceneLightMask lightMask = SceneLightMask::layer1();
    // Off makes the layer immune to the whole system -- it draws exactly
    // as it would with no lights in the scene. For a UI plate, a title
    // card, or anything that is a picture OF something rather than a thing
    // in the set.
    bool receivesLight = true;

    // The surface this layer presents to the lights.
    //
    // ON THE LAYER AND NOT ON THE CONTENT, so a plate and a rig instance
    // are the same kind of surface. A rig's NORMAL MAP is the exception
    // and lives on `SceneImage`, because a map is the pair of one PNG and
    // a rig is many PNGs; everything else here is a property of how this
    // card sits in this set, which is a layer's business.
    SceneMaterial material;

    SceneLayerContent content;

    bool operator==(const SceneLayer&) const = default;

    // A card-local point in the card's OWN PLANE: scale, then shear, then
    // roll. ONE function, called by both pictures -- see the header.
    Vec2 planePoint(const Vec2& local) const;

    // A point of the card's own plane, lifted into world space by the
    // layer's tilt: pitch about its x axis, then yaw about its y.
    //
    // Linear and orthonormal -- it takes a plane to a plane and preserves
    // lengths and angles -- which is why it can serve both the card's
    // corners and the gizmo's frame without either restating it.
    Vec3 liftToWorld(const Vec2& planePoint) const;

    // Where the layer's origin sits in world space.
    Vec3 worldOrigin() const { return Vec3(position.x, position.y, positionZ); }

    // The layer's ROTATION, as three orthonormal world axes. Roll, then
    // the tilt; no scale and no shear can reach it, which is what keeps
    // the arrows square to each other however the card is squashed.
    SceneLayerOrientation orientation() const;

    // The plane every pixel this layer draws lies in: a point on it and
    // its normal. Straight off `orientation()`, so no scale and no shear
    // can reach the normal. This is what makes lighting exact -- see the
    // header's flatness note.
    struct Plane {
        Vec3 point;
        Vec3 normal;
    };
    Plane lightingPlane() const;

    // The artwork's own axes in world space: where image +x points, and
    // whether the card is mirrored.
    //
    // The other half of `lightingPlane`, and it exists for the same
    // reason: a normal map stores its normals in TANGENT space (+x across
    // the image, +y up it, +z out of it), and turning one into a world
    // normal needs the world directions those three mean here.
    //
    // Straight off `orientation()`, so no scale and no shear can reach it.
    // The scale gets in only through its SIGN: a card with a negative
    // scale draws its artwork reversed, so image +x points the other way,
    // and the bitangent's handedness is `sign(scale.x * scale.y)`. A
    // mirrored card whose basis is not told it is mirrored lights its
    // relief from the wrong side -- entirely plausible in a still, and
    // obvious the moment a light crosses it.
    //
    // The MAGNITUDE of the scale is deliberately left out, so relief does
    // not stretch with a card scaled 3x wide: a bump on it still lights
    // round. That is the reading an emboss wants, and the same
    // approximation the flat normal has always made.
    struct Tangent {
        Vec3 tangent;
        float handed = 1.0f;
    };
    Tangent lightingTangent() const;

    // Which frame of its clip this layer shows when the scene is at
    // `sceneFrame`. nullopt for anything that is not a rig. A speed of
    // zero freezes the instance on its start frame rather than dividing
    // the timeline by nothing.
    std::optional<int> rigFrame(int sceneFrame, int clipDuration) const;
};

} // namespace umeshcore
