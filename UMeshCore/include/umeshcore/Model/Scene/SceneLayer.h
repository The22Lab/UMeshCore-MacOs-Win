#pragma once

// 1:1 port of `Data/Scene/SceneLayer.swift` -- one card in a Scene, at its
// own depth.
//
// EVERY LAYER IS FLAT: its Z is constant across the whole card. That is
// the model's founding invariant, and most of Phase 4 rests on it --
// `SceneLighting` intersects the ray through a pixel with the layer's
// plane and gets the exact world point, and `SceneOccluder` reads a single
// texel because a ray crosses a plane segment exactly once. It is the
// After Effects model, and it is what the artist asked for.

#include <cstdint>
#include <string>
#include <variant>

#include "umeshcore/Core/Uuid.h"
#include "umeshcore/Math/Vec.h"
#include "umeshcore/Model/Scene/SceneLight.h"
#include "umeshcore/Model/Scene/SceneMaterial.h"

namespace umeshcore {

// A flat fill -- a sky, a fog bank, a colour card behind everything.
struct SceneFill {
    Vec4 topColor;
    Vec4 bottomColor;

    bool operator==(const SceneFill&) const = default;

    // True when both stops match, i.e. a plain colour rather than a ramp.
    bool isFlat() const { return topColor == bottomColor; }

    // A neutral GREY ramp. It used to be a dark blue, and a blue ground is
    // not neutral: every colour placed on the set was judged against a
    // tint, so a warm plate read warmer than it is. Still a ramp rather
    // than a flat fill, so an empty scene reads as a space with a floor
    // rather than as a blank.
    static SceneFill neutral() {
        return SceneFill{Vec4(0.34f, 0.34f, 0.34f, 1), Vec4(0.46f, 0.46f, 0.46f, 1)};
    }
    static SceneFill solid(const Vec4& color) { return SceneFill{color, color}; }
};

// What a Scene layer actually draws.
//
// DELIBERATELY CLOSED. A Scene assembles work that already exists -- it
// does not author it -- so there is no case here for "a mesh being edited"
// or "a bone chain". Rigging stays in Editor and animation stays in
// Animator.
struct SceneRigContent {
    // An instance of this project's rig, playing one of its clips. The
    // same rig can appear more than once at different depths and different
    // points in its clip -- three birds from one bird rig -- which is only
    // possible because a clip's pose is a pure function of the frame, so a
    // pose can be sampled without disturbing the scene being edited.
    Uuid clipID;
    float speed = 1.0f;
    int startFrame = 0;
    bool loops = true;
    bool operator==(const SceneRigContent&) const = default;
};

// A plain image: a backdrop, a foreground plate, a cloud bank.
struct ScenePlateContent {
    Uuid assetID;
    bool operator==(const ScenePlateContent&) const = default;
};

// A colour or vertical ramp, for skies and fog without needing a PNG.
using SceneLayerContent = std::variant<SceneRigContent, ScenePlateContent, SceneFill>;

inline bool contentIsFill(const SceneLayerContent& content) {
    return std::holds_alternative<SceneFill>(content);
}

struct SceneLayer {
    Uuid id;
    std::string name;
    bool isHidden = false;
    float opacity = 1.0f;

    Vec2 position;
    // Depth. Higher is further from the camera.
    float positionZ = 0.0f;
    // Roll, in radians -- the card spinning in its own plane.
    float rotation = 0.0f;
    // Pitch and yaw tilt the card out of its plane; z is unused because
    // `rotation` already carries roll. Kept as a Vec3 to match the
    // convention `SceneImage::rotation3D` established in the rig.
    Vec3 rotation3D;
    Vec2 scale = Vec2(1, 1);
    // Slant, as a pair of tangents: x slides a point sideways by its
    // height, y slides it vertically by its width. The same shape
    // `SceneImage::skew` uses, so the number an artist learns in one place
    // means the same in the other.
    Vec2 shear;

    // Which layer this card is drawn on. HIGHER IS NEARER THE FRONT.
    //
    // Nearer the front for higher numbers, which is the opposite of
    // `positionZ` and deliberately so: Z is a distance, and things further
    // away have more of it, while a layer number is a stacking order and
    // every tool that has one counts it upward towards the viewer.
    // Matching Z here would have made the two numbers look interchangeable
    // when they do the opposite.
    //
    // DEPTH STILL DOES NOT REORDER ANYTHING. Pushing a card back in Z
    // changes how big it draws and how fast it slides, and nothing about
    // who covers whom.
    int sortingOrder = 0;

    // Which light channels this layer sits on. The performance control as
    // much as the artistic one: a light that cannot reach a layer is never
    // evaluated over it.
    SceneLightMask lightMask = SceneLightMask::layer1();
    // Off makes the layer immune to the whole system -- it draws exactly
    // as it would with no lights in the scene. For a UI plate, a title
    // card, or anything that is a picture OF something rather than a thing
    // in the set.
    bool receivesLight = true;

    // The surface this layer presents to the lights. ON THE LAYER AND NOT
    // ON THE CONTENT, so a plate and a rig instance are the same kind of
    // surface. A rig's normal map is the exception and lives on
    // `SceneImage`, because a map is the pair of one PNG and a rig is many
    // PNGs.
    SceneMaterial material;

    SceneLayerContent content = SceneFill::neutral();

    bool operator==(const SceneLayer&) const = default;

    // A card-local point in the card's OWN PLANE: scale, then shear, then
    // roll.
    //
    // ONE function, called by both pictures. The shot's projection and the
    // fly view's card geometry each used to inline this, and two copies of
    // a transform is how one ends up missing a term -- the rig side of
    // this editor already has exactly that bug between its canvas and its
    // exporter.
    //
    // THE ORDER IS THE DEFINITION. Shear is applied after the scale, so it
    // is expressed in the card's SCALED units -- the same order
    // `SceneImage` applies skew in -- and a scaled card slants by the
    // amount the number says rather than by that amount times its scale.
    Vec2 planePoint(const Vec2& local) const;

    // A point of the card's own plane, lifted into world space by the
    // layer's tilt: pitch about its x axis, then yaw about its y.
    //
    // Linear and orthonormal -- it takes a plane to a plane and preserves
    // lengths and angles -- which is why it can serve both the card's
    // corners and the gizmo's frame without either one restating it.
    Vec3 liftToWorld(const Vec2& planePoint) const;

    // Where the layer's origin sits in world space.
    Vec3 worldOrigin() const { return Vec3(position.x, position.y, positionZ); }

    struct Plane {
        Vec3 point;
        Vec3 normal;
    };

    // The plane every pixel this layer draws lies in.
    //
    // This is what makes lighting EXACT rather than approximate: a layer
    // is flat, so the ray through any pixel it covers meets this plane at
    // the world point that is actually there, whatever the layer contains,
    // however it is tilted, and however its meshes are deformed. Straight
    // off `orientation()`, so no scale and no shear can reach the normal.
    Plane lightingPlane() const;

    struct TangentFrame {
        Vec3 tangent;
        float handed;
    };

    // The artwork's own axes in world space: where image +x points, and
    // whether the card is mirrored. The other half of `lightingPlane`, and
    // it exists for the same reason -- a normal map stores its normals in
    // tangent space, and turning one into a world normal needs the world
    // directions those three mean here.
    //
    // STRAIGHT OFF `orientation()`, so no scale and no shear can reach it.
    // The scale gets in only through its SIGN: a card with a negative
    // scale draws its artwork reversed, so image +x points the other way,
    // and the handedness is `sign(scale.x * scale.y)`. A mirrored card
    // whose basis is not told it is mirrored lights its relief from the
    // wrong side -- plausible in a still, obvious the moment a light
    // crosses it.
    //
    // The MAGNITUDE of the scale is deliberately left out, so relief does
    // not stretch with a card scaled 3x wide: a bump on it still lights
    // round, which is the reading an emboss wants.
    TangentFrame lightingTangent() const;

    struct Orientation {
        Vec3 x;
        Vec3 y;
        Vec3 z;
    };

    // The layer's ROTATION, as three orthonormal world axes.
    //
    // This is what a manipulator hangs off, and the reason it exists
    // separately from `planePoint` is the whole of a bug: the gizmo used
    // to take its frame by differencing the card's own transform, which
    // runs a point through `planePoint` -- scale first, then SHEAR, then
    // roll. Normalising the two vectors that came back fixed their lengths
    // and could do nothing about the angle between them, so a sheared card
    // handed the gizmo a frame that was not a rotation. A matrix like that
    // shears every arrow it multiplies.
    Orientation orientation() const;

    // Which frame of its clip this layer shows when the scene is at
    // `sceneFrame`. Absent for anything that is not a rig. A speed of zero
    // freezes the instance on its start frame rather than dividing the
    // timeline by nothing.
    std::optional<int> rigFrame(int sceneFrame, int clipDuration) const;
};

} // namespace umeshcore
