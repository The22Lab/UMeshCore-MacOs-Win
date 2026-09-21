import Foundation

/// What is selected in Scene. ONE value, for everything.
///
/// ## Why this is a type and not two optionals
///
/// It was two: `selectedLayerID`, a `@State` living in the workspace view, and
/// `selectedSceneLightID` on the manager. Nothing stopped both being set at
/// once, and nothing made either of them clear the other — so selecting a light
/// left the previous layer's gizmo on the canvas, and picking a card left the
/// light inspector open on a light nobody was looking at. Every place that
/// wanted to ask "what is selected" had to ask twice and decide which answer
/// won, and each of them decided differently.
///
/// A selection is one thing at a time. Saying that as a type is what makes the
/// inspector, the gizmo, the canvas and the layer list agree without any of
/// them coordinating.
///
/// Editor state: it is not saved with the scene and never reaches an export.
enum SceneSelection: Equatable {
    case none
    case layer(UUID)
    case light(UUID)

    var layerID: UUID? {
        if case let .layer(id) = self { return id }
        return nil
    }

    var lightID: UUID? {
        if case let .light(id) = self { return id }
        return nil
    }

    var isEmpty: Bool { self == .none }

    /// The id of whatever is selected, without saying which kind it is — for
    /// the handful of callers that only need to know whether THIS row is the
    /// selected one.
    var id: UUID? {
        switch self {
        case .none:            return nil
        case let .layer(id):   return id
        case let .light(id):   return id
        }
    }
}
