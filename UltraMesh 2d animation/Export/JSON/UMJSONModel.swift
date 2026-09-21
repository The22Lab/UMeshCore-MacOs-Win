import Foundation

// MARK: - UltraMesh JSON Interchange Format
//
// This is the *official* engine-agnostic interchange format between the
// UltraMesh editor and any runtime (Unity, Unreal, Godot, custom C++, WASM…).
//
// Design rules (see ULTRAMESH_JSON_FORMAT.md for the full contract):
//   • Versioned. `format`/`version` gate compatibility; unknown keys are ignored
//     by conforming readers, so the format grows without breaking old files.
//   • Sectioned & flat. Each top-level section is an independent array or object
//     of self-describing records keyed by stable string IDs (UUIDs), never by
//     array index, so references survive reordering and future edits.
//   • Deterministic. The encoder emits sorted keys and the builder emits sorted
//     records, so exporting an unchanged project twice yields byte-identical JSON.
//   • Lossless. Every value the editor can author is represented. Angles are
//     stored in the editor's *internal* unit (documented per field) so a runtime
//     reproduces the rig with zero conversion drift.
//
// All `Codable` structs below map 1:1 to the JSON. Optionals are omitted when
// nil (Swift synthesises `encodeIfPresent`), keeping files compact and stable.

// MARK: Root

struct UMJSONDocument: Codable {
    var format: String            // always "UltraMesh"
    var version: String           // format semver, e.g. "1.0.0"
    var engineVersion: String     // editor build that produced the file
    var generator: String         // exporter name + version
    var exportDate: String        // ISO-8601, UTC
    var compatibility: UMJSONCompatibility
    var metadata: UMJSONMetadata

    var atlas: UMJSONAtlas
    var bones: [UMJSONBone]
    var slots: [UMJSONSlot]
    var attachments: [UMJSONAttachment]
    var meshes: [UMJSONMesh]
    var skins: [UMJSONSkin]
    var constraints: UMJSONConstraints
    var physics: [UMJSONPhysics]
    var events: [UMJSONEvent]
    var animations: [UMJSONAnimation]
}

struct UMJSONCompatibility: Codable {
    /// Minimum runtime semver able to load this file.
    var minRuntimeVersion: String
    /// Named capabilities a reader may probe. Absent capabilities must be
    /// treated as "not present", never as an error.
    var featureFlags: [String]
}

struct UMJSONMetadata: Codable {
    var projectName: String
    var framesPerSecond: Double
    var playbackStartFrame: Int
    var playbackEndFrame: Int
    /// Length unit the coordinates are expressed in. UltraMesh authors in pixels.
    var units: String
    /// Authored (setup) draw order: attachment IDs, back-to-front. The runtime
    /// draws in this order unless an animation's draw-order timeline overrides it.
    var drawOrder: [String]
    /// Free-form user data, preserved verbatim across round-trips.
    var custom: [String: String]
}

// MARK: Atlas / textures

struct UMJSONAtlas: Codable {
    var regions: [UMJSONAtlasRegion]
}

struct UMJSONAtlasRegion: Codable {
    var id: String
    var name: String
    var width: Float
    var height: Float
    /// When true, `dataBase64` carries the PNG bytes; otherwise load `path`
    /// relative to the exported file.
    var embedded: Bool
    var path: String?
    var dataBase64: String?
}

// MARK: Skeleton

/// A bone's decomposed 2D transform in the editor's internal units.
/// `rotation` and `shear` are RADIANS (bone convention). The optional
/// `depth` block preserves the rarely-used 3D components losslessly.
struct UMJSONTransform: Codable {
    var position: [Float]  // [x, y]
    var rotation: Float    // radians
    var scale: [Float]     // [x, y]
    var shear: [Float]     // [x, y] radians
    var depth: UMJSONTransformDepth?
}

struct UMJSONTransformDepth: Codable {
    var positionZ: Float
    var rotationX: Float   // radians
    var rotationY: Float   // radians
    var scaleZ: Float
}

struct UMJSONBone: Codable {
    var id: String
    var name: String
    var parent: String?
    var transform: UMJSONTransform  // setup (base) pose
    var length: Float
    /// Editor-only gizmo tint. Omitted entirely (not emitted as an empty array)
    /// when nonessential data is excluded, so a runtime never sees a malformed
    /// colour it might index into.
    var color: [Float]?             // [r, g, b, a]
    var root: Bool
}

// MARK: Slots & attachments

struct UMJSONSlot: Codable {
    var name: String
    /// Attachment IDs that can occupy this slot (skin variants).
    var attachments: [String]
}

/// A sprite/attachment. Every UltraMesh attachment is a mesh (a quad is a mesh
/// with four vertices), so `mesh` references its geometry in the `meshes` array.
struct UMJSONAttachment: Codable {
    var id: String
    var name: String
    var slot: String
    var region: String        // atlas region id (== assetId)
    var mesh: String?         // mesh id, if custom geometry
    var hidden: Bool
    /// Tint multiplied into the attachment, `[r,g,b,a]`. Omitted when neutral,
    /// so a rig that never uses tinting produces the same file as before.
    var color: [Float]?
    /// "normal" | "additive" | "multiply" | "screen". Omitted when normal.
    var blend: String?
    var animationSpace: String        // "world" | "boneLocal"
    var animationSpaceBone: String?   // bone id when boneLocal
    /// Setup pose used when the attachment is NOT bound to a bone.
    var setupPose: UMJSONAttachmentPose
    /// Present only when the attachment is parented to a bone.
    var boneBinding: UMJSONBoneBinding?
}

/// Sprite pose. `rotation` is RADIANS, `shear` is DEGREES (sprite convention).
struct UMJSONAttachmentPose: Codable {
    var position: [Float]
    var rotation: Float    // radians
    var scale: [Float]
    var shear: [Float]     // degrees
}

struct UMJSONBoneBinding: Codable {
    var bone: String
    var localPose: UMJSONAttachmentPose // rotation radians, shear degrees
}

// MARK: Meshes

struct UMJSONMeshWeight: Codable {
    var bone: String
    var weight: Float
}

struct UMJSONMesh: Codable {
    var id: String
    var name: String
    var vertices: [Float]        // flat [x0,y0, x1,y1, …]
    var uvs: [Float]             // flat [u0,v0, …] (v grows downward)
    var triangles: [Int]         // triangle list (indices)
    var hull: [Int]
    var edges: [Int]             // flat [a0,b0, a1,b1, …]
    var manualTriangles: [Int]   // flat [a0,b0,c0, …]
    /// Skinning (present only when the mesh is weighted).
    var bindVertices: [Float]?   // flat [x,y,…] rest pose
    var weights: [[UMJSONMeshWeight]]?    // per vertex
    var inverseBindMatrices: [UMJSONInverseBind]?
    /// Sprite world pose captured when the skin bind was made (rotation radians,
    /// shear degrees). Lets a runtime skin correctly under animation.
    var bindPose: UMJSONAttachmentPose?
}

struct UMJSONInverseBind: Codable {
    var bone: String
    /// Column-major 4x4, 16 floats.
    var matrix: [Float]
}

// MARK: Skins

struct UMJSONSkin: Codable {
    var id: String
    var name: String
    /// Explicit per-slot choices. A record with `attachment == nil` means the
    /// skin deliberately empties the slot; a slot absent from this array means
    /// the skin has no opinion and defers to `includes` then the setup pose.
    var slots: [UMJSONSkinSlot]
    var includes: [String]  // included skin ids, nearest-first
}

struct UMJSONSkinSlot: Codable {
    var slot: String
    var attachment: String?  // null == deliberately empty
}

// MARK: Constraints

struct UMJSONConstraints: Codable {
    var ik: [UMJSONIKConstraint]
    var transform: [UMJSONTransformConstraint]
    var path: [UMJSONPathConstraint]
}

struct UMJSONIKConstraint: Codable {
    var id: String
    var name: String
    var enabled: Bool
    var order: Int
    var mix: Float
    var bones: [String]        // chain, root → effector
    var target: String         // target bone id
    var bendPositive: Bool
    var stretch: Bool
    var compress: Bool
    var uniformScale: Bool
    var softness: Float
}

struct UMJSONTransformConstraint: Codable {
    var id: String
    var name: String
    var enabled: Bool
    var order: Int
    var mix: Float
    var target: String
    var bones: [String]
    var copyPosition: Bool
    var copyRotation: Bool
    var copyScale: Bool
    var copyShear: Bool
    var positionMix: Float
    var rotationMix: Float
    var scaleMix: Float
    var shearMix: Float
    var offsetPosition: [Float] // [x, y]
    var offsetRotation: Float   // radians
    var offsetScale: [Float]    // [x, y]
    var offsetShear: Float      // radians
}

struct UMJSONPathConstraint: Codable {
    var id: String
    var name: String
    var enabled: Bool
    var order: Int
    var mix: Float
    var pathBones: [String]
    var bones: [String]
    var position: Float
    var spacing: Float
    var spacingMode: String     // "length" | "percent" | "proportional" | "fixed"
    var positionMix: Float
    var rotateMix: Float
    var offsetRotation: Float    // radians
    var closed: Bool
    var reversed: Bool
    var rotateMode: String       // "tangent" | "chain" | "chainScale"
}

// MARK: Physics

struct UMJSONPhysicsSettings: Codable {
    var mass: Float
    var damping: Float
    var stiffness: Float
    var gravity: Float
    var drag: Float
    var wind: [Float]           // [x, y]
    var stretchLimit: Float
    var angleLimitMin: Float    // radians
    var angleLimitMax: Float    // radians
}

struct UMJSONPhysics: Codable {
    var id: String
    var name: String
    var enabled: Bool
    var order: Int
    var mix: Float
    var type: String            // spring | jiggle | rope | pendulum | cloth
    var bones: [String]
    var settings: UMJSONPhysicsSettings
}

// MARK: Events

struct UMJSONEvent: Codable {
    var id: String
    var name: String
    var int: Int
    var float: Float
    var string: String
    var audioPath: String
    var volume: Float
    var balance: Float
}

// MARK: Animations

struct UMJSONAnimation: Codable {
    var name: String
    var durationFrames: Int
    /// Per-bone transform timelines.
    var bones: [UMJSONBoneTimelines]
    /// Per-attachment (sprite) timelines.
    var attachments: [UMJSONAttachmentTimelines]
    /// Per-constraint property timelines.
    var constraints: [UMJSONConstraintTimelines]
    /// Scene-wide draw-order timeline (stepped).
    var drawOrder: [UMJSONDrawOrderKey]
    /// Per-event-definition keyframes.
    var events: [UMJSONEventTimeline]
}

struct UMJSONBoneTimelines: Codable {
    var bone: String
    var translate: [UMJSONKeyframe]?
    var rotate: [UMJSONKeyframe]?
    var scale: [UMJSONKeyframe]?
    var shear: [UMJSONKeyframe]?
}

struct UMJSONAttachmentTimelines: Codable {
    var attachment: String
    var translate: [UMJSONKeyframe]?
    var rotate: [UMJSONKeyframe]?
    var scale: [UMJSONKeyframe]?
    var shear: [UMJSONKeyframe]?
    /// Free-form mesh deformation (FFD). Absent unless the attachment's mesh
    /// is actually deformed by the animation.
    var deform: [UMJSONDeformKey]?
}

/// One mesh-deformation keyframe: the mesh's local vertex positions at a frame.
///
/// Positions are ABSOLUTE in the attachment's local space — the same space as
/// `UMJSONMesh.vertices` — not offsets from the rest shape. Storing them
/// outright costs more bytes than deltas but removes any question about which
/// rest pose a delta is relative to when skins swap the mesh underneath.
struct UMJSONDeformKey: Codable {
    var frame: Int
    /// "linear" or "stepped". Deformation ignores Bézier tangents, matching the
    /// editor, which interpolates vertex arrays linearly.
    var interp: String
    /// Flat [x0,y0, x1,y1, …], one pair per mesh vertex.
    var vertices: [Float]
}

struct UMJSONConstraintTimelines: Codable {
    var constraint: String
    /// property name (see ULTRAMESH_JSON_FORMAT.md) → keyframes.
    var properties: [UMJSONConstraintTrack]
}

struct UMJSONConstraintTrack: Codable {
    var property: String
    var keys: [UMJSONKeyframe]
}

struct UMJSONDrawOrderKey: Codable {
    var frame: Int
    /// Attachment IDs in draw order at this frame (stepped).
    var order: [String]
}

struct UMJSONEventTimeline: Codable {
    var event: String   // event definition id
    var keys: [UMJSONEventKey]
}

struct UMJSONEventKey: Codable {
    var frame: Int
    // Overrides; when absent, the definition's default applies.
    var int: Int?
    var float: Float?
    var string: String?
}

/// One keyframe. `value` carries exactly one of the payload fields depending on
/// the track: a scalar (rotate, constraint scalar), a vector `[x,y]`
/// (translate/scale/shear/physics-wind), or a flag. Bézier tangents are stored
/// as (frameDelta, valueDelta) offsets; secondary tangents drive the Y channel
/// of vector tracks.
struct UMJSONKeyframe: Codable {
    var frame: Int
    var interp: String            // "linear" | "stepped" | "bezier"
    var scalar: Float?
    var vector: [Float]?          // [x, y]
    var flag: Bool?
    var inTangent: [Float]?
    var outTangent: [Float]?
    var secondaryInTangent: [Float]?
    var secondaryOutTangent: [Float]?
}
