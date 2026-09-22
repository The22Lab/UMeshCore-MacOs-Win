#include "umeshcore/Editor/SceneGizmoDrag.h"

#include <algorithm>
#include <cmath>
#include <limits>

namespace umeshcore {

namespace {

constexpr float kPi = 3.14159265358979323846f;

const SceneGizmoHandleId kAxisOrder[3] = {
    SceneGizmoHandleId::kAxisX, SceneGizmoHandleId::kAxisY, SceneGizmoHandleId::kAxisZ};
const SceneGizmoHandleId kPlaneOrder[3] = {
    SceneGizmoHandleId::kPlaneXY, SceneGizmoHandleId::kPlaneXZ, SceneGizmoHandleId::kPlaneYZ};

template <typename Value>
const Value* find(
    const std::vector<std::pair<SceneGizmoHandleId, Value>>& entries, SceneGizmoHandleId id) {
    for (const auto& entry : entries) {
        if (entry.first == id) return &entry.second;
    }
    return nullptr;
}

float wrapToPi(float angle) {
    while (angle > kPi) angle -= 2.0f * kPi;
    while (angle < -kPi) angle += 2.0f * kPi;
    return angle;
}

} // namespace

// ---- The projected shape ------------------------------------------------

std::optional<SceneGizmoShape> buildGizmoShape(
    const SceneGizmoState& state, const LightWorldGeometry* lightGeometry) {
    const std::optional<Vec2> originPx = state.map(state.basis.origin);
    if (!originPx.has_value()) return std::nullopt;

    SceneGizmoShape shape;
    shape.originPx = *originPx;
    shape.ringRadiusPx = kSceneGizmoHandlePixels;

    for (SceneGizmoHandleId id : kAxisOrder) {
        const std::optional<Vec3> direction = state.basis.direction(id);
        if (!direction.has_value()) continue;
        const std::optional<SceneGizmoScreenAxis> axis = projectAxis(state, *direction);
        if (axis.has_value()) shape.axes.emplace_back(id, *axis);
        // The ring for an axis turns ABOUT that axis, so the axis is the
        // circle's normal.
        std::vector<std::vector<Vec2>> arcs = ringArcs(state, *direction, state.scale);
        if (!arcs.empty()) shape.rings.emplace_back(id, std::move(arcs));
    }

    for (SceneGizmoHandleId id : kPlaneOrder) {
        const std::optional<std::vector<Vec2>> quad = planeQuad(state, id);
        if (quad.has_value()) shape.planes.emplace_back(id, *quad);
    }

    // A light's dots go through the REAL projection: its diagram is not
    // part of this pass's stabilisation, only the shared manipulator is.
    if (lightGeometry != nullptr) {
        for (const auto& entry : lightGeometry->handlePositions) {
            const std::optional<Vec2> px = state.realProjection.project(entry.second);
            if (px.has_value()) shape.lightHandles.emplace_back(entry.first, *px);
        }
    }
    return shape;
}

// ---- The hit test -------------------------------------------------------

std::optional<SceneGizmoHit> hitTestGizmo(
    const SceneGizmoShape& shape, const Vec2& pointPx, SceneGizmoTool tool, float lightGrabPx) {
    // A LIGHT'S OWN HANDLES FIRST, and by NEAREST rather than by first
    // match -- see the header.
    {
        std::optional<std::pair<SceneLightHandle, float>> nearestLight;
        for (const auto& entry : shape.lightHandles) {
            const float d = length(pointPx - entry.second);
            if (!(d <= lightGrabPx)) continue;
            if (!nearestLight.has_value() || d < nearestLight->second) {
                nearestLight = std::make_pair(entry.first, d);
            }
        }
        if (nearestLight.has_value()) {
            return SceneGizmoHit{SceneGizmoHandleId::kLight, std::nullopt, nearestLight->first};
        }
    }

    struct Best {
        SceneGizmoHandleId id;
        std::optional<SceneGizmoScreenAxis> axis;
        float distance;
    };
    std::optional<Best> best;

    if (tool == SceneGizmoTool::kRotate) {
        // Nearest ring wins, and a ring is a POLYLINE, so the test is the
        // distance to the nearest of its segments: an ellipse seen edge-on
        // is a line, and a radial test around a circle would never find it.
        for (SceneGizmoHandleId id : kAxisOrder) {
            const auto* arcs = find(shape.rings, id);
            if (arcs == nullptr) continue;
            float nearest = std::numeric_limits<float>::max();
            for (const std::vector<Vec2>& arc : *arcs) {
                for (std::size_t i = 0; i + 1 < arc.size(); ++i) {
                    nearest = std::min(nearest, distanceToSegment(pointPx, arc[i], arc[i + 1]));
                }
            }
            if (nearest <= kSceneGizmoGrabPixels &&
                (!best.has_value() || nearest < best->distance)) {
                best = Best{id, std::nullopt, nearest};
            }
        }
        // The fourth ring is honestly screen-space, so its test is radial.
        const float outer = shape.ringRadiusPx * kSceneGizmoViewRingScale;
        const float radial = std::fabs(length(pointPx - shape.originPx) - outer);
        if (radial <= kSceneGizmoGrabPixels && (!best.has_value() || radial < best->distance)) {
            best = Best{SceneGizmoHandleId::kViewRing, std::nullopt, radial};
        }
    } else {
        // Planes first, and only for translate: a quad is an area, so
        // being INSIDE it is the test.
        if (tool == SceneGizmoTool::kTranslate) {
            for (SceneGizmoHandleId id : kPlaneOrder) {
                const auto* quad = find(shape.planes, id);
                if (quad == nullptr || quad->size() != 4) continue;
                if (convexContains(*quad, pointPx)) return SceneGizmoHit{id, std::nullopt};
            }
        }
        for (SceneGizmoHandleId id : kAxisOrder) {
            const auto* axis = find(shape.axes, id);
            if (axis == nullptr) continue;
            const float d = distanceToSegment(pointPx, axis->origin, axis->tip);
            if (d <= kSceneGizmoGrabPixels && (!best.has_value() || d < best->distance)) {
                best = Best{id, *axis, d};
            }
        }
        // The centre handle: free move for translate, uniform for scale.
        // Shear has none -- there is no "slant everything equally".
        if (tool != SceneGizmoTool::kShear) {
            const float d = length(pointPx - shape.originPx);
            if (d <= kSceneGizmoGrabPixels && (!best.has_value() || d < best->distance)) {
                best = Best{
                    tool == SceneGizmoTool::kScale ? SceneGizmoHandleId::kUniform
                                                   : SceneGizmoHandleId::kFree,
                    std::nullopt, d};
            }
        }
    }

    if (!best.has_value()) return std::nullopt;
    return SceneGizmoHit{best->id, best->axis, std::nullopt};
}

// ---- The measurements ---------------------------------------------------

std::optional<float> axisDragUnits(
    const SceneProjection& projection, const Vec2& startPx, const Vec2& nowPx, const Vec3& origin,
    const Vec3& direction) {
    const std::optional<float> t0 = projection.axisParameter(startPx, origin, direction);
    const std::optional<float> t1 = projection.axisParameter(nowPx, origin, direction);
    if (!t0.has_value() || !t1.has_value()) return std::nullopt;
    return *t1 - *t0;
}

std::optional<Vec3> planeDragDelta(
    const SceneProjection& projection, const Vec2& startPx, const Vec2& nowPx, const Vec3& pivot,
    const Vec3& normal) {
    const std::optional<Vec3> a = projection.hitPlane(startPx, pivot, normal);
    const std::optional<Vec3> b = projection.hitPlane(nowPx, pivot, normal);
    if (!a.has_value() || !b.has_value()) return std::nullopt;
    return *b - *a;
}

std::optional<float> ringDragAngle(
    const SceneProjection& projection, const Vec2& startPx, const Vec2& nowPx, const Vec3& pivot,
    const Vec3& normal) {
    const GizmoRingFrame frame = gizmoRingFrame(normal);
    const std::optional<Vec3> a = projection.hitPlane(startPx, pivot, normal);
    const std::optional<Vec3> b = projection.hitPlane(nowPx, pivot, normal);
    if (!a.has_value() || !b.has_value()) return std::nullopt;
    const auto angle = [&](const Vec3& point) {
        const Vec3 d = point - pivot;
        return std::atan2(dot(d, frame.v), dot(d, frame.u));
    };
    return wrapToPi(angle(*b) - angle(*a));
}

float screenAngleDelta(const Vec2& originPx, const Vec2& startPx, const Vec2& nowPx) {
    const float a = std::atan2(startPx.y - originPx.y, startPx.x - originPx.x);
    const float b = std::atan2(nowPx.y - originPx.y, nowPx.x - originPx.x);
    return wrapToPi(b - a);
}

// ---- Applying a drag ----------------------------------------------------

namespace {

void applyTranslate(
    SceneLayer& layer, const SceneLayer& start, const SceneGizmoDrag& drag, const Vec2& nowPx,
    const SceneProjection& projection) {
    const SceneGizmoBasis basis = translateBasis(start, SceneGizmoTool::kTranslate);
    switch (drag.handle) {
        case SceneGizmoHandleId::kAxisX:
        case SceneGizmoHandleId::kAxisY:
        case SceneGizmoHandleId::kAxisZ: {
            // The axis is a WORLD direction here, per `translateBasis`, so
            // `amount` is already a literal world distance along a pure
            // axis and goes straight to the one field that axis IS -- no
            // further transform, because there is no rotation left to undo.
            const std::optional<Vec3> direction = basis.direction(drag.handle);
            if (!direction.has_value()) return;
            const std::optional<float> amount =
                axisDragUnits(projection, drag.startPx, nowPx, basis.origin, *direction);
            if (!amount.has_value()) return;
            if (drag.handle == SceneGizmoHandleId::kAxisX) {
                layer.position.x = start.position.x + *amount;
            } else if (drag.handle == SceneGizmoHandleId::kAxisY) {
                layer.position.y = start.position.y + *amount;
            } else {
                layer.positionZ = start.positionZ + *amount;
            }
            return;
        }
        case SceneGizmoHandleId::kPlaneXY:
        case SceneGizmoHandleId::kPlaneXZ:
        case SceneGizmoHandleId::kPlaneYZ: {
            const std::optional<Vec3> normal = planeNormal(drag.handle, basis);
            if (!normal.has_value()) return;
            const std::optional<Vec3> delta =
                planeDragDelta(projection, drag.startPx, nowPx, basis.origin, *normal);
            if (!delta.has_value()) return;
            const PlaneAxes axes = planeAxes(drag.handle, basis);
            const float da = dot(*delta, axes.a);
            const float db = dot(*delta, axes.b);
            if (drag.handle == SceneGizmoHandleId::kPlaneXY) {
                layer.position = start.position + Vec2(da, db);
            } else if (drag.handle == SceneGizmoHandleId::kPlaneXZ) {
                layer.position.x = start.position.x + da;
                layer.positionZ = start.positionZ + db;
            } else {
                layer.position.y = start.position.y + da;
                layer.positionZ = start.positionZ + db;
            }
            return;
        }
        case SceneGizmoHandleId::kFree: {
            // Free move slides the card across the WORLD XY plane through
            // its origin -- the plane the screen-space free-move square
            // always meant, now that the basis is world axes rather than
            // the card's own tilted plane.
            const std::optional<Vec3> delta =
                planeDragDelta(projection, drag.startPx, nowPx, basis.origin, basis.z);
            if (!delta.has_value()) return;
            layer.position = start.position + Vec2(delta->x, delta->y);
            return;
        }
        default: return;
    }
}

void applyScale(
    SceneLayer& layer, const SceneLayer& start, const SceneGizmoDrag& drag, const Vec2& nowPx,
    const Vec2& originPx) {
    // A RATIO of distances from the origin, so the handle stays under the
    // pointer without any unit conversion at all.
    const float startDist = std::max(length(drag.startPx - originPx), 1.0f);
    const float nowDist = length(nowPx - originPx);
    const float factor = std::max(nowDist / startDist, 0.01f);
    switch (drag.handle) {
        case SceneGizmoHandleId::kAxisX:
            layer.scale.x = std::max(start.scale.x * factor, 0.01f);
            return;
        case SceneGizmoHandleId::kAxisY:
            layer.scale.y = std::max(start.scale.y * factor, 0.01f);
            return;
        case SceneGizmoHandleId::kUniform:
            layer.scale = Vec2(
                std::max(start.scale.x * factor, 0.01f), std::max(start.scale.y * factor, 0.01f));
            return;
        default: return;
    }
}

void applyShear(
    SceneLayer& layer, const SceneLayer& start, const SceneGizmoDrag& drag, const Vec2& nowPx,
    const SceneProjection& projection, const Vec2& cardHalfExtent) {
    const SceneGizmoBasis basis = layerBasis(start);
    if (drag.handle == SceneGizmoHandleId::kAxisZ) {
        // THE THIRD SLANT. A flat card has only two in-plane shears, so
        // the z handle does the thing the artist was actually missing: it
        // tips the card out of its plane. Along the handle pitches it,
        // across it yaws.
        //
        // Still measured in PIXELS, deliberately: this is not a slant with
        // a geometric size, it is a rate -- "how much tip per how much
        // drag" -- so there is no world quantity for a ray to find.
        if (!drag.axis.has_value()) return;
        const Vec2 delta = nowPx - drag.startPx;
        const float along = dot(delta, drag.axis->direction);
        const float across = -delta.x * drag.axis->direction.y + delta.y * drag.axis->direction.x;
        layer.rotation3D.x = start.rotation3D.x + along * kSceneGizmoRadiansPerPixel;
        layer.rotation3D.y = start.rotation3D.y + across * kSceneGizmoRadiansPerPixel;
        return;
    }

    // The handle slides ACROSS its axis, and the slant is that offset over
    // the card's own extent -- so dragging the handle by the card's height
    // is a shear of 1, whatever size the card is. Measured IN THE CARD'S
    // PLANE, like every other drag here: the screen version divided by a
    // pixels-per-unit read at the pivot, so the slant ran ahead of the
    // pointer on the near side of a tilted card and behind it on the far.
    const std::optional<Vec3> delta =
        planeDragDelta(projection, drag.startPx, nowPx, basis.origin, basis.z);
    if (!delta.has_value()) return;
    if (drag.handle == SceneGizmoHandleId::kAxisX) {
        layer.shear.y = start.shear.y + dot(*delta, basis.y) / std::max(cardHalfExtent.x, 0.001f);
    } else if (drag.handle == SceneGizmoHandleId::kAxisY) {
        layer.shear.x = start.shear.x - dot(*delta, basis.x) / std::max(cardHalfExtent.y, 0.001f);
    }
}

void applyRotate(
    SceneLayer& layer, const SceneLayer& start, const SceneGizmoDrag& drag, const Vec2& nowPx,
    const SceneProjection& projection, const Vec2& originPx) {
    const SceneGizmoBasis basis = layerBasis(start);
    switch (drag.handle) {
        case SceneGizmoHandleId::kAxisX:
        case SceneGizmoHandleId::kAxisY:
        case SceneGizmoHandleId::kAxisZ: {
            const std::optional<Vec3> normal = basis.direction(drag.handle);
            if (!normal.has_value()) return;
            const std::optional<float> turn =
                ringDragAngle(projection, drag.startPx, nowPx, basis.origin, *normal);
            if (!turn.has_value()) return;
            if (drag.handle == SceneGizmoHandleId::kAxisZ) {
                // The card's own normal: turning about it is the card's roll.
                layer.rotation = start.rotation + *turn;
            } else if (drag.handle == SceneGizmoHandleId::kAxisX) {
                layer.rotation3D.x = start.rotation3D.x + *turn;
            } else {
                layer.rotation3D.y = start.rotation3D.y + *turn;
            }
            return;
        }
        case SceneGizmoHandleId::kViewRing:
            // About the axis you are looking along. THIS one is honestly a
            // screen-space handle -- its plane is the screen -- so a screen
            // angle is not an approximation here, it is the definition. It
            // is also the ring that always works: the three world rings
            // each vanish edge-on at some angle.
            layer.rotation = start.rotation + screenAngleDelta(originPx, drag.startPx, nowPx);
            return;
        default: return;
    }
}

} // namespace

void applyLayerDrag(
    SceneLayer& layer, const SceneLayer& start, SceneGizmoTool tool, const SceneGizmoDrag& drag,
    const Vec2& nowPx, const SceneProjection& projection, const Vec2& cardHalfExtent) {
    // The gizmo's origin on screen, through the REAL camera -- which is
    // where the stabilised projection's recentre-then-slide lands anyway.
    const std::optional<Vec2> originPx = projection.project(start.worldOrigin());

    switch (tool) {
        case SceneGizmoTool::kTranslate:
            applyTranslate(layer, start, drag, nowPx, projection);
            return;
        case SceneGizmoTool::kScale:
            if (!originPx.has_value()) return;
            applyScale(layer, start, drag, nowPx, *originPx);
            return;
        case SceneGizmoTool::kShear:
            applyShear(layer, start, drag, nowPx, projection, cardHalfExtent);
            return;
        case SceneGizmoTool::kRotate:
            if (!originPx.has_value() && drag.handle == SceneGizmoHandleId::kViewRing) return;
            applyRotate(
                layer, start, drag, nowPx, projection,
                originPx.has_value() ? *originPx : Vec2::zero());
            return;
    }
}

// ---- Dragging a light ---------------------------------------------------

void applyLightDrag(
    SceneLight& light, const SceneLight& start, SceneGizmoTool tool, const SceneGizmoDrag& drag,
    const Vec2& nowPx, const SceneProjection& projection, const Vec2& originPx) {
    const Vec3 centre = start.world();

    // Where the pointer is, on the world plane through the light that
    // faces the camera. Every one of a light's own handles is answered
    // here, which is what keeps the grabbed point under the pointer at any
    // camera angle.
    const auto facingHit = [&]() {
        return projection.hitPlane(nowPx, centre, lightViewAxis(projection));
    };

    if (drag.handle == SceneGizmoHandleId::kLight) {
        if (!drag.lightHandle.has_value()) return;
        switch (*drag.lightHandle) {
            case SceneLightHandle::kRadius: {
                const std::optional<Vec3> hit = facingHit();
                if (!hit.has_value()) return;
                const float radius = lightRadiusForHit(*hit, centre);
                light.radius = radius;
                // THE BAND is what the artist was looking at, so it is
                // what is preserved. Softness is a fraction of the radius,
                // so leaving it alone would make the fade grow with the
                // radius and the light would change shape while being
                // resized.
                if (start.radius > 1e-5f && radius > 1e-5f) {
                    const float band = start.radius * start.softness;
                    light.softness = std::min(std::max(band / radius, 0.0f), 1.0f);
                }
                return;
            }
            case SceneLightHandle::kSoftness: {
                const std::optional<Vec3> hit = facingHit();
                if (!hit.has_value()) return;
                light.softness = lightSoftnessForHit(*hit, centre, start.radius);
                return;
            }
            case SceneLightHandle::kDirection: {
                const std::optional<Vec3> hit = facingHit();
                if (!hit.has_value()) return;
                const Vec3 aim = *hit - centre;
                if (!(length(aim) > 1e-5f)) return;
                aimLight(light, aim);
                return;
            }
            case SceneLightHandle::kInnerAngle:
            case SceneLightHandle::kOuterAngle: {
                // In the CONE'S OWN PLANE, not the facing one.
                const Vec3 across = lightConePlane(start.direction(), projection);
                const Vec3 normal = cross(start.direction(), across);
                const std::optional<Vec3> hit = projection.hitPlane(nowPx, centre, normal);
                if (!hit.has_value()) return;
                const std::optional<float> angle =
                    lightHalfAngleForHit(*hit, centre, start.direction());
                if (!angle.has_value()) return;
                if (*drag.lightHandle == SceneLightHandle::kOuterAngle) {
                    light.outerAngle = std::min(std::max(*angle, 0.0f), kPi);
                    // The inner cone cannot outgrow the outer one, or the
                    // smoothstep between them would run backwards.
                    light.innerAngle = std::min(start.innerAngle, light.outerAngle);
                } else {
                    light.innerAngle = std::min(std::max(*angle, 0.0f), start.outerAngle);
                }
                return;
            }
        }
        return;
    }

    const SceneGizmoBasis basis = lightBasis(start);
    const auto place = [&](const Vec3& moved) {
        light.position = Vec2(moved.x, moved.y);
        light.positionZ = moved.z;
    };

    switch (tool) {
        case SceneGizmoTool::kTranslate:
            switch (drag.handle) {
                case SceneGizmoHandleId::kAxisX:
                case SceneGizmoHandleId::kAxisY:
                case SceneGizmoHandleId::kAxisZ: {
                    const std::optional<Vec3> direction = basis.direction(drag.handle);
                    if (!direction.has_value()) return;
                    const std::optional<float> amount =
                        axisDragUnits(projection, drag.startPx, nowPx, basis.origin, *direction);
                    if (!amount.has_value()) return;
                    place(centre + *direction * *amount);
                    return;
                }
                case SceneGizmoHandleId::kPlaneXY:
                case SceneGizmoHandleId::kPlaneXZ:
                case SceneGizmoHandleId::kPlaneYZ: {
                    const std::optional<Vec3> normal = planeNormal(drag.handle, basis);
                    if (!normal.has_value()) return;
                    const std::optional<Vec3> delta =
                        planeDragDelta(projection, drag.startPx, nowPx, basis.origin, *normal);
                    if (!delta.has_value()) return;
                    place(centre + *delta);
                    return;
                }
                case SceneGizmoHandleId::kFree: {
                    // Across the plane the artist is looking at, which is
                    // the one plane a pointer can specify a point in
                    // without a third number.
                    const std::optional<Vec3> delta = planeDragDelta(
                        projection, drag.startPx, nowPx, basis.origin, lightViewAxis(projection));
                    if (!delta.has_value()) return;
                    place(centre + *delta);
                    return;
                }
                default: return;
            }
        case SceneGizmoTool::kRotate: {
            // AIMING, not orienting. A light stores where it points, so a
            // turn is applied to its direction and re-expressed. A turn
            // about the beam itself comes back as no change, which is
            // correct: a cone has nothing to roll.
            if (start.kind == SceneLightKind::kPoint) return;
            if (drag.handle == SceneGizmoHandleId::kViewRing) {
                const float turn = screenAngleDelta(originPx, drag.startPx, nowPx);
                aimLight(
                    light, rotatedAbout(start.direction(), lightViewAxis(projection), turn));
                return;
            }
            const std::optional<Vec3> axis = basis.direction(drag.handle);
            if (!axis.has_value()) return;
            const std::optional<float> turn =
                ringDragAngle(projection, drag.startPx, nowPx, basis.origin, *axis);
            if (!turn.has_value()) return;
            aimLight(light, rotatedAbout(start.direction(), *axis, *turn));
            return;
        }
        case SceneGizmoTool::kScale:
        case SceneGizmoTool::kShear:
            // A light has no size to scale and no plane to slant.
            return;
    }
}

void applyCameraDrag(
    SceneCamera& camera, const SceneCamera& start, SceneGizmoTool tool,
    const SceneGizmoDrag& drag, const Vec2& nowPx, const SceneProjection& projection,
    const Vec2& originPx) {
    const SceneGizmoBasis basis = cameraBasis(start);
    switch (tool) {
        case SceneGizmoTool::kTranslate: {
            // The camera's handles are the WORLD's axes, and they go
            // through the same world-space measurement every other handle
            // does.
            const std::optional<Vec3> direction = basis.direction(drag.handle);
            if (!direction.has_value()) return;
            const std::optional<float> amount =
                axisDragUnits(projection, drag.startPx, nowPx, basis.origin, *direction);
            if (!amount.has_value()) return;
            if (drag.handle == SceneGizmoHandleId::kAxisX) {
                camera.position.x = start.position.x + *amount;
            } else if (drag.handle == SceneGizmoHandleId::kAxisY) {
                camera.position.y = start.position.y + *amount;
            } else {
                camera.positionZ = start.positionZ + *amount;
            }
            return;
        }
        case SceneGizmoTool::kRotate: {
            if (drag.handle == SceneGizmoHandleId::kViewRing) {
                camera.rotation3D.z =
                    start.rotation3D.z + screenAngleDelta(originPx, drag.startPx, nowPx);
                return;
            }
            const std::optional<Vec3> normal = basis.direction(drag.handle);
            if (!normal.has_value()) return;
            const std::optional<float> turn =
                ringDragAngle(projection, drag.startPx, nowPx, basis.origin, *normal);
            if (!turn.has_value()) return;
            if (drag.handle == SceneGizmoHandleId::kAxisZ) {
                camera.rotation3D.z = start.rotation3D.z + *turn;
            } else if (drag.handle == SceneGizmoHandleId::kAxisX) {
                camera.rotation3D.x = start.rotation3D.x + *turn;
            } else {
                camera.rotation3D.y = start.rotation3D.y + *turn;
            }
            return;
        }
        case SceneGizmoTool::kScale:
        case SceneGizmoTool::kShear:
            // A camera has neither.
            return;
    }
}

// ---- The screen predicates ----------------------------------------------

float distanceToSegment(const Vec2& point, const Vec2& a, const Vec2& b) {
    const Vec2 v = b - a;
    const float lengthSquared = dot(v, v);
    if (!(lengthSquared > 0.0001f)) return length(point - a);
    float t = dot(point - a, v) / lengthSquared;
    t = std::min(std::max(t, 0.0f), 1.0f);
    return length(point - (a + v * t));
}

bool convexContains(const std::vector<Vec2>& polygon, const Vec2& point) {
    if (polygon.size() < 3) return false;
    int positive = 0, negative = 0;
    for (std::size_t i = 0; i < polygon.size(); ++i) {
        const Vec2& a = polygon[i];
        const Vec2& b = polygon[(i + 1) % polygon.size()];
        const float side = (b.x - a.x) * (point.y - a.y) - (b.y - a.y) * (point.x - a.x);
        if (side > 0.0f) {
            ++positive;
        } else if (side < 0.0f) {
            ++negative;
        }
    }
    return positive == 0 || negative == 0;
}

} // namespace umeshcore
