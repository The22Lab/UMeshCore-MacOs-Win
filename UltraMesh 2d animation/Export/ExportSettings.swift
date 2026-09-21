import Foundation
import simd

// MARK: - Export settings (persistable presets with Save/Load)

/// Which output the Export dialog produces. Grouped in the left-hand list the
/// way export dialogs conventionally are: Data formats first, then Image formats.
enum ExportKind: String, Codable, CaseIterable, Identifiable {
    // Data
    case json
    case binary
    // Image
    case png

    var id: String { rawValue }

    var title: String {
        switch self {
        case .json:   return "JSON"
        case .binary: return "Binary"
        case .png:    return "PNG"
        }
    }

    var isData: Bool { self != .png }

    /// Section header in the format list.
    var group: String { isData ? "Data" : "Image" }

    var defaultExtension: String {
        switch self {
        case .json:   return ".json"
        case .binary: return ".umesh"
        case .png:    return ".png"
        }
    }
}

/// Complete, serializable export configuration — what the Save/Load buttons
/// write to disk so a project's export setup travels with the team.
struct ExportSettings: Codable, Equatable {

    // Which panel
    var kind: ExportKind = .json

    // ── Shared ────────────────────────────────────────────────────────────
    /// Output folder (data formats) or output file's folder (image formats).
    var outputPath: String = ""
    /// File name without extension, used when composing the final URL.
    var fileName: String = ""
    var openAfterExport: Bool = false

    // ── JSON / Binary (Data) ──────────────────────────────────────────────
    var fileExtension: String = ".json"
    var prettyPrint: Bool = true
    /// Format version string surfaced in the file header.
    var formatVersion: String = "1.0"
    var nonessentialData: Bool = true
    var animationCleanUp: Bool = false
    var warnings: Bool = true
    /// Export every named animation. Off = only the active animation.
    var exportAll: Bool = false
    var embedTextures: Bool = true
    var floatPrecision: Int = 6
    var reproducible: Bool = false

    // ── Texture atlas packing ─────────────────────────────────────────────
    var packTextureAtlas: Bool = false
    var atlasMaxWidth: Int = 2048
    var atlasMaxHeight: Int = 2048
    var atlasPadding: Int = 2
    var atlasPowerOfTwo: Bool = true
    var atlasStripWhitespace: Bool = true

    // ── PNG crop ──────────────────────────────────────────────────────────
    var cropPadding: Int = 2

    // ── PNG (Image) ───────────────────────────────────────────────────────
    /// "Current pose" renders one frame; "Animation" renders a range.
    var pngExportType: PNGExportType = .animation
    var warmUp: Int = 1
    var renderBones: Bool = false
    var renderImages: Bool = true
    var renderOthers: Bool = false
    var renderSelection: Bool = false
    var renderTitles: Bool = false
    var smoothing: Int = 8
    var multisampleAA: Int = 0          // 0 = None, else 2/4/8/16
    var cropViewport: Bool = false
    var sizeMode: PNGSizeMode = .scale
    var scalePercent: Int = 100
    var pixelWidth: Int = 1024
    var pixelHeight: Int = 1024
    var useFrameRange: Bool = false
    var startFrame: Int = 0
    var endFrame: Int = 0
    var fps: Int = 30
    var transparentBackground: Bool = true
    var compression: Int = 6
    var bruteForce: Bool = false
    var reduceColors: Bool = false
    var filenamePrefix: String = "frame"

    enum PNGExportType: String, Codable, CaseIterable, Identifiable {
        case currentPose
        case animation
        var id: String { rawValue }
        var title: String { self == .currentPose ? "Current pose" : "Animation" }
    }

    // MARK: Defaults

    /// The "Defaults" button: restores every option of the *current* panel
    /// while preserving the chosen output location, so one click does not force
    /// the artist to re-pick the folder.
    mutating func restoreDefaults() {
        let keptPath = outputPath
        let keptName = fileName
        let keptKind = kind
        self = ExportSettings()
        kind = keptKind
        outputPath = keptPath
        fileName = keptName
        fileExtension = keptKind.defaultExtension
    }

    // MARK: Persistence (Save / Load preset)

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    static func decoded(from data: Data) throws -> ExportSettings {
        try JSONDecoder().decode(ExportSettings.self, from: data)
    }

    // MARK: Derived values

    /// Effective output pixel size for the PNG panel, honoring Scale vs Size.
    func resolvedPixelSize(viewportWidth: Int, viewportHeight: Int) -> (width: Int, height: Int) {
        switch sizeMode {
        case .fixed:
            return (max(1, pixelWidth), max(1, pixelHeight))
        case .scale:
            let factor = Double(max(1, scalePercent)) / 100.0
            return (max(1, Int((Double(viewportWidth) * factor).rounded())),
                    max(1, Int((Double(viewportHeight) * factor).rounded())))
        }
    }

    /// Camera zoom multiplier implied by Scale mode, so scaling up renders more
    /// detail rather than merely enlarging the same pixels.
    var zoomMultiplier: Float {
        sizeMode == .scale ? Float(max(1, scalePercent)) / 100.0 : 1.0
    }
}
