#include "umeshcore/Serialization/SavedScene.h"

#include <algorithm>
#include <cmath>

#include "umeshcore/Math/MatrixUtilities.h"
#include "umeshcore/Serialization/SavedGeometry.h"

namespace umeshcore {

namespace {

float clampf(float value, float lo, float hi) { return std::min(std::max(value, lo), hi); }

float floatOr(const JsonValue& j, const char* key, float fallback) {
    const JsonValue* found = j.find(key);
    return found != nullptr && !found->isNull() ? found->asFloat() : fallback;
}

bool boolOr(const JsonValue& j, const char* key, bool fallback) {
    const JsonValue* found = j.find(key);
    return found != nullptr && !found->isNull() ? found->asBool() : fallback;
}

int intOr(const JsonValue& j, const char* key, int fallback) {
    const JsonValue* found = j.find(key);
    return found != nullptr && !found->isNull() ? found->asInt() : fallback;
}

std::optional<Uuid> optionalUuid(const JsonValue& j, const char* key) {
    const JsonValue* found = j.find(key);
    if (found == nullptr || found->isNull()) return std::nullopt;
    return uuidFromJson(*found);
}

// A Vec4 colour that survives a truncated array: Swift's `SavedSceneFill`
// guards `components.count == 4` and falls back to opaque black rather
// than indexing off the end.
Vec4 colorOrBlack(const JsonValue* j) {
    if (j == nullptr || !j->isArray() || j->asArray().size() != 4) return Vec4(0, 0, 0, 1);
    const JsonValue::Array& a = j->asArray();
    return Vec4(a[0].asFloat(), a[1].asFloat(), a[2].asFloat(), a[3].asFloat());
}

JsonValue colorToJson(const Vec4& c) {
    JsonValue::Array a;
    a.push_back(JsonValue::makeNumber(c.x));
    a.push_back(JsonValue::makeNumber(c.y));
    a.push_back(JsonValue::makeNumber(c.z));
    a.push_back(JsonValue::makeNumber(c.w));
    return JsonValue::makeArray(std::move(a));
}

// The three layer kinds, as STRINGS and not ordinals -- the rule this
// whole family follows. An int raw value would make the on-disk format
// depend on the declaration order of an enum, so inserting a case between
// two others would silently re-read every saved scene as something else.
const char* layerKindName(const SceneLayerContent& content) {
    if (std::holds_alternative<SceneRigContent>(content)) return "rig";
    if (std::holds_alternative<ScenePlateContent>(content)) return "plate";
    return "fill";
}

} // namespace

// ---- SceneFill ---------------------------------------------------------

JsonValue toJson(const SceneFill& fill) {
    JsonValue j = JsonValue::makeObject();
    j.set("topColor", colorToJson(fill.topColor));
    j.set("bottomColor", colorToJson(fill.bottomColor));
    return j;
}

SceneFill sceneFillFromJson(const JsonValue& j) {
    SceneFill fill;
    fill.topColor = colorOrBlack(j.find("topColor"));
    fill.bottomColor = colorOrBlack(j.find("bottomColor"));
    return fill;
}

// ---- SceneCamera (the SHOT camera) -------------------------------------

JsonValue toJson(const SceneCamera& camera) {
    JsonValue j = JsonValue::makeObject();
    j.set("position", toJson(camera.position));
    j.set("positionZ", JsonValue::makeNumber(camera.positionZ));
    j.set("rotation3D", toJson(camera.rotation3D));
    j.set("fieldOfView", JsonValue::makeNumber(camera.fieldOfView));
    j.set("nearZ", JsonValue::makeNumber(camera.nearZ));
    j.set("farZ", JsonValue::makeNumber(camera.farZ));
    return j;
}

SceneCamera sceneCameraFromJson(const JsonValue& j) {
    SceneCamera camera;
    const JsonValue* position = j.find("position");
    if (position != nullptr && !position->isNull()) camera.position = vec2FromJson(*position);
    camera.positionZ = floatOr(j, "positionZ", camera.positionZ);
    const JsonValue* rotation = j.find("rotation3D");
    if (rotation != nullptr && !rotation->isNull()) camera.rotation3D = vec3FromJson(*rotation);
    // Clamped on the way in, not just in the UI: a hand-edited or corrupt
    // file must not produce a camera that divides by tan(0) or draws
    // nothing forever.
    camera.fieldOfView = clampf(floatOr(j, "fieldOfView", camera.fieldOfView), 1.0f, 170.0f);
    camera.nearZ = std::max(floatOr(j, "nearZ", camera.nearZ), 0.01f);
    camera.farZ = std::max(floatOr(j, "farZ", camera.farZ), camera.nearZ + 1.0f);
    return camera;
}

// ---- Lights ------------------------------------------------------------

JsonValue toJson(const LightFalloffStop& stop) {
    JsonValue j = JsonValue::makeObject();
    j.set("position", JsonValue::makeNumber(stop.position));
    j.set("value", JsonValue::makeNumber(stop.value));
    if (stop.inTangent) j.set("inTangent", toJson(*stop.inTangent));
    if (stop.outTangent) j.set("outTangent", toJson(*stop.outTangent));
    return j;
}

LightFalloffStop lightFalloffStopFromJson(const JsonValue& j) {
    LightFalloffStop stop;
    stop.position = floatOr(j, "position", 0.0f);
    stop.value = floatOr(j, "value", 0.0f);
    const JsonValue* in = j.find("inTangent");
    if (in != nullptr && !in->isNull()) stop.inTangent = vec2FromJson(*in);
    const JsonValue* out = j.find("outTangent");
    if (out != nullptr && !out->isNull()) stop.outTangent = vec2FromJson(*out);
    return stop;
}

JsonValue toJson(const SceneLight& light) {
    JsonValue j = JsonValue::makeObject();
    j.set("id", toJson(light.id));
    j.set("name", JsonValue::makeString(light.name));
    j.set("isEnabled", JsonValue::makeBool(light.isEnabled));
    j.set("kind", JsonValue::makeString(sceneLightKindName(light.kind)));
    j.set("position", toJson(light.position));
    j.set("positionZ", JsonValue::makeNumber(light.positionZ));
    j.set("azimuth", JsonValue::makeNumber(light.azimuth));
    j.set("elevation", JsonValue::makeNumber(light.elevation));
    j.set("radius", JsonValue::makeNumber(light.radius));
    j.set("intensity", JsonValue::makeNumber(light.intensity));
    j.set("color", toJson(light.color));

    JsonValue::Array stops;
    stops.reserve(light.falloff.stops().size());
    for (const LightFalloffStop& stop : light.falloff.stops()) stops.push_back(toJson(stop));
    j.set("falloff", JsonValue::makeArray(std::move(stops)));

    j.set("softness", JsonValue::makeNumber(light.softness));
    j.set("innerAngle", JsonValue::makeNumber(light.innerAngle));
    j.set("outerAngle", JsonValue::makeNumber(light.outerAngle));
    j.set("mask", JsonValue::makeNumber(light.mask.rawValue));
    j.set("blend", JsonValue::makeString(sceneLightBlendName(light.blend)));
    j.set("depthInfluence", JsonValue::makeNumber(light.depthInfluence));
    j.set("normalInfluence", JsonValue::makeNumber(light.normalInfluence));
    j.set("castsShadows", JsonValue::makeBool(light.castsShadows));
    return j;
}

SceneLight sceneLightFromJson(const JsonValue& j) {
    SceneLight light;
    const JsonValue* id = j.find("id");
    if (id != nullptr && !id->isNull()) light.id = uuidFromJson(*id);
    const JsonValue* name = j.find("name");
    if (name != nullptr && !name->isNull()) light.name = name->asString();
    light.isEnabled = boolOr(j, "isEnabled", true);

    // An unknown kind or blend falls back rather than failing the
    // document, and never comes from a cast -- the stored token is the
    // format, so a renamed C++ case must not rewrite a file.
    const JsonValue* kind = j.find("kind");
    if (kind != nullptr && kind->isString()) {
        light.kind = sceneLightKindFromName(kind->asString()).value_or(SceneLightKind::kPoint);
    }
    const JsonValue* blend = j.find("blend");
    if (blend != nullptr && blend->isString()) {
        light.blend = sceneLightBlendFromName(blend->asString()).value_or(SceneLightBlend::kNormal);
    }

    const JsonValue* position = j.find("position");
    if (position != nullptr && !position->isNull()) light.position = vec2FromJson(*position);
    light.positionZ = floatOr(j, "positionZ", light.positionZ);
    light.azimuth = floatOr(j, "azimuth", light.azimuth);
    light.elevation = floatOr(j, "elevation", light.elevation);

    // Every range enforced on the way IN, not only in the inspector: a
    // hand-edited or truncated file must not be able to make a light that
    // divides by a zero band or inverts its cone.
    light.radius = std::max(floatOr(j, "radius", light.radius), 0.0f);
    light.intensity = std::max(floatOr(j, "intensity", light.intensity), 0.0f);
    const JsonValue* color = j.find("color");
    if (color != nullptr && !color->isNull()) light.color = vec3FromJson(*color);

    const JsonValue* falloff = j.find("falloff");
    if (falloff != nullptr && falloff->isArray()) {
        std::vector<LightFalloffStop> stops;
        stops.reserve(falloff->asArray().size());
        for (const JsonValue& stop : falloff->asArray()) {
            stops.push_back(lightFalloffStopFromJson(stop));
        }
        // The curve's own constructor pins the ends at (0,1) and (1,0), so
        // a file whose last stop reads 0.2 does not draw a hard circle
        // around the lamp.
        light.falloff = LightFalloffCurve(std::move(stops));
    }

    light.softness = clampf(floatOr(j, "softness", light.softness), 0.0f, 1.0f);
    // The outer angle is clamped first and then bounds the inner one. A
    // cone whose inner exceeds its outer makes the smoothstep between them
    // run backwards, which reads as a spot lit inside out.
    const float outer = clampf(floatOr(j, "outerAngle", light.outerAngle), 0.0f, kPi);
    light.outerAngle = outer;
    light.innerAngle = clampf(floatOr(j, "innerAngle", light.innerAngle), 0.0f, outer);

    // An EMPTY mask would be a light that lights nothing, which is
    // indistinguishable from the file being wrong. All channels. (Note a
    // LAYER's empty mask restores to channel 1 instead -- the two are
    // answering different questions.)
    const std::uint8_t mask = static_cast<std::uint8_t>(intOr(j, "mask", 0xFF));
    light.mask = mask == 0 ? SceneLightMask::all() : SceneLightMask(mask);

    light.depthInfluence = clampf(floatOr(j, "depthInfluence", light.depthInfluence), 0.0f, 1.0f);
    light.normalInfluence = clampf(floatOr(j, "normalInfluence", light.normalInfluence), 0.0f, 1.0f);
    light.castsShadows = boolOr(j, "castsShadows", false);
    return light;
}

JsonValue toJson(const SceneAmbient& ambient) {
    JsonValue j = JsonValue::makeObject();
    j.set("color", toJson(ambient.color));
    j.set("intensity", JsonValue::makeNumber(ambient.intensity));
    return j;
}

SceneAmbient sceneAmbientFromJson(const JsonValue& j) {
    SceneAmbient ambient;
    const JsonValue* color = j.find("color");
    if (color != nullptr && !color->isNull()) ambient.color = vec3FromJson(*color);
    ambient.intensity = std::max(floatOr(j, "intensity", ambient.intensity), 0.0f);
    return ambient;
}

// ---- Material ----------------------------------------------------------

JsonValue toJson(const SceneMaterial& material) {
    JsonValue j = JsonValue::makeObject();
    if (material.normalMapAssetId) j.set("normalMapAssetID", toJson(*material.normalMapAssetId));
    j.set("normalStrength", JsonValue::makeNumber(material.normalStrength));
    j.set("smoothness", JsonValue::makeNumber(material.smoothness));
    j.set("contrast", JsonValue::makeNumber(material.contrast));
    j.set("shadowCastMask", JsonValue::makeNumber(material.shadowCastMask.rawValue));
    j.set("shadowedMask", JsonValue::makeNumber(material.shadowedMask.rawValue));
    j.set("parallaxMode", JsonValue::makeString(sceneParallaxModeName(material.parallaxMode)));
    if (material.heightMapAssetId) j.set("heightMapAssetID", toJson(*material.heightMapAssetId));
    j.set("parallaxDepth", JsonValue::makeNumber(material.parallaxDepth));
    j.set("parallaxQuality", JsonValue::makeNumber(material.parallaxQuality));
    j.set("heightInverted", JsonValue::makeBool(material.heightInverted));
    j.set("parallaxSelfShadow", JsonValue::makeBool(material.parallaxSelfShadow));
    j.set("parallaxOcclusionStrength",
          JsonValue::makeNumber(material.parallaxOcclusionStrength));
    return j;
}

SceneMaterial sceneMaterialFromJson(const JsonValue& j) {
    SceneMaterial material;
    material.normalMapAssetId = optionalUuid(j, "normalMapAssetID");
    material.normalStrength = floatOr(j, "normalStrength", 1.0f);
    material.smoothness = floatOr(j, "smoothness", 0.0f);
    material.contrast = floatOr(j, "contrast", 0.0f);
    material.shadowCastMask = SceneLightMask(static_cast<std::uint8_t>(intOr(j, "shadowCastMask", 0)));
    material.shadowedMask = SceneLightMask(static_cast<std::uint8_t>(intOr(j, "shadowedMask", 0)));

    // A MODE THIS BUILD DOES NOT KNOW FALLS BACK TO `Off`, not to a nearby
    // guess. A file written by a later build naming a march this one
    // cannot run has to draw the surface it drew before marches existed --
    // picking the closest mode would render the artist a scene they never
    // composed and then let them save it back.
    const JsonValue* mode = j.find("parallaxMode");
    material.parallaxMode = mode != nullptr && mode->isString()
                                ? sceneParallaxModeFromName(mode->asString())
                                      .value_or(SceneParallaxMode::Off)
                                : SceneParallaxMode::Off;

    material.heightMapAssetId = optionalUuid(j, "heightMapAssetID");
    material.parallaxDepth = floatOr(j, "parallaxDepth", 0.05f);
    material.parallaxQuality = floatOr(j, "parallaxQuality", 0.5f);
    material.heightInverted = boolOr(j, "heightInverted", false);
    material.parallaxSelfShadow = boolOr(j, "parallaxSelfShadow", false);
    material.parallaxOcclusionStrength = floatOr(j, "parallaxOcclusionStrength", 0.0f);
    // Sanitised on the way in, not merely on the way to the GPU -- see
    // `SceneMaterial.h`: a negative smoothness takes the SLOW path and
    // computes a wrap with a negative width, which reads as an inverted
    // light rather than as a bad number.
    return sanitized(material);
}

// ---- Layer -------------------------------------------------------------

JsonValue toJson(const SceneLayer& layer) {
    JsonValue j = JsonValue::makeObject();
    j.set("id", toJson(layer.id));
    j.set("name", JsonValue::makeString(layer.name));
    j.set("isHidden", JsonValue::makeBool(layer.isHidden));
    j.set("opacity", JsonValue::makeNumber(layer.opacity));
    j.set("position", toJson(layer.position));
    j.set("positionZ", JsonValue::makeNumber(layer.positionZ));
    j.set("rotation", JsonValue::makeNumber(layer.rotation));
    j.set("rotation3D", toJson(layer.rotation3D));
    j.set("scale", toJson(layer.scale));
    j.set("shear", toJson(layer.shear));
    j.set("lightMask", JsonValue::makeNumber(layer.lightMask.rawValue));
    j.set("receivesLight", JsonValue::makeBool(layer.receivesLight));
    j.set("sortingOrder", JsonValue::makeNumber(layer.sortingOrder));
    j.set("material", toJson(layer.material));
    j.set("kind", JsonValue::makeString(layerKindName(layer.content)));

    // Only the payload this kind needs is written.
    if (const SceneRigContent* rig = std::get_if<SceneRigContent>(&layer.content)) {
        j.set("clipID", toJson(rig->clipId));
        j.set("speed", JsonValue::makeNumber(rig->speed));
        j.set("startFrame", JsonValue::makeNumber(rig->startFrame));
        j.set("loops", JsonValue::makeBool(rig->loops));
    } else if (const ScenePlateContent* plate = std::get_if<ScenePlateContent>(&layer.content)) {
        j.set("assetID", toJson(plate->assetId));
    } else if (const SceneFillContent* fill = std::get_if<SceneFillContent>(&layer.content)) {
        j.set("fill", toJson(fill->fill));
    }
    return j;
}

std::optional<SceneLayer> sceneLayerFromJson(const JsonValue& j, int fallbackOrder) {
    const JsonValue* kindValue = j.find("kind");
    const std::string kind = kindValue != nullptr && kindValue->isString() ? kindValue->asString()
                                                                          : std::string();

    // The layer is DROPPED when the payload its kind needs is missing,
    // rather than restored as something it never was -- so a future layer
    // type does not brick an older editor, it just does not appear.
    SceneLayerContent content;
    if (kind == "rig") {
        const auto clipId = optionalUuid(j, "clipID");
        if (!clipId) return std::nullopt;
        content = SceneRigContent{*clipId, floatOr(j, "speed", 1.0f), intOr(j, "startFrame", 0),
                                  boolOr(j, "loops", true)};
    } else if (kind == "plate") {
        const auto assetId = optionalUuid(j, "assetID");
        if (!assetId) return std::nullopt;
        content = ScenePlateContent{*assetId};
    } else if (kind == "fill") {
        const JsonValue* fill = j.find("fill");
        if (fill == nullptr || fill->isNull()) return std::nullopt;
        content = SceneFillContent{sceneFillFromJson(*fill)};
    } else {
        // An unknown kind entirely -- a layer type a later build added.
        return std::nullopt;
    }

    SceneLayer layer;
    layer.content = content;
    const JsonValue* id = j.find("id");
    if (id != nullptr && !id->isNull()) layer.id = uuidFromJson(*id);
    const JsonValue* name = j.find("name");
    if (name != nullptr && !name->isNull()) layer.name = name->asString();
    layer.isHidden = boolOr(j, "isHidden", false);
    layer.opacity = clampf(floatOr(j, "opacity", 1.0f), 0.0f, 1.0f);

    const JsonValue* position = j.find("position");
    if (position != nullptr && !position->isNull()) layer.position = vec2FromJson(*position);
    layer.positionZ = floatOr(j, "positionZ", 0.0f);
    layer.rotation = floatOr(j, "rotation", 0.0f);
    const JsonValue* rotation3D = j.find("rotation3D");
    if (rotation3D != nullptr && !rotation3D->isNull()) layer.rotation3D = vec3FromJson(*rotation3D);
    const JsonValue* scale = j.find("scale");
    if (scale != nullptr && !scale->isNull()) layer.scale = vec2FromJson(*scale);
    // Optional so a project written before Scene layers could shear still
    // opens; a missing slant is no slant.
    const JsonValue* shear = j.find("shear");
    layer.shear = shear != nullptr && !shear->isNull() ? vec2FromJson(*shear) : Vec2::zero();

    // A missing `sortingOrder` restores the layer's INDEX IN THE FILE:
    // before layers had numbers the stacking WAS the array order, so the
    // index reproduces exactly the draw order it was saved with. Zero
    // would put every card on one layer and leave the tie-break to sort
    // them -- the same order by luck, and no longer so the moment anybody
    // touched one number.
    layer.sortingOrder = intOr(j, "sortingOrder", fallbackOrder);

    // A missing mask restores channel 1 and `receivesLight` true, which is
    // what makes a light added to an old scene later actually reach
    // anything. An explicitly EMPTY one restores to channel 1 as well --
    // a layer on no channel is a card no light can ever touch.
    const JsonValue* maskValue = j.find("lightMask");
    if (maskValue != nullptr && !maskValue->isNull()) {
        const std::uint8_t mask = static_cast<std::uint8_t>(maskValue->asInt());
        layer.lightMask = mask == 0 ? SceneLightMask::layer1() : SceneLightMask(mask);
    } else {
        layer.lightMask = SceneLightMask::layer1();
    }
    layer.receivesLight = boolOr(j, "receivesLight", true);

    // Nil restores the FLAT surface -- the one every project predating
    // materials was drawn with, and the one `isFlat` keeps off the
    // shader's material path entirely.
    const JsonValue* material = j.find("material");
    layer.material = material != nullptr && !material->isNull() ? sceneMaterialFromJson(*material)
                                                                : sceneMaterialFlat();
    return layer;
}

// ---- Composition -------------------------------------------------------

JsonValue toJson(const SceneComposition& composition) {
    JsonValue j = JsonValue::makeObject();
    j.set("id", toJson(composition.id));
    j.set("name", JsonValue::makeString(composition.name));

    JsonValue::Array layers;
    layers.reserve(composition.layers.size());
    for (const SceneLayer& layer : composition.layers) layers.push_back(toJson(layer));
    j.set("layers", JsonValue::makeArray(std::move(layers)));

    j.set("camera", toJson(composition.camera));

    // Optional in the file: a scene saved before lighting existed has
    // none, and restores with none, which is the identity case the
    // renderer skips outright.
    JsonValue::Array lights;
    lights.reserve(composition.lights.size());
    for (const SceneLight& light : composition.lights) lights.push_back(toJson(light));
    j.set("lights", JsonValue::makeArray(std::move(lights)));

    j.set("ambient", toJson(composition.ambient));
    j.set("background", toJson(composition.background));
    j.set("durationInFrames", JsonValue::makeNumber(composition.durationInFrames));
    j.set("fps", JsonValue::makeNumber(composition.fps));
    j.set("renderSize", toJson(composition.renderSize));
    return j;
}

SceneComposition sceneCompositionFromJson(const JsonValue& j) {
    SceneComposition composition;
    const JsonValue* id = j.find("id");
    if (id != nullptr && !id->isNull()) composition.id = uuidFromJson(*id);
    const JsonValue* name = j.find("name");
    if (name != nullptr && !name->isNull()) composition.name = name->asString();

    // Enumerated, so a layer written before layer numbers existed takes
    // its position in the file as its number and the scene restores in
    // exactly the order it was saved in.
    const JsonValue* layers = j.find("layers");
    if (layers != nullptr && layers->isArray()) {
        const JsonValue::Array& array = layers->asArray();
        for (std::size_t i = 0; i < array.size(); ++i) {
            if (auto layer = sceneLayerFromJson(array[i], static_cast<int>(i))) {
                composition.layers.push_back(std::move(*layer));
            }
        }
    }

    const JsonValue* camera = j.find("camera");
    if (camera != nullptr && !camera->isNull()) composition.camera = sceneCameraFromJson(*camera);

    const JsonValue* lights = j.find("lights");
    if (lights != nullptr && lights->isArray()) {
        for (const JsonValue& light : lights->asArray()) {
            composition.lights.push_back(sceneLightFromJson(light));
        }
    }

    const JsonValue* ambient = j.find("ambient");
    composition.ambient = ambient != nullptr && !ambient->isNull()
                              ? sceneAmbientFromJson(*ambient)
                              : SceneAmbient::neutral();

    const JsonValue* background = j.find("background");
    if (background != nullptr && !background->isNull()) {
        composition.background = sceneFillFromJson(*background);
    }

    // Floors that keep a corrupt file from producing a scene that cannot
    // be played or rendered: a zero-frame scene has no playhead and a
    // 16-pixel floor keeps the render target addressable.
    composition.durationInFrames = std::max(intOr(j, "durationInFrames", 90), 1);
    composition.fps = std::min(std::max(intOr(j, "fps", 30), 1), 240);
    const JsonValue* renderSize = j.find("renderSize");
    if (renderSize != nullptr && !renderSize->isNull()) {
        const Vec2 size = vec2FromJson(*renderSize);
        composition.renderSize = Vec2(std::max(size.x, 16.0f), std::max(size.y, 16.0f));
    }
    return composition;
}

// ---- The fly camera ----------------------------------------------------

JsonValue toJson(const SceneViewCamera& camera) {
    JsonValue j = JsonValue::makeObject();
    j.set("pivot", toJson(camera.pivot));
    j.set("distance", JsonValue::makeNumber(camera.distance));
    j.set("pitch", JsonValue::makeNumber(camera.pitch));
    j.set("yaw", JsonValue::makeNumber(camera.yaw));
    j.set("fieldOfView", JsonValue::makeNumber(camera.fieldOfView));
    return j;
}

SceneViewCamera sceneViewCameraFromJson(const JsonValue& j) {
    SceneViewCamera camera;
    const JsonValue* pivot = j.find("pivot");
    if (pivot != nullptr && !pivot->isNull()) camera.pivot = vec3FromJson(*pivot);
    // The same clamps the live camera enforces, applied on the way in: a
    // file must not be able to put the view somewhere the controls cannot
    // reach or leave.
    camera.distance = clampf(floatOr(j, "distance", camera.distance),
                             SceneViewCamera::kMinDistance, SceneViewCamera::kMaxDistance);
    camera.pitch = clampf(floatOr(j, "pitch", camera.pitch), -SceneViewCamera::kPitchLimit,
                          SceneViewCamera::kPitchLimit);
    camera.yaw = floatOr(j, "yaw", camera.yaw);
    camera.fieldOfView = clampf(floatOr(j, "fieldOfView", camera.fieldOfView), 1.0f, 170.0f);
    return camera;
}

} // namespace umeshcore
