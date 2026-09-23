#pragma once

// 1:1 port of the hierarchy panel's non-view logic, out of
// `HierarchyView.swift` (1087 L): `displayHierarchyIDs()` (which actually
// lives on `SceneManager`, `Data/SceneManager.swift:3868`, but belongs
// here -- it is pure value logic over the same three inputs this file
// already takes, not scene mutation), `boneLineage`, `boneDepth`,
// `isHiddenByCollapsedAncestor`, and the `display` tree builder itself.
//
// This is the third bite of the timeline/hierarchy SwiftUI debt (Risk #6),
// after `GraphViewport`/`TimelineGraphMath`. Same reason to take it now
// rather than later: it is real algorithm sitting inside a `View`, and a
// Windows outliner needs the identical tree without re-deriving it from a
// SwiftUI body it doesn't have.
//
// WHAT STAYS IN THE VIEW, deliberately: everything about HOW a row draws
// (`accentColor`, SF Symbol names, row height, the drag-and-drop delegate,
// rename text field focus, the alert for a pending delete), and the two
// `@State` sets this file takes as plain parameters
// (`collapsedBoneIDs`/`expandedSections`) -- those are what the artist
// last clicked, not project data, and stay owned by the view. This
// mirrors the split `GraphViewport.h` already made between "what the
// artist is looking at" (view state, injected) and "how a value becomes a
// pixel" (here).
//
// "INJECT WHAT'S NEEDED" (convention #2): every function takes
// `hierarchyItems`/`images`/`skeleton` directly rather than a
// `SceneManager`, the same split `EditorScene` already uses.
//
// ONE DELIBERATE ADDITION over the Swift source: `boneLineage`,
// `boneDepth` and `isHiddenByCollapsedAncestor` each walk a bone's parent
// chain with a plain `while let`, unbounded. `EditorScene::depthOf` -- the
// same walk, for a different caller -- already caps that walk at 64 hops
// as a guard against a corrupt or cyclic parent chain reaching the UI as
// an infinite loop instead of a wrong-looking tree. The same cap is
// applied here, for the same reason, matching that precedent rather than
// inventing a new one.

#include <optional>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <variant>
#include <vector>

#include "umeshcore/Core/Uuid.h"
#include "umeshcore/Model/HierarchyItem.h"
#include "umeshcore/Model/SceneImage.h"
#include "umeshcore/Model/Skeleton.h"

namespace umeshcore {

// The walk that finds where a project's whole rig sits in display order:
// bones depth-first from the roots (root order, then each root's own
// order among siblings), each bone immediately followed by the sprites
// bound to it (in THEIR authored order), then its children. Anything
// `hierarchyItems` holds that the walk never reaches -- an item whose
// parent bone does not exist, most commonly -- is appended afterwards in
// authored order, so a broken binding still shows the sprite rather than
// losing it from the panel.
//
// Ported from `SceneManager.displayHierarchyIDs()`
// (`Data/SceneManager.swift:3868`), not from anything already named
// "display" in the view -- it is scene-derived order, not row layout,
// which is why `EditorScene` or a future scene-load path may want it too.
std::vector<Uuid> displayHierarchyIDs(
    const std::vector<HierarchyItem>& hierarchyItems, const std::vector<SceneImage>& images,
    const Skeleton& skeleton);

// A bone's ancestors, ROOT FIRST -- the order a breadcrumb or an indent
// guide wants, not the order a parent-chain walk naturally produces.
std::vector<Uuid> hierarchyBoneLineage(const Skeleton& skeleton, Uuid boneID);

// How many bones separate this one from a root. A root bone is depth 0.
int hierarchyBoneDepth(const Skeleton& skeleton, Uuid boneID);

// True when some ancestor bone -- the item's own parent chain for a bone,
// or the chain above the bone a sprite is bound to -- is collapsed. An
// unbound sprite is never hidden this way; it has no bone chain to be
// hidden by.
bool isHierarchyItemHiddenByCollapsedAncestor(
    Uuid itemID, HierarchyItem::ItemType type, const Skeleton& skeleton,
    const std::vector<SceneImage>& images,
    const std::unordered_set<Uuid, UuidHash>& collapsedBoneIDs);

// The three virtual section headers the panel groups rows under. A typed
// enum rather than the Swift source's raw `"skeleton"`/`"images"`/
// `"constraints"` strings used as both a `Set<String>` key and a display
// title -- the identity and the label are different questions, and this
// boundary is new code, not a wire format, so nothing is served by
// stringing it.
enum class HierarchySection { Skeleton, Images, Constraints };

// What one row IS. A tagged union rather than a bare enum because two
// cases (`Mesh`, `Constraint`) carry the id of the thing the row
// represents -- `std::variant` of wrapper structs, the idiom
// `KeyframeValue`/`GizmoHandle`/`SceneLayerContent` already use in this
// port, so the cases stay distinguishable by identity and `std::visit`
// keeps its exhaustiveness on the C++ side.
struct HierarchyRowItem {
    HierarchyItem::ItemType type;
    bool operator==(const HierarchyRowItem&) const = default;
};
struct HierarchyRowMesh {
    // The sprite this mesh row belongs to -- not a separate id, matching
    // Swift's `.mesh(UUID)` case, which carries the IMAGE's id.
    Uuid imageID;
    bool operator==(const HierarchyRowMesh&) const = default;
};
struct HierarchyRowConstraint {
    Uuid constraintID;
    bool operator==(const HierarchyRowConstraint&) const = default;
};
struct HierarchyRowSection {
    HierarchySection section;
    bool operator==(const HierarchyRowSection&) const = default;
};

using HierarchyRowKind =
    std::variant<HierarchyRowItem, HierarchyRowMesh, HierarchyRowConstraint, HierarchyRowSection>;

// One row of the built tree.
struct HierarchyDisplayEntry {
    // Matches the Swift source's row identity strings exactly --
    // `"§skeleton"`/`"§images"`/`"§constraints"` for the section headers,
    // a UUID's string form for an item row, `"mesh-<uuid>"` for its mesh
    // child, `"ik-<uuid>"` for a constraint row -- because a shell may
    // reasonably use this as a stable row id the way SwiftUI's `ForEach`
    // already does, and inventing a different scheme here would be a
    // divergence with no reason behind it.
    std::string id;
    Uuid targetID;
    HierarchyRowKind kind;
    int depth = 0;
    // Which ancestor levels this row's tree-line should draw a
    // CONTINUING vertical through, because a later sibling still shares
    // that ancestor. Swift computes this and `showsDescendantContinuation`
    // together in one backward pass over all rows rather than two
    // separate forward scans per row -- seeing `entries.count` this way
    // once again -- and the port keeps that shape; see the .cpp.
    std::vector<int> continuingLevels;
    // True when a LATER row is this row's descendant, i.e. this row's own
    // tree-line should extend downward rather than stop here.
    bool showsDescendantContinuation = false;
};

// The whole built tree, plus the two answers a row asks about ITSELF
// rather than about its place in the list -- both were linear scans of
// the whole rig repeated once per row before this existed (an O(rows *
// items) rebuild on every canvas drag, since a drag publishes on every
// frame); built once here they are dictionary and set lookups.
struct HierarchyDisplay {
    std::vector<HierarchyDisplayEntry> entries;
    // A hierarchy item's id -> its index in the `hierarchyItems` this was
    // built from. What a drop target or an arrow-key walk needs to
    // reorder or to read `hierarchyItems[i]` without a second scan.
    std::unordered_map<Uuid, int, UuidHash> indexByID;
    // Every id that something -- a bone or a sprite -- is parented to.
    // What a row asks to decide whether it draws a disclosure triangle.
    std::unordered_set<Uuid, UuidHash> parentsWithChildren;
    std::unordered_map<HierarchySection, int> sectionCounts;
};

// Builds the tree the panel draws, for the sections currently expanded
// and with the bones currently collapsed. `expandedSections` and
// `collapsedBoneIDs` are `@State` in the Swift view -- the artist's last
// click, not project data -- and arrive here as plain parameters rather
// than living in this file, the same split `GraphViewport.h` makes
// between viewport state and pixel mapping.
HierarchyDisplay buildHierarchyDisplay(
    const std::vector<HierarchyItem>& hierarchyItems, const std::vector<SceneImage>& images,
    const Skeleton& skeleton,
    const std::unordered_set<Uuid, UuidHash>& collapsedBoneIDs,
    const std::unordered_set<HierarchySection>& expandedSections);

} // namespace umeshcore
