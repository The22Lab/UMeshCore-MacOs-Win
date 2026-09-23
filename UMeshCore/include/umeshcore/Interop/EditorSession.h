#pragma once

// Where the Mac shell keeps the core: ONE heap object, reached through a
// pointer.
//
// `EditorScene` is copyable, and heavy: it carries the undo history (up to
// 80 snapshots each way, every one a full copy of the model). Swift imports
// a copyable C++ struct as a Swift value type, and Swift copies values
// whenever it likes -- binding one to a `let`, and, in an unoptimized
// build, sometimes just to call a `const` method on it. A `SceneManager`
// holding `var core: umeshcore.EditorScene` could therefore duplicate the
// whole scene, history included, on an innocent-looking read.
//
// So the scene lives here, allocated by C++, and Swift holds the pointer
// (`UnsafeMutablePointer<EditorSession>`). Every access is
// `session.pointee.scene.<member>`: `pointee` is an addressor, so a member
// is reached IN PLACE and nothing is copied that the expression does not
// name. No Swift annotation is needed for this (`<swift/bridging>` does not
// exist on the Linux build that runs this port's tests, and an annotation
// only one compiler sees is a difference between the two builds).
//
// The Swift owner (`Bridge/CoreSession.swift`) calls `destroyEditorSession`
// from its `deinit`. Nothing else frees it.
//
// `ToolManager` is deliberately NOT here yet. It owns its tools through
// `unique_ptr`, so it is not copyable, and Swift imports it as a
// `~Copyable` type -- a separate interop question, answered when the tools
// move over, not bundled into the first thing the Mac has to compile.

#include "umeshcore/Editor/AssetAlphaStore.h"
#include "umeshcore/Editor/EditorScene.h"

namespace umeshcore {

struct EditorSession {
    EditorScene scene;
    // Filled by the shell as it decodes each sprite's artwork; read by
    // picking and Auto-Mesh. See `Editor/AssetAlphaStore.h`.
    AssetAlphaStore assets;
};

// A new, empty session. Never null.
EditorSession* makeEditorSession();
// Frees a session made by `makeEditorSession`. Null is ignored.
void destroyEditorSession(EditorSession* session);

} // namespace umeshcore
