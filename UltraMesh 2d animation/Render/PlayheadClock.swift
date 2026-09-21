import Foundation
import Combine

/// Where the playhead is, to a fraction of a frame.
///
/// A whole object for one number, because of who is allowed to watch it. The
/// value was `@Published` on `SceneManager`; the timeline observes that manager,
/// so every playback tick invalidated the entire timeline — which rebuilds its
/// track tree, walking every bone and image and scanning their clips. The
/// timeline then copied the value into its own `@State`, invalidating itself a
/// second time. Sixty ticks a second on a twelve-object rig is on the order of
/// seven thousand clip scans a second, all to move a line a few points.
///
/// On its own, only the playhead view observes it, and a tick redraws a line.
@MainActor
final class PlayheadClock: ObservableObject {
    /// Fractional frames. Whole frames are what the model animates on; the
    /// fraction exists so the line moves every display tick rather than every
    /// clip frame — the difference between motion and a stutter.
    @Published var frame: Double = 0
}
