import Foundation
import Metal
import simd

/// What an imported image IS, which decides how it is stored and where it is
/// offered.
///
/// A normal map is not artwork. It is a field of directions that happens to be
/// stored in a PNG, and treating it as one more sprite gets three things wrong
/// at once: it clutters every sprite and plate picker with images nobody can
/// place, it wastes atlas space on a texture the atlas cannot safely hold, and
/// it invites an artist to drop a lavender rectangle into their scene.
enum AssetRole: String, Codable {
    /// Artwork. Goes in the atlas, appears in every picker. The default, so
    /// every project that predates this enum restores exactly as it was.
    case albedo
    /// A tangent-space normal map. Sampled standalone, never atlased, offered
    /// only where a normal map is being chosen.
    case normal

    /// The suffixes that mark a file as a normal map, in SpriteKit's own
    /// convention.
    ///
    /// `_n` is what Xcode's asset catalogs and `SKTexture` have used for years,
    /// so it is the spelling an artist arriving from that world already has in
    /// their export presets. `_normal` is accepted because it is what most
    /// baking tools write by default.
    static let normalSuffixes = ["_n", "_normal"]

    /// The role a file's NAME claims, and the artwork name it pairs with.
    ///
    /// MATCHED AS A SUFFIX ON THE WHOLE STEM, not as a substring. `hero_n` is a
    /// normal map for `hero`; `hero_north` is a drawing of a compass and must
    /// stay one. Testing with `contains` gets that wrong, and gets it wrong
    /// silently -- the compass simply stops appearing in the sprite list.
    static func inferred(fromFileName stem: String) -> (role: AssetRole, pairedWith: String)? {
        let lowered = stem.lowercased()
        for suffix in normalSuffixes where lowered.hasSuffix(suffix) {
            let base = String(stem.dropLast(suffix.count))
            // A file called exactly "_n" pairs with nothing.
            guard !base.isEmpty else { return nil }
            return (.normal, base)
        }
        return nil
    }
}

struct TextureAsset: Identifiable {
    let id: UUID
    let name: String
    let fileURL: URL
    let texture: MTLTexture
    let size: SIMD2<Float>
    /// Defaulted, so every construction site that predates roles keeps
    /// compiling and keeps meaning what it meant.
    var role: AssetRole = .albedo
    var atlasPageIndex: Int?
    var atlasUVRect: SIMD4<Float>?

    /// True when this asset can be placed as a sprite or a plate.
    ///
    /// A normal map cannot: it has no atlas entry, so a card built from it
    /// would have no UV rect to sample through.
    var isPlaceable: Bool { role == .albedo }
}
