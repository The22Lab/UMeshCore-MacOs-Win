#include "umeshcore/Serialization/SavedEditorState.h"

#include "umeshcore/Serialization/SavedGeometry.h"

namespace umeshcore {

const char* hierarchyItemTypeName(HierarchyItem::ItemType type) {
    switch (type) {
        case HierarchyItem::ItemType::Image: return "image";
        case HierarchyItem::ItemType::Bone: return "bone";
        case HierarchyItem::ItemType::Mesh: return "mesh";
    }
    return "image";
}

HierarchyItem::ItemType hierarchyItemTypeFromName(const std::string& name) {
    if (name == "bone") return HierarchyItem::ItemType::Bone;
    if (name == "mesh") return HierarchyItem::ItemType::Mesh;
    return HierarchyItem::ItemType::Image; // matches Swift's `?? .image`.
}

JsonValue toJson(const HierarchyItem& item) {
    JsonValue j = JsonValue::makeObject();
    j.set("id", toJson(item.id));
    j.set("name", JsonValue::makeString(item.name));
    j.set("type", JsonValue::makeString(hierarchyItemTypeName(item.type)));
    j.set("isHidden", JsonValue::makeBool(item.isHidden));
    j.set("order", JsonValue::makeNumber(item.order));

    JsonValue::Array children;
    children.reserve(item.children.size());
    for (const HierarchyItem& child : item.children) children.push_back(toJson(child));
    j.set("children", JsonValue::makeArray(std::move(children)));

    return j;
}

HierarchyItem hierarchyItemFromJson(const JsonValue& j) {
    HierarchyItem item;
    item.id = uuidFromJson(*j.find("id"));
    item.name = j.find("name")->asString();
    const JsonValue* type = j.find("type");
    item.type = type != nullptr ? hierarchyItemTypeFromName(type->asString()) : HierarchyItem::ItemType::Image;
    const JsonValue* isHidden = j.find("isHidden");
    item.isHidden = isHidden != nullptr && isHidden->asBool();
    const JsonValue* order = j.find("order");
    item.order = order != nullptr ? order->asInt() : 0;

    const JsonValue* children = j.find("children");
    if (children != nullptr) {
        for (const JsonValue& child : children->asArray()) item.children.push_back(hierarchyItemFromJson(child));
    }
    return item;
}

JsonValue toJson(const CameraState& camera) {
    JsonValue j = JsonValue::makeObject();
    // `SavedPoint`: an {x, y} pair, like SavedSIMD2 but Double-valued.
    JsonValue origin = JsonValue::makeObject();
    origin.set("x", JsonValue::makeNumber(camera.origin.x));
    origin.set("y", JsonValue::makeNumber(camera.origin.y));
    j.set("origin", origin);
    j.set("zoom", JsonValue::makeNumber(camera.zoom));
    j.set("rotation", JsonValue::makeNumber(camera.rotation));
    return j;
}

CameraState cameraStateFromJson(const JsonValue& j) {
    CameraState camera;
    const JsonValue* origin = j.find("origin");
    if (origin != nullptr) camera.origin = vec2FromJson(*origin);
    const JsonValue* zoom = j.find("zoom");
    if (zoom != nullptr) camera.zoom = zoom->asFloat();
    const JsonValue* rotation = j.find("rotation");
    if (rotation != nullptr) camera.rotation = rotation->asFloat();
    return camera;
}

} // namespace umeshcore
