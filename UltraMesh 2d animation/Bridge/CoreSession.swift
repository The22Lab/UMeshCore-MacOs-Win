import Foundation
import UMeshCore

/// The Mac shell's handle on UMeshCore: one `umeshcore::EditorSession` (the
/// scene, and the alpha store picking reads), allocated by C++ and owned
/// here.
///
/// WHY A POINTER AND NOT A STORED `umeshcore.EditorScene`. The scene is a
/// copyable C++ struct, and it is heavy: it carries the undo history, up to
/// 80 full snapshots each way. Swift imports a copyable C++ struct as a
/// value type and copies values when it likes -- a `let` binding, and in a
/// debug build sometimes just a call to a `const` method. A stored scene
/// could duplicate itself, history and all, on a read that looks free.
///
/// Through the pointer it cannot: `session.pointee.scene.images` reaches
/// the field in place (`pointee` is an addressor), and copies only the
/// field the expression names.
///
/// One owner, one scene. `SceneManager` will hold the only instance; this
/// class is `final` and not `Sendable` because the scene is not safe to
/// touch from two threads, and nothing in the core pretends otherwise.
final class CoreSession {
    let session: UnsafeMutablePointer<umeshcore.EditorSession>

    init() {
        // `makeEditorSession` never returns null; a nil here would mean the
        // C++ allocation itself failed, and there is no editor without it.
        guard let made = umeshcore.makeEditorSession() else {
            fatalError("UMeshCore could not allocate an editor session")
        }
        session = made
    }

    deinit {
        umeshcore.destroyEditorSession(session)
    }
}
