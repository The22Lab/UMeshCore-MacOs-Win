import Foundation

/// A named event the rig can raise from an animation.
///
/// Events: the definition lives on the skeleton and carries the
/// default payload, while individual keyframes on the timeline may override it.
/// Runtimes use these to trigger footstep sounds, spawn effects, or hand control
/// back to gameplay code at an exact frame.
struct AnimationEvent: Identifiable, Equatable {
    let id: UUID
    var name: String

    /// Default payload. A keyframe that does not override a field uses these,
    /// which is what lets an event be retimed without re-entering its data.
    var defaultInt: Int
    var defaultFloat: Float
    var defaultString: String

    /// Optional audio cue, for audio events. Stored as a path so a
    /// project stays portable; the editor does not play it back.
    var audioPath: String
    var volume: Float
    var balance: Float

    init(
        id: UUID = UUID(),
        name: String,
        defaultInt: Int = 0,
        defaultFloat: Float = 0,
        defaultString: String = "",
        audioPath: String = "",
        volume: Float = 1,
        balance: Float = 0
    ) {
        self.id = id
        self.name = name
        self.defaultInt = defaultInt
        self.defaultFloat = defaultFloat
        self.defaultString = defaultString
        self.audioPath = audioPath
        self.volume = volume
        self.balance = balance
    }
}

/// The payload carried by a single event keyframe.
///
/// Each field is optional so a keyframe can say "use the definition's default"
/// rather than being forced to duplicate it. Editing the default then updates
/// every keyframe that did not override it, which is the point of having
/// defaults at all.
struct AnimationEventPayload: Equatable {
    var intValue: Int?
    var floatValue: Float?
    var stringValue: String?

    static let inheritingDefaults = AnimationEventPayload()

    var overridesAnything: Bool {
        intValue != nil || floatValue != nil || stringValue != nil
    }

    /// Resolve against a definition, filling in whatever this payload leaves open.
    func resolved(against definition: AnimationEvent) -> (int: Int, float: Float, string: String) {
        (
            intValue ?? definition.defaultInt,
            floatValue ?? definition.defaultFloat,
            stringValue ?? definition.defaultString
        )
    }
}

/// An event that playback has crossed, reported to whoever is listening.
struct FiredAnimationEvent: Equatable {
    let eventID: UUID
    let name: String
    let frame: Int
    let intValue: Int
    let floatValue: Float
    let stringValue: String
}
