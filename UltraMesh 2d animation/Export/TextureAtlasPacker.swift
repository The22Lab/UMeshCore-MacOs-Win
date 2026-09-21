import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import simd

// MARK: - Options & results

struct AtlasPackOptions {
    /// Hard ceiling for a single atlas page. Pages beyond the first are created
    /// automatically when regions do not fit.
    var maxPageWidth: Int
    var maxPageHeight: Int
    /// Transparent pixels kept between regions, preventing bilinear filtering
    /// from bleeding a neighbour's colour across an edge.
    var padding: Int
    /// Round page dimensions up to the next power of two — required by some
    /// older GPUs and mipmapping paths.
    var powerOfTwo: Bool
    /// Trim fully transparent borders before packing, then record the offset so
    /// the runtime can restore the original placement.
    var stripWhitespace: Bool
    /// Base name for produced files: `name.atlas`, `name.png`, `name2.png`, …
    var name: String

    init(maxPageWidth: Int = 2048,
         maxPageHeight: Int = 2048,
         padding: Int = 2,
         powerOfTwo: Bool = true,
         stripWhitespace: Bool = true,
         name: String = "atlas") {
        self.maxPageWidth = maxPageWidth
        self.maxPageHeight = maxPageHeight
        self.padding = padding
        self.powerOfTwo = powerOfTwo
        self.stripWhitespace = stripWhitespace
        self.name = name
    }
}

struct AtlasPackResult {
    var pageURLs: [URL]
    var atlasFileURL: URL
    var regionCount: Int
    /// Fraction of atlas area occupied by regions, averaged over pages.
    var occupancy: Double
}

/// One image awaiting placement.
private struct AtlasInput {
    let id: UUID
    let name: String
    let image: CGImage
    /// Source rect inside `image` after whitespace stripping.
    let trimmed: CGRect
    /// Original untrimmed size, needed by the runtime to restore placement.
    let originalSize: CGSize
    /// Offset of `trimmed` within the original image (Y measured from bottom,
    /// matching the libGDX atlas convention).
    let offset: CGPoint
}

/// A placed region on a page.
private struct AtlasPlacement {
    let input: AtlasInput
    let page: Int
    let x: Int
    let y: Int
    let width: Int
    let height: Int
}

// MARK: - Packer

/// Packs a project's textures into atlas pages using the MaxRects algorithm
/// (Best Short Side Fit), the family every atlas packer of this kind uses.
///
/// Why MaxRects rather than a shelf packer: shelf packing wastes the vertical
/// gap above short sprites in a row, which is exactly the shape of a typical
/// 2D character rig (a few tall limbs, many small props). MaxRects tracks the
/// free space as a set of maximal rectangles, so those gaps stay usable and the
/// resulting pages are markedly denser.
@MainActor
enum TextureAtlasPacker {

    /// Packs every texture referenced by the scene and writes the pages plus the
    /// `.atlas` descriptor into `directory`.
    static func pack(scene: SceneManager,
                     assets: AssetManager,
                     to directory: URL,
                     options: AtlasPackOptions = AtlasPackOptions()) throws -> AtlasPackResult {

        let inputs = try gatherInputs(scene: scene, assets: assets, options: options)
        guard !inputs.isEmpty else { throw ExportError.noScene }

        let placements = placeRegions(inputs, options: options)
        guard !placements.isEmpty else { throw ExportError.textureReadFailed }

        let pageCount = (placements.map(\.page).max() ?? 0) + 1
        var pageURLs: [URL] = []
        var totalUsed = 0
        var totalArea = 0

        for page in 0..<pageCount {
            let pagePlacements = placements.filter { $0.page == page }
            guard !pagePlacements.isEmpty else { continue }

            let (pageWidth, pageHeight) = pageDimensions(for: pagePlacements, options: options)
            let url = pageURL(directory: directory, options: options, page: page)
            try writePage(pagePlacements, width: pageWidth, height: pageHeight, to: url)
            pageURLs.append(url)

            totalUsed += pagePlacements.reduce(0) { $0 + $1.width * $1.height }
            totalArea += pageWidth * pageHeight
        }

        let atlasURL = directory.appendingPathComponent("\(options.name).atlas")
        try writeAtlasDescriptor(placements, pageURLs: pageURLs,
                                 options: options, to: atlasURL)

        return AtlasPackResult(
            pageURLs: pageURLs,
            atlasFileURL: atlasURL,
            regionCount: placements.count,
            occupancy: totalArea > 0 ? Double(totalUsed) / Double(totalArea) : 0
        )
    }

    // MARK: Input gathering

    private static func gatherInputs(scene: SceneManager,
                                     assets: AssetManager,
                                     options: AtlasPackOptions) throws -> [AtlasInput] {
        // Distinct assets in a stable order, so packing an unchanged project
        // twice produces the same atlas.
        var seen = Set<UUID>()
        var ordered: [UUID] = []
        for image in scene.images where seen.insert(image.assetID).inserted {
            ordered.append(image.assetID)
        }

        var inputs: [AtlasInput] = []
        inputs.reserveCapacity(ordered.count)

        for assetID in ordered {
            guard let asset = assets.asset(for: assetID),
                  let cgImage = loadCGImage(for: asset) else { continue }

            let fullRect = CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height)
            let trimmed = options.stripWhitespace
                ? (opaqueBounds(of: cgImage) ?? fullRect)
                : fullRect

            // The libGDX atlas format measures the offset from the bottom-left
            // of the original image; CGImage rows run top-down, so flip Y here.
            let offsetY = CGFloat(cgImage.height) - trimmed.maxY
            inputs.append(AtlasInput(
                id: assetID,
                name: sanitizedRegionName(asset.name, fallback: assetID.uuidString),
                image: cgImage,
                trimmed: trimmed,
                originalSize: CGSize(width: cgImage.width, height: cgImage.height),
                offset: CGPoint(x: trimmed.minX, y: offsetY)
            ))
        }
        return inputs
    }

    private static func loadCGImage(for asset: TextureAsset) -> CGImage? {
        if let source = CGImageSourceCreateWithURL(asset.fileURL as CFURL, nil),
           let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            return image
        }
        return nil
    }

    /// Tight bounds of pixels with alpha > 0. Returns nil for a fully
    /// transparent image, which the caller treats as "do not trim".
    private static func opaqueBounds(of image: CGImage) -> CGRect? {
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return nil }

        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue

        // The CGContext keeps the pixel pointer alive for its whole lifetime, so
        // the buffer must stay valid for every use — drawing AND scanning. That
        // is why all of it happens inside `withUnsafeMutableBytes` rather than
        // passing `&pixels` to the initializer, which would dangle the moment
        // the initializer returned.
        let bounds: CGRect? = pixels.withUnsafeMutableBytes { raw -> CGRect? in
            guard let base = raw.baseAddress,
                  let ctx = CGContext(data: base, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                      space: colorSpace, bitmapInfo: info) else { return nil }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

            let bytes = base.assumingMemoryBound(to: UInt8.self)
            var minX = width, minY = height, maxX = -1, maxY = -1
            for y in 0..<height {
                let rowStart = y * bytesPerRow
                for x in 0..<width {
                    // Alpha is the 4th byte of each RGBA pixel.
                    if bytes[rowStart + x * 4 + 3] != 0 {
                        if x < minX { minX = x }
                        if x > maxX { maxX = x }
                        if y < minY { minY = y }
                        if y > maxY { maxY = y }
                    }
                }
            }
            guard maxX >= minX, maxY >= minY else { return nil }
            return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        }
        return bounds
    }

    private static func sanitizedRegionName(_ name: String, fallback: String) -> String {
        let base = (name as NSString).deletingPathExtension
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    // MARK: MaxRects placement

    private static func placeRegions(_ inputs: [AtlasInput],
                                     options: AtlasPackOptions) -> [AtlasPlacement] {
        // Largest area first: big pieces are hardest to place, so committing
        // them while the page is empty avoids fragmenting it.
        let sorted = inputs.sorted { lhs, rhs in
            let l = lhs.trimmed.width * lhs.trimmed.height
            let r = rhs.trimmed.width * rhs.trimmed.height
            if l != r { return l > r }
            return lhs.name < rhs.name   // stable tiebreak → deterministic atlas
        }

        var placements: [AtlasPlacement] = []
        var remaining = sorted
        var page = 0

        while !remaining.isEmpty {
            var freeRects = [CGRect(x: 0, y: 0,
                                    width: options.maxPageWidth,
                                    height: options.maxPageHeight)]
            var unplaced: [AtlasInput] = []

            for input in remaining {
                let w = Int(input.trimmed.width) + options.padding
                let h = Int(input.trimmed.height) + options.padding

                guard let choice = bestFreeRect(freeRects, width: w, height: h) else {
                    unplaced.append(input)
                    continue
                }
                let placed = CGRect(x: choice.origin.x, y: choice.origin.y,
                                    width: CGFloat(w), height: CGFloat(h))
                placements.append(AtlasPlacement(
                    input: input, page: page,
                    x: Int(placed.minX), y: Int(placed.minY),
                    width: Int(input.trimmed.width), height: Int(input.trimmed.height)))

                freeRects = split(freeRects, by: placed)
                freeRects = pruneContained(freeRects)
            }

            // A region larger than a whole page can never be placed; dropping it
            // is better than looping forever.
            if unplaced.count == remaining.count { break }
            remaining = unplaced
            page += 1
        }
        return placements
    }

    /// Best Short Side Fit: minimise the smaller leftover edge, which keeps the
    /// remaining free space as square as possible.
    private static func bestFreeRect(_ free: [CGRect], width: Int, height: Int) -> CGRect? {
        var best: CGRect?
        var bestShort = Int.max
        var bestLong = Int.max

        for rect in free {
            let leftoverW = Int(rect.width) - width
            let leftoverH = Int(rect.height) - height
            guard leftoverW >= 0, leftoverH >= 0 else { continue }
            let short = min(leftoverW, leftoverH)
            let long = max(leftoverW, leftoverH)
            if short < bestShort || (short == bestShort && long < bestLong) {
                bestShort = short
                bestLong = long
                best = rect
            }
        }
        return best
    }

    /// Splits every free rect that overlaps `used` into the maximal rectangles
    /// left around it — the core of MaxRects.
    private static func split(_ free: [CGRect], by used: CGRect) -> [CGRect] {
        var result: [CGRect] = []
        result.reserveCapacity(free.count + 4)

        for rect in free {
            guard rect.intersects(used) else {
                result.append(rect)
                continue
            }
            // Left slab
            if used.minX > rect.minX {
                result.append(CGRect(x: rect.minX, y: rect.minY,
                                     width: used.minX - rect.minX, height: rect.height))
            }
            // Right slab
            if used.maxX < rect.maxX {
                result.append(CGRect(x: used.maxX, y: rect.minY,
                                     width: rect.maxX - used.maxX, height: rect.height))
            }
            // Bottom slab
            if used.minY > rect.minY {
                result.append(CGRect(x: rect.minX, y: rect.minY,
                                     width: rect.width, height: used.minY - rect.minY))
            }
            // Top slab
            if used.maxY < rect.maxY {
                result.append(CGRect(x: rect.minX, y: used.maxY,
                                     width: rect.width, height: rect.maxY - used.maxY))
            }
        }
        return result.filter { $0.width > 0 && $0.height > 0 }
    }

    /// Drops free rects fully contained in another; without this the list grows
    /// without bound and placement slows to a crawl.
    private static func pruneContained(_ rects: [CGRect]) -> [CGRect] {
        var kept: [CGRect] = []
        for (i, rect) in rects.enumerated() {
            var contained = false
            for (j, other) in rects.enumerated() where i != j {
                if other.contains(rect) {
                    // Identical rects would swallow each other; keep the first.
                    if other == rect && j > i { continue }
                    contained = true
                    break
                }
            }
            if !contained { kept.append(rect) }
        }
        return kept
    }

    // MARK: Page rendering

    private static func pageDimensions(for placements: [AtlasPlacement],
                                       options: AtlasPackOptions) -> (Int, Int) {
        let usedWidth = placements.map { $0.x + $0.width + options.padding }.max() ?? 1
        let usedHeight = placements.map { $0.y + $0.height + options.padding }.max() ?? 1
        if options.powerOfTwo {
            return (nextPowerOfTwo(usedWidth), nextPowerOfTwo(usedHeight))
        }
        return (max(1, usedWidth), max(1, usedHeight))
    }

    private static func nextPowerOfTwo(_ value: Int) -> Int {
        guard value > 1 else { return 1 }
        var result = 1
        while result < value { result <<= 1 }
        return result
    }

    private static func pageURL(directory: URL, options: AtlasPackOptions, page: Int) -> URL {
        // libGDX convention: first page has no suffix, later pages are numbered.
        let suffix = page == 0 ? "" : "\(page + 1)"
        return directory.appendingPathComponent("\(options.name)\(suffix).png")
    }

    private static func writePage(_ placements: [AtlasPlacement],
                                  width: Int, height: Int, to url: URL) throws {
        let bytesPerRow = width * 4
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue

        guard let ctx = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                  space: colorSpace, bitmapInfo: info) else {
            throw ExportError.textureReadFailed
        }
        ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))
        // Nearest-neighbour: regions are blitted 1:1, so any filtering here would
        // only soften the very pixels the atlas must reproduce exactly.
        ctx.interpolationQuality = .none

        for placement in placements {
            guard let cropped = placement.input.image.cropping(to: placement.input.trimmed) else { continue }
            // CGContext is Y-up; atlas coordinates are Y-down from the top-left.
            let destY = height - placement.y - placement.height
            ctx.draw(cropped, in: CGRect(x: placement.x, y: destY,
                                         width: placement.width, height: placement.height))
        }

        guard let image = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(
                url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw ExportError.ioFailure(url, underlying: NSError(domain: "Atlas", code: -1))
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw ExportError.ioFailure(url, underlying: NSError(domain: "Atlas", code: -2))
        }
    }

    // MARK: Descriptor

    /// Writes the libGDX `.atlas` text format, which the common 2D runtimes
    /// and the Unity importer already understand.
    private static func writeAtlasDescriptor(_ placements: [AtlasPlacement],
                                             pageURLs: [URL],
                                             options: AtlasPackOptions,
                                             to url: URL) throws {
        var out = ""
        for (index, pageURL) in pageURLs.enumerated() {
            let pagePlacements = placements
                .filter { $0.page == index }
                .sorted { $0.input.name < $1.input.name }   // deterministic order
            guard !pagePlacements.isEmpty else { continue }

            let (w, h) = pageDimensions(for: pagePlacements, options: options)
            out += "\n"
            out += "\(pageURL.lastPathComponent)\n"
            out += "size: \(w),\(h)\n"
            out += "format: RGBA8888\n"
            out += "filter: Linear,Linear\n"
            out += "repeat: none\n"

            for placement in pagePlacements {
                let input = placement.input
                out += "\(input.name)\n"
                out += "  rotate: false\n"
                out += "  xy: \(placement.x), \(placement.y)\n"
                out += "  size: \(placement.width), \(placement.height)\n"
                out += "  orig: \(Int(input.originalSize.width)), \(Int(input.originalSize.height))\n"
                out += "  offset: \(Int(input.offset.x)), \(Int(input.offset.y))\n"
                out += "  index: -1\n"
            }
        }

        do {
            try out.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            throw ExportError.ioFailure(url, underlying: error)
        }
    }
}
