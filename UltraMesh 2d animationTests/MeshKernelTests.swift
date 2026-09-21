import XCTest
import simd
@testable import UltraMesh_2d_animation

/// The Swift side of the meshing verification.
///
/// These are the same shapes, the same properties and the same expected numbers
/// as `Meshing/verify_kernel.py` and `Meshing/verify_regression_holes.py`, which
/// are the normative reference for `MeshKernel` and `MeshValidator`. The Python
/// harness is where the algorithm was developed and proved; this file is what
/// confirms the Swift transcription of it behaves identically.
///
/// If one of these fails and the Python equivalent passes, the bug is in the
/// transcription, not in the algorithm — compare the two side by side.
final class MeshKernelTests: XCTestCase {

    // MARK: - Corpus

    private func p(_ x: Float, _ y: Float) -> SIMD2<Float> { SIMD2<Float>(x, y) }

    private func square() -> ([SIMD2<Float>], [Int], [[Int]], Double) {
        ([p(0, 0), p(100, 0), p(100, 100), p(0, 100)], [0, 1, 2, 3], [], 10000)
    }

    private func shapeL() -> ([SIMD2<Float>], [Int], [[Int]], Double) {
        ([p(0, 0), p(120, 0), p(120, 40), p(40, 40), p(40, 120), p(0, 120)],
         [0, 1, 2, 3, 4, 5], [], 8000)
    }

    private func shapeC() -> ([SIMD2<Float>], [Int], [[Int]], Double) {
        ([p(0, 0), p(120, 0), p(120, 30), p(30, 30),
          p(30, 90), p(120, 90), p(120, 120), p(0, 120)],
         [0, 1, 2, 3, 4, 5, 6, 7], [], 9000)
    }

    private func shapeU() -> ([SIMD2<Float>], [Int], [[Int]], Double) {
        ([p(0, 0), p(40, 0), p(40, 90), p(80, 90),
          p(80, 0), p(120, 0), p(120, 120), p(0, 120)],
         [0, 1, 2, 3, 4, 5, 6, 7], [], 10800)
    }

    /// The silhouette from the screen recording where deleting a node opened a
    /// wedge of missing geometry.
    private func bone() -> ([SIMD2<Float>], [Int], [[Int]], Double) {
        ([p(-55, 60), p(-18, 40), p(-18, -40), p(-55, -60),
          p(-55, -150), p(55, -150), p(55, -60), p(18, -40),
          p(18, 40), p(55, 60), p(55, 150), p(-55, 150)],
         // Two 110x90 lobes, a 36x80 waist, and the two trapezoids flaring from
         // the waist out to each lobe: 19800 + 2880 + 2920.
         Array(0..<12), [], 25600)
    }

    /// Worst case measured for the old algorithm: 57.08 % coverage, 42.92 % of
    /// the silhouette simply missing. Transcribed vertex for vertex from
    /// `Meshing/pymesh/shapes.py` so both harnesses test the same polygon.
    private func comb() -> ([SIMD2<Float>], [Int], [[Int]], Double) {
        let pts: [SIMD2<Float>] = [
            p(0, 0), p(12, 0), p(12, 100), p(24, 100), p(24, 0),
            p(36, 0), p(36, 100), p(48, 100), p(48, 0),
            p(60, 0), p(60, 100), p(72, 100), p(72, 0),
            p(84, 0), p(84, 100), p(96, 100), p(96, 0),
            p(108, 0), p(108, 100), p(120, 100), p(120, 0),
            p(120, -25), p(0, -25)
        ]
        return (pts, Array(0..<pts.count), [], 9000)
    }

    /// Every boundary vertex collinear with its neighbours — the configuration
    /// that RDP simplification produces and that used to orphan vertices.
    private func collinearHeavy() -> ([SIMD2<Float>], [Int], [[Int]], Double) {
        var pts: [SIMD2<Float>] = []
        for i in 0..<10 { pts.append(p(Float(i) * 10, 0)) }
        for i in 0..<10 { pts.append(p(100, Float(i) * 10)) }
        for i in 0..<10 { pts.append(p(100 - Float(i) * 10, 100)) }
        for i in 0..<10 { pts.append(p(0, 100 - Float(i) * 10)) }
        return (pts, Array(0..<40), [], 10000)
    }

    private func plateWithThreeHoles() -> ([SIMD2<Float>], [Int], [[Int]], Double) {
        let pts: [SIMD2<Float>] = [
            p(0, 0), p(200, 0), p(200, 200), p(0, 200),
            p(30, 30), p(30, 70), p(70, 70), p(70, 30),
            p(130, 30), p(130, 70), p(170, 70), p(170, 30),
            p(80, 130), p(80, 170), p(120, 170), p(120, 130)
        ]
        return (pts, [0, 1, 2, 3], [[4, 5, 6, 7], [8, 9, 10, 11], [12, 13, 14, 15]], 35200)
    }

    private var boundaryOnlyCorpus: [(String, ([SIMD2<Float>], [Int], [[Int]], Double))] {
        [("square", square()), ("L", shapeL()), ("C", shapeC()), ("U", shapeU()),
         ("bone", bone()), ("comb", comb()), ("collinear-heavy", collinearHeavy())]
    }

    // MARK: - Helpers

    /// Deterministic interior points: rejection sampling from a fixed sequence,
    /// so a failure is always reproducible.
    private func interiorPoints(
        into points: inout [SIMD2<Float>], outer: [Int], holes: [[Int]], count: Int, seed: UInt64 = 12345
    ) -> [Int] {
        var state = seed
        func next() -> Double {
            // xorshift64*, so this does not depend on the platform's RNG and a
            // failure is reproducible from the seed alone.
            state ^= state >> 12
            state ^= state << 25
            state ^= state >> 27
            // The parentheses matter: `>>` binds tighter than `&*` in Swift, so
            // without them this would shift the multiplier, not the product.
            let scrambled = (state &* 2685821657736338717) >> 11
            return Double(scrambled) / Double(UInt64(1) << 53)
        }

        var minX = Float.greatestFiniteMagnitude, maxX = -Float.greatestFiniteMagnitude
        var minY = Float.greatestFiniteMagnitude, maxY = -Float.greatestFiniteMagnitude
        for i in outer {
            minX = min(minX, points[i].x); maxX = max(maxX, points[i].x)
            minY = min(minY, points[i].y); maxY = max(maxY, points[i].y)
        }

        var added: [Int] = []
        var attempts = 0
        while added.count < count && attempts < count * 400 {
            attempts += 1
            let candidate = SIMD2<Float>(
                minX + Float(next()) * (maxX - minX),
                minY + Float(next()) * (maxY - minY)
            )
            guard MeshKernel.pointInRing(points: points, ring: outer, candidate) else { continue }
            var insideHole = false
            for hole in holes where MeshKernel.pointInRing(points: points, ring: hole, candidate) {
                insideHole = true
            }
            if insideHole { continue }
            // Keep clear of existing points so no insertion is degenerate.
            if points.contains(where: {
                abs($0.x - candidate.x) < 0.5 && abs($0.y - candidate.y) < 0.5
            }) { continue }
            points.append(candidate)
            added.append(points.count - 1)
        }
        return added
    }

    // MARK: - Coverage, the invariant that catches the reported bug

    func testEveryShapeIsWatertightBoundaryOnly() throws {
        for (name, shape) in boundaryOnlyCorpus {
            let (points, outer, holes, expectedArea) = shape
            let tris = try MeshKernel.triangulate(
                points: points, boundary: .init(outer: outer, holes: holes))
            let report = MeshValidator.validate(
                points: points, triangles: tris, outer: outer, holes: holes)
            XCTAssertTrue(report.isValid, "\(name): \(report.summary)")

            let ratio = MeshValidator.coverageRatio(
                points: points, triangles: tris, outer: outer, holes: holes)
            XCTAssertEqual(ratio, 1.0, accuracy: 1e-9, "\(name) coverage")

            if expectedArea > 0 {
                // Sum the triangle areas and compare to the hand-written
                // constant with nothing kernel-derived in between. Writing this
                // as `ratio * expectedArea` would be circular — ratio is
                // measured-over-shoelace, so expectedArea cancels and the check
                // silently becomes the coverage check a second time.
                var covered = 0.0
                for t in stride(from: 0, to: tris.count, by: 3) {
                    covered += abs(MeshPredicates.signedArea2(
                        points[Int(tris[t])], points[Int(tris[t + 1])],
                        points[Int(tris[t + 2])])) / 2.0
                }
                XCTAssertEqual(covered, expectedArea, accuracy: expectedArea * 1e-9,
                               "\(name) area")
            }
        }
    }

    func testEveryShapeIsWatertightWithInteriorPoints() throws {
        // This is the configuration in the recording: interior vertices present.
        // The old algorithm lost between 2.2 % and 42.9 % of the silhouette here
        // while covering it completely with boundary points only, which is why
        // the bug looked intermittent.
        for (name, shape) in boundaryOnlyCorpus {
            let (basePoints, outer, holes, _) = shape
            var points = basePoints
            let interior = interiorPoints(
                into: &points, outer: outer, holes: holes, count: 40)
            XCTAssertGreaterThan(interior.count, 20, "\(name): interior fill failed")

            let tris = try MeshKernel.triangulate(
                points: points, boundary: .init(outer: outer, holes: holes), interior: interior)
            let report = MeshValidator.validate(
                points: points, triangles: tris, outer: outer, holes: holes)
            XCTAssertTrue(report.isValid, "\(name) + interior: \(report.summary)")
            XCTAssertEqual(
                MeshValidator.coverageRatio(
                    points: points, triangles: tris, outer: outer, holes: holes),
                1.0, accuracy: 1e-9, "\(name) + interior coverage")
        }
    }

    func testHolesAreExcludedAndTheRestIsCovered() throws {
        let (basePoints, outer, holes, expectedArea) = plateWithThreeHoles()
        var points = basePoints
        let tris = try MeshKernel.triangulate(
            points: points, boundary: .init(outer: outer, holes: holes))
        let report = MeshValidator.validate(
            points: points, triangles: tris, outer: outer, holes: holes)
        XCTAssertTrue(report.isValid, report.summary)

        XCTAssertEqual(
            MeshValidator.coverageRatio(
                points: points, triangles: tris, outer: outer, holes: holes),
            1.0, accuracy: 1e-9)

        // Summed triangle area against the closed form: 200x200 minus three
        // 40x40 holes. Nothing kernel-derived in between.
        var covered = 0.0
        for t in stride(from: 0, to: tris.count, by: 3) {
            covered += abs(MeshPredicates.signedArea2(
                points[Int(tris[t])], points[Int(tris[t + 1])],
                points[Int(tris[t + 2])])) / 2.0
        }
        XCTAssertEqual(covered, expectedArea, accuracy: expectedArea * 1e-9,
                       "the three holes must be excluded from the covered area")

        // And with interior points as well.
        let interior = interiorPoints(into: &points, outer: outer, holes: holes, count: 30)
        let tris2 = try MeshKernel.triangulate(
            points: points, boundary: .init(outer: outer, holes: holes), interior: interior)
        XCTAssertTrue(
            MeshValidator.validate(points: points, triangles: tris2,
                                   outer: outer, holes: holes).isValid)
    }

    // MARK: - The reported symptom: deleting a vertex

    func testDeletingAnInteriorVertexStaysWatertight() throws {
        let (basePoints, outer, holes, _) = bone()
        var points = basePoints
        let interior = interiorPoints(into: &points, outer: outer, holes: holes, count: 40)
        XCTAssertGreaterThan(interior.count, 20)

        // Mirror of Mesh.removingVertices: compact the point list, remap, retriangulate.
        let victim = interior[interior.count / 2]
        var remap: [Int: Int] = [:]
        var kept: [SIMD2<Float>] = []
        for i in points.indices where i != victim {
            remap[i] = kept.count
            kept.append(points[i])
        }
        let newOuter = outer.compactMap { remap[$0] }
        let newInterior = interior.filter { $0 != victim }.compactMap { remap[$0] }

        let tris = try MeshKernel.triangulate(
            points: kept, boundary: .init(outer: newOuter), interior: newInterior)
        let report = MeshValidator.validate(points: kept, triangles: tris, outer: newOuter)
        XCTAssertTrue(report.isValid, report.summary)
        XCTAssertEqual(
            MeshValidator.coverageRatio(points: kept, triangles: tris, outer: newOuter),
            1.0, accuracy: 1e-9,
            "deleting a vertex must not open a hole — this is the reported bug")
    }

    // MARK: - Degenerate input is refused, not silently mangled

    func testFoldedOutlineIsRejected() {
        // Reduced from seed 156 of the Python edit fuzz. Vertices 0, 2 and 3 are
        // collinear, so edge (2,3) lies on top of edge (3,0): the outline doubles
        // back on itself and vertex 3 bounds no area. Nothing crosses
        // transversally, so a proper-intersection test calls this simple — and
        // every triangulation of it silently loses vertex 3 along with its bone
        // weights and deform keyframes.
        let points = [p(120, 0), p(30, 30), p(30, 90), p(0, 120)]
        XCTAssertThrowsError(
            try MeshKernel.triangulate(points: points, boundary: .init(outer: [0, 1, 2, 3]))
        ) { error in
            XCTAssertEqual(error as? MeshKernel.Failure, .ringFoldsBack)
        }

        // The half that proves the test is not vacuous: the weaker predicate
        // this replaced accepts the same ring.
        var anyProperCrossing = false
        let ring = [0, 1, 2, 3]
        for i in 0..<4 {
            for j in (i + 1)..<4 where !(j == i + 1 || (i == 0 && j == 3)) {
                if MeshPredicates.segmentsProperlyIntersect(
                    points[ring[i]], points[ring[(i + 1) % 4]],
                    points[ring[j]], points[ring[(j + 1) % 4]]) {
                    anyProperCrossing = true
                }
            }
        }
        XCTAssertFalse(anyProperCrossing,
                       "the proper-crossing test alone would have let this through")
    }

    func testSelfIntersectingOutlineIsRejected() {
        let points = [p(0, 0), p(10, 10), p(10, 0), p(0, 10)]
        XCTAssertThrowsError(
            try MeshKernel.triangulate(points: points, boundary: .init(outer: [0, 1, 2, 3])))
    }

    func testTooFewPointsIsRejected() {
        XCTAssertThrowsError(
            try MeshKernel.triangulate(points: [p(0, 0), p(1, 1)], boundary: .init(outer: [0, 1])))
    }

    func testCollinearButStraightVertexIsAccepted() throws {
        // A point sitting straight on an edge (180°, not folded back) is legal
        // and must survive; the strict ring test must not overreach.
        let points = [p(0, 0), p(50, 0), p(100, 0), p(100, 100), p(0, 100)]
        let ring = [0, 1, 2, 3, 4]
        let tris = try MeshKernel.triangulate(points: points, boundary: .init(outer: ring))
        let used = Set(tris.map { Int($0) })
        for v in ring {
            XCTAssertTrue(used.contains(v), "vertex \(v) was dropped")
        }
        XCTAssertTrue(MeshValidator.validate(points: points, triangles: tris, outer: ring).isValid)
    }

    // MARK: - Properties the editor depends on

    func testTriangulationIsDeterministic() throws {
        let (basePoints, outer, holes, _) = bone()
        var points = basePoints
        let interior = interiorPoints(into: &points, outer: outer, holes: holes, count: 40)
        let a = try MeshKernel.triangulate(
            points: points, boundary: .init(outer: outer), interior: interior)
        let b = try MeshKernel.triangulate(
            points: points, boundary: .init(outer: outer), interior: interior)
        XCTAssertEqual(a, b, "same input must give the same mesh on every run")
    }

    func testTriangulationNeverRenumbersAVertex() throws {
        // Bone weights and deform keyframes address vertices by index. If the
        // kernel reordered points, every one of them would silently point at
        // the wrong vertex.
        let (basePoints, outer, holes, _) = bone()
        var points = basePoints
        let interior = interiorPoints(into: &points, outer: outer, holes: holes, count: 30)
        let before = points
        _ = try MeshKernel.triangulate(
            points: points, boundary: .init(outer: outer), interior: interior)
        XCTAssertEqual(points, before)
    }

    func testOrphanVertexIsAbsorbedWithoutChangingArea() {
        let points = [p(0, 0), p(50, 0), p(100, 0), p(100, 100), p(0, 100)]
        let ring = [0, 1, 2, 3, 4]
        // A tiling that covers the square completely but never mentions vertex 1.
        let skipped = [0, 2, 3, 0, 3, 4]
        func area(_ t: [Int]) -> Double {
            stride(from: 0, to: t.count, by: 3).reduce(0.0) {
                $0 + abs(MeshPredicates.signedArea2(
                    points[t[$1]], points[t[$1 + 1]], points[t[$1 + 2]])) / 2.0
            }
        }
        let repaired = MeshKernel.absorbOrphanRingVertices(
            points: points, ring: ring, triangles: skipped)
        XCTAssertTrue(Set(repaired).contains(1), "the orphaned vertex must be put back")
        XCTAssertEqual(area(repaired), area(skipped), accuracy: 1e-9,
                       "the repair must not change the covered area")
    }

    // MARK: - Predicates

    func testOrient2dIsExactOnCollinearInput() {
        // Collinear lattice points must give exactly zero, not a small residue —
        // every ear, diagonal and ring test depends on that being reliable.
        let line: [SIMD2<Float>] = [p(0, 0), p(1, 1), p(2, 2), p(3, 3), p(100, 100)]
        for i in 0..<line.count {
            for j in (i + 1)..<line.count {
                for k in (j + 1)..<line.count {
                    XCTAssertEqual(MeshPredicates.orient2d(line[i], line[j], line[k]), 0,
                                   "(\(i),\(j),\(k)) should be exactly collinear")
                }
            }
        }
    }

    func testOrient2dSignsAreCorrect() {
        let a = p(0, 0), b = p(10, 0)
        XCTAssertGreaterThan(MeshPredicates.orient2d(a, b, p(5, 1)), 0)
        XCTAssertLessThan(MeshPredicates.orient2d(a, b, p(5, -1)), 0)
        XCTAssertEqual(MeshPredicates.orient2d(a, b, p(5, 0)), 0)
    }

    func testPointOnSegmentIsClosed() {
        let a = p(0, 0), b = p(10, 10)
        XCTAssertTrue(MeshPredicates.pointOnSegment(p(5, 5), a, b))
        XCTAssertTrue(MeshPredicates.pointOnSegment(a, a, b))
        XCTAssertFalse(MeshPredicates.pointOnSegment(p(15, 15), a, b))   // beyond the end
        XCTAssertFalse(MeshPredicates.pointOnSegment(p(5, 6), a, b))
    }

    func testTouchingSegmentsCountAsMeetingButNotAsCrossing() {
        let a1 = p(0, 0), a2 = p(10, 0)
        let b1 = p(5, 0), b2 = p(5, 10)          // touches the middle of a
        XCTAssertFalse(MeshPredicates.segmentsProperlyIntersect(a1, a2, b1, b2))
        XCTAssertTrue(MeshPredicates.segmentsTouchOrCross(a1, a2, b1, b2))
    }
}
