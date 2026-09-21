#if os(iOS)
import Foundation

/// Keeping the folder the artist picked.
///
/// A folder handed over by the iOS document picker is SECURITY-SCOPED: the URL
/// works while the app holds access to it and is useless afterwards. So a save
/// that happens a minute later, or after a relaunch, fails with a permission
/// error that has nothing on screen connecting it to the moment the folder was
/// chosen — the picker worked, the path is right there in the sheet, and
/// writing quietly does not.
///
/// A bookmark is what survives that. It is taken the moment the folder is
/// picked, stored, and resolved again when something needs to write.
///
/// iOS only. On macOS `NSOpenPanel` hands back a URL the app may simply use.
enum ProjectFolderAccess {

    private static let bookmarkKey = "umProjectFolderBookmark"

    /// Store the folder, and say whether it can actually be written to.
    ///
    /// The check is a real one — a temporary file created and removed inside
    /// it — because "the picker returned a URL" and "the app may write there"
    /// are different questions, and the second is the one the artist cares
    /// about. Answering it now is the difference between a message beside the
    /// button and a failure minutes later.
    @discardableResult
    static func remember(_ folder: URL) -> Bool {
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }

        let probe = folder.appendingPathComponent(".ultramesh-write-probe-\(UUID().uuidString)")
        do {
            try Data().write(to: probe, options: .atomic)
            try? FileManager.default.removeItem(at: probe)
        } catch {
            return false
        }

        guard let bookmark = try? folder.bookmarkData(
            options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        else { return false }
        UserDefaults.standard.set(bookmark, forKey: bookmarkKey)
        return true
    }

    /// The remembered folder, resolved, or nil when there is none or it has
    /// gone. A stale bookmark is dropped rather than returned: offering a
    /// folder that no longer exists is how a save fails on a path the artist
    /// last saw weeks ago.
    static func remembered() -> URL? {
        guard let bookmark = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark,
                                 options: [], relativeTo: nil,
                                 bookmarkDataIsStale: &isStale) else {
            UserDefaults.standard.removeObject(forKey: bookmarkKey)
            return nil
        }
        if isStale { remember(url) }
        return url
    }
}
#endif
