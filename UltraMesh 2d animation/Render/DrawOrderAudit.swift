import Foundation

/// Checks that what the editor viewport SUBMITTED matches the Draw Order.
///
/// The viewport's sprite pass used to bucket sprites by `(atlasPage, blendMode)`
/// and emit page-major, and to emit every instanced quad before every mesh. Both
/// discarded the draw order, and the visible result was that the last entries in
/// the Draw Order panel — the newest layers, on the newest atlas page, the most
/// likely to have been meshed — composited on top of everything.
///
/// The pass builds runs in draw order now, so the order is correct by
/// construction. This exists because "by construction" is a claim, and the
/// arithmetic that backs it — each run's `start` and `count` into two separate
/// buffers — is exactly where an off-by-one at the end of an array hides.
///
/// It prints the table the report asked for:
///
///     drawIndex -> object -> expected order -> actual render order
///
/// and then the thing that actually matters: whether the runs partition each
/// buffer contiguously, in increasing order, covering everything appended and
/// nothing twice.
///
/// Off unless asked for, like the frame statistics beside it:
///
///     ULTRAMESH_DRAW_ORDER_AUDIT=1     (scheme environment variable)
///     -ULTRAMESH_DRAW_ORDER_AUDIT      (launch argument)
///
/// Editor only. The export path and the runtime walk the draw order and draw as
/// they go; neither ever bucketed, and neither is touched by any of this.
enum DrawOrderAudit {

    static let isEnabled: Bool = {
        let environment = ProcessInfo.processInfo.environment
        return environment["ULTRAMESH_DRAW_ORDER_AUDIT"] == "1"
            || ProcessInfo.processInfo.arguments.contains("-ULTRAMESH_DRAW_ORDER_AUDIT")
    }()

    /// Reported once per second at most: this runs inside the frame.
    private static var lastReport: Date = .distantPast
    private static let reportInterval: TimeInterval = 1.0

    static func report(runs: [(kind: String, page: Int, blend: Int, start: Int, count: Int)],
                       submitted: [(run: Int, name: String)],
                       instanceCount: Int,
                       vertexCount: Int) {
        guard isEnabled else { return }
        let now = Date()
        guard now.timeIntervalSince(lastReport) >= reportInterval else { return }
        lastReport = now

        var out = ["── editor draw order audit ── \(submitted.count) sprites in \(runs.count) runs"]
        out.append("  expected  actual  object                run  kind  page blend   span")
        for (index, entry) in submitted.enumerated() {
            let run = runs.indices.contains(entry.run) ? runs[entry.run] : nil
            // Columns padded in Swift, not with a `%@` width flag: width on
            // `%@` is not dependable across format implementations, and a
            // table that misaligns is a table nobody reads.
            let describedRun = run.map { run in
                let kind = run.kind.padding(toLength: 5, withPad: " ", startingAt: 0)
                return String(format: "%4d  %@ %4d %5d   %d..<%d", entry.run, kind,
                              run.page, run.blend, run.start, run.start + run.count)
            } ?? "  (no run)"
            // `submitted` is built in the order the pass visited sprites, which
            // IS the draw order, so the index is both the expected position and
            // the actual one. They are printed separately anyway: the day they
            // differ is the day this file earns its place.
            let object = entry.name.padding(toLength: 20, withPad: " ", startingAt: 0)
            out.append(String(format: "  %6d  %6d     %@ %@",
                              index, index, object, describedRun))
        }

        // The part that is not tautological. Runs are drawn in array order, so
        // for each buffer the spans they claim must start at zero, butt exactly
        // against each other, and finish at the end of what was appended.
        for (label, kind, total) in [("instances", "quad", instanceCount),
                                     ("vertices", "mesh", vertexCount)] {
            var cursor = 0
            var broken: String?
            for (index, run) in runs.enumerated() where run.kind == kind {
                if run.start != cursor {
                    broken = "run \(index) starts at \(run.start), expected \(cursor)"
                    break
                }
                if run.count <= 0 {
                    broken = "run \(index) is empty"
                    break
                }
                cursor += run.count
            }
            if broken == nil, cursor != total {
                broken = "runs cover \(cursor) of \(total) \(label)"
            }
            out.append("  \(label): " + (broken ?? "\(cursor) covered contiguously, none twice"))
        }
        print(out.joined(separator: "\n"))
    }
}
