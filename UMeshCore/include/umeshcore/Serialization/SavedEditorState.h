#pragma once

// JSON conversions for the project manifest's remaining sections that are
// genuinely MODEL data: `SavedHierarchyItem` (the outliner tree the artist
// arranged) and `SavedCameraState` (the 2D viewport camera).
//
// Swift's `SavedEditorState` itself is deliberately NOT ported, and this is
// the reason rather than an oversight: it is a flat bag of `AppState` UI
// scalars -- timeline zoom, snap and onion-skin toggles, which track filter
// is selected, mesh soft-selection slider values, which keyframes are
// highlighted. That is platform-shell state, and this port's standing rule
// (see `AnimationTrackProperty.h`, `ToolManager.h`) is that UI chrome stays
// with the shell. It still survives a save: `ProjectDocument::unrecognized`
// carries the whole `editorState` object through untouched, so a Mac
// project edited via UMeshCore keeps its panel state.
//
// `SavedCameraState` stores `zoom`/`rotation` as `Double` while this port's
// `CameraState` uses `float`, matching the rest of its math. JSON numbers
// are doubles either way, so the file is unchanged; the value narrows on
// read, which costs nothing at the magnitudes a viewport camera holds.

#include "umeshcore/Editor/CameraState.h"
#include "umeshcore/Model/HierarchyItem.h"
#include "umeshcore/Serialization/Json.h"

namespace umeshcore {

const char* hierarchyItemTypeName(HierarchyItem::ItemType type);
// Unknown/absent falls back to Image, matching Swift's
// `HierarchyItem.ItemType(rawValue:) ?? .image`.
HierarchyItem::ItemType hierarchyItemTypeFromName(const std::string& name);

JsonValue toJson(const HierarchyItem& item);
HierarchyItem hierarchyItemFromJson(const JsonValue& j);

JsonValue toJson(const CameraState& camera);
CameraState cameraStateFromJson(const JsonValue& j);

} // namespace umeshcore
