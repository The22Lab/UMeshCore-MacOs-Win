import Foundation
import simd

/// Invariants a mesh must satisfy, checked after every mutation.
///
/// The point is that a hole becomes impossible to *ship*, not merely unlikely to
/// be drawn. Before this type existed there was no coverage check anywhere in
/// the editor, which is why a triangle list covering 97.8 % of a silhouette went
/// straight through to the renderer, the project file and the exporters without
/// a single complaint. `sanitizedForRender` could not catch it either: its
/// rebuild only fires when `indices` is *completely* empty, so a
/// partially-covered list passes through untouched.
///
/// `.coverage` is the invariant that catches that specific defect. The others
/// catch the failure modes a triangulation can exhibit while still having the
/// right total area — a torn edge, a flipped triangle, a vertex that quietly
/// stopped being referenced.
///
/// Normative reference: `Meshing/pymesh/validate.py`.
enum MeshValidator {

    /// Invariant identifiers, kept stable so they can be quoted in a bug report.
    enum Invariant: String, Equatable {
        case indexBounds       = "I1"
        case degenerate        = "I2"
        case winding           = "I3"
        case manifold          = "I4"
        case boundaryMatchesRings = "I5"
        case coverage          = "I7"
        case orphanVertices    = "I8"
        case constraints       = "I9"
        case trianglesInHoles  = "I10"
        case indexCeiling      = "I11"
    }

    struct Report {
        private(set) var failures: [(Invariant, String)] = []
        private(set) var warnings: [(Invariant, String)] = []

        var isValid: Bool { failures.isEmpty }

        mutating func fail(_ invariant: Invariant, _ message: String) {
            failures.append((invariant, message))
        }

        mutating func warn(_ invariant: Invariant, _ message: String) {
            warnings.append((invariant, message))
        }

        /// One-line summary suitable for a log or an inspector tooltip.
        var summary: String {
            if isValid && warnings.isEmpty { return "valid" }
            var parts = failures.map { "\($0.0.rawValue): \($0.1)" }
            parts += warnings.map { "\($0.0.rawValue) (warning): \($0.1)" }
            return parts.joined(separator: "; ")
        }

        /// Short phrase for the health indicator next to the vertex count.
        var shortStatus: String {
            if isValid { return warnings.isEmpty ? "Watertight" : "Watertight, \(warnings.count) note(s)" }
            return "\(failures.count) problem(s)"
        }
    }

    /// Check every invariant against a triangle list.
    ///
    /// - Parameter coverageTolerance: relative area tolerance. The default is
    ///   tight on purpose: the pipeline is exact by construction, so anything
    ///   above rounding noise means real geometry went missing.
    static func validate(
        points: [SIMD2<Float>],
        triangles: [UInt16],
        outer: [Int],
        holes: [[Int]] = [],
        constraints: [(Int, Int)] = [],
        coverageTolerance: Double = 1e-6
    ) -> Report {
        var report = Report()
        let n = points.count

        // I1 — index bounds and triangle count.
        guard triangles.count % 3 == 0 else {
            report.fail(.indexBounds,
                        "triangle list length \(triangles.count) is not a multiple of 3")
            return report
        }
        for index in triangles where Int(index) >= n {
            report.fail(.indexBounds, "index \(index) out of range (0..\(n - 1))")
            return report
        }

        var tris: [(Int, Int, Int)] = []
        tris.reserveCapacity(triangles.count / 3)
        for t in stride(from: 0, to: triangles.count, by: 3) {
            tris.append((Int(triangles[t]), Int(triangles[t + 1]), Int(triangles[t + 2])))
        }

        // I2 — no degenerate triangles, and no repeated vertex within one.
        for (a, b, c) in tris {
            if Set([a, b, c]).count != 3 {
                report.fail(.degenerate, "triangle (\(a),\(b),\(c)) repeats a vertex")
            } else if MeshPredicates.orient2d(points[a], points[b], points[c]) == 0 {
                report.fail(.degenerate, "triangle (\(a),\(b),\(c)) has zero area")
            }
        }

        // I3 — consistent winding.
        var signs = Set<Int>()
        for (a, b, c) in tris {
            let o = MeshPredicates.orient2d(points[a], points[b], points[c])
            if o != 0 { signs.insert(o > 0 ? 1 : -1) }
        }
        if signs.count > 1 {
            report.fail(.winding, "triangles do not share a consistent winding")
        }

        // I4 — manifold: every undirected edge used once (boundary) or twice (interior).
        var edgeCount: [MeshEdge: Int] = [:]
        edgeCount.reserveCapacity(tris.count * 3)
        for (a, b, c) in tris {
            for (u, v) in [(a, b), (b, c), (c, a)] {
                edgeCount[MeshEdge(UInt16(u), UInt16(v)), default: 0] += 1
            }
        }
        let overused = edgeCount.filter { $0.value > 2 }
        if let first = overused.keys.sorted(by: edgeIsBefore).first {
            report.fail(.manifold,
                        "\(overused.count) edge(s) shared by more than 2 triangles, "
                        + "e.g. (\(first.a),\(first.b))")
        }

        // I5 — the boundary of the triangulation is exactly the ring set.
        let boundary = Set(edgeCount.filter { $0.value == 1 }.keys)
        var expected = Set<MeshEdge>()
        for ring in [outer] + holes where ring.count >= 2 {
            for i in ring.indices {
                expected.insert(MeshEdge(UInt16(ring[i]), UInt16(ring[(i + 1) % ring.count])))
            }
        }
        let missing = expected.subtracting(boundary)
        let extra = boundary.subtracting(expected)
        if let first = missing.sorted(by: edgeIsBefore).first {
            report.fail(.boundaryMatchesRings,
                        "\(missing.count) outline edge(s) are not on the mesh boundary, "
                        + "e.g. (\(first.a),\(first.b)) — this is a hole or a torn edge")
        }
        if let first = extra.sorted(by: edgeIsBefore).first {
            report.fail(.boundaryMatchesRings,
                        "\(extra.count) boundary edge(s) are not outline edges, "
                        + "e.g. (\(first.a),\(first.b)) — this is a gap inside the region")
        }

        // I7 — coverage. The invariant that would have caught the shipped bug.
        // Uses signedArea2, not orient2d: orient2d answers a yes/no question and
        // is free to report +/-1 rather than the determinant, so summing areas
        // with it would count a near-degenerate triangle as half a unit of area.
        var covered = 0.0
        for (a, b, c) in tris {
            covered += abs(MeshPredicates.signedArea2(points[a], points[b], points[c])) / 2.0
        }
        var target = MeshKernel.polygonArea(points: points, ring: outer)
        for hole in holes { target -= MeshKernel.polygonArea(points: points, ring: hole) }
        if target > 0 {
            let relative = abs(covered - target) / target
            if relative > coverageTolerance {
                let percent = 100.0 * covered / target
                report.fail(.coverage,
                            String(format: "coverage %.4f %% of the region (%.6f vs %.6f)",
                                   percent, covered, target))
            }
        }

        // I8 — no orphan outline vertices. Coverage cannot see this: a vertex
        // collinear with its neighbours contributes no area, so it can vanish
        // while the total still reads 100 %, taking its bone weights and every
        // deform keyframe that addressed it.
        let referenced = Set(triangles.map { Int($0) })
        var ringVertices = Set(outer)
        for hole in holes { ringVertices.formUnion(hole) }
        let orphans = ringVertices.subtracting(referenced)
        if let first = orphans.sorted().first {
            report.fail(.orphanVertices,
                        "\(orphans.count) outline vertex/vertices missing from the "
                        + "triangulation, e.g. \(first)")
        }

        // I9 — declared constraints are present as edges.
        for (a, b) in constraints {
            let key = MeshEdge(UInt16(a), UInt16(b))
            if edgeCount[key] == nil {
                report.fail(.constraints,
                            "constraint edge (\(key.a),\(key.b)) is absent from the triangulation")
            }
        }

        // I10 — no triangle centroid inside a hole.
        for hole in holes {
            for (a, b, c) in tris {
                let centroid = (points[a] + points[b] + points[c]) / 3
                if MeshKernel.pointInRing(points: points, ring: hole, centroid) {
                    report.fail(.trianglesInHoles, "triangle (\(a),\(b),\(c)) lies inside a hole")
                    break
                }
            }
        }

        // I11 — the UInt16 index ceiling the file format imposes.
        if n > Int(UInt16.max) {
            report.fail(.indexCeiling,
                        "\(n) vertices exceeds the UInt16 index limit of \(UInt16.max)")
        }

        return report
    }

    /// Fraction of the region actually covered. 1.0 is watertight.
    static func coverageRatio(
        points: [SIMD2<Float>], triangles: [UInt16], outer: [Int], holes: [[Int]] = []
    ) -> Double {
        var covered = 0.0
        for t in stride(from: 0, to: triangles.count, by: 3) {
            let a = Int(triangles[t]), b = Int(triangles[t + 1]), c = Int(triangles[t + 2])
            guard points.indices.contains(a), points.indices.contains(b),
                  points.indices.contains(c) else { continue }
            covered += abs(MeshPredicates.signedArea2(points[a], points[b], points[c])) / 2.0
        }
        var target = MeshKernel.polygonArea(points: points, ring: outer)
        for hole in holes { target -= MeshKernel.polygonArea(points: points, ring: hole) }
        return target > 0 ? covered / target : 0.0
    }

    private static func edgeIsBefore(_ lhs: MeshEdge, _ rhs: MeshEdge) -> Bool {
        lhs.a != rhs.a ? lhs.a < rhs.a : lhs.b < rhs.b
    }
}
