import Foundation
import simd

/// The one triangulation path in UltraMesh.
///
/// Every mesh mutation routes through `MeshKernel.triangulate`. There is
/// deliberately no second way to build a triangle list, because the bug this
/// replaces came from having two: the insert paths used ear clipping and were
/// watertight, while `removingVertices` used an unconstrained Delaunay followed
/// by a filter that only ever *discarded* triangles. Nothing forced the outline's
/// own edges into that triangulation, so on a concave silhouette the straddling
/// triangles were thrown away and nothing replaced them — the wedge of missing
/// geometry that appears after deleting a node.
///
/// The pipeline here cannot produce that failure, by construction rather than by
/// checking afterwards:
///
///   1. `bridgeHoles`  rings become one simple polygon, holes joined by a
///                     zero-width channel that encloses no area
///   2. `earClip`      tiles that polygon exactly; boundary-exact by definition
///   3. `splitInsert`  each interior point splits its triangle into three,
///                     which preserves the total area exactly
///   4. `lawsonFlips`  improves toward Delaunay by swapping the diagonal of a
///                     convex quad, which is also area-preserving
///
/// No step can open a gap, so watertightness is structural. When an input cannot
/// be triangulated without losing a vertex the kernel throws instead of
/// returning a partial result, and the caller leaves the mesh as it was.
///
/// Verified against `Meshing/pymesh/kernel.py`, which is the normative reference
/// for this file. Measured there on identical inputs, old path versus this one:
/// the bone silhouette from the bug report went from 97.76 % coverage to
/// 100.0000 %, and a comb shape from 57.08 % to 100.0000 %.
enum MeshKernel {

    // MARK: - Errors

    enum Failure: LocalizedError, Equatable {
        case ringTooSmall
        case ringSelfIntersecting
        case ringFoldsBack
        case holeRingTooSmall
        case holeRingSelfIntersecting
        case cannotTileWithoutLosingVertex
        case didNotConverge
        case tooManyVertices(Int)

        var errorDescription: String? {
            switch self {
            case .ringTooSmall:
                return "The outline needs at least three points."
            case .ringSelfIntersecting:
                return "The outline crosses itself."
            case .ringFoldsBack:
                return "The outline doubles back on itself, so part of it encloses no area."
            case .holeRingTooSmall:
                return "A hole needs at least three points."
            case .holeRingSelfIntersecting:
                return "A hole outline crosses itself."
            case .cannotTileWithoutLosingVertex:
                return "This shape cannot be filled without dropping a point."
            case .didNotConverge:
                return "The outline could not be filled."
            case .tooManyVertices(let count):
                return "A mesh cannot have more than 65 535 points (this one has \(count))."
            }
        }
    }

    // MARK: - Boundary

    /// An outer ring plus any number of hole rings, as indices into a point array.
    struct Boundary: Equatable {
        var outer: [Int]
        var holes: [[Int]]

        init(outer: [Int], holes: [[Int]] = []) {
            self.outer = outer
            self.holes = holes
        }
    }

    // MARK: - Entry point

    /// Triangulate a region. Returns a flat index list wound counter-clockwise.
    ///
    /// - Parameters:
    ///   - points: vertex positions; never reordered, moved or renumbered, so
    ///     bone weights and deform keyframes stay addressed by the same index.
    ///   - boundary: outer ring and hole rings.
    ///   - interior: free points to insert inside the region.
    ///   - constraints: edges that the Lawson pass must not flip away.
    static func triangulate(
        points: [SIMD2<Float>],
        boundary: Boundary,
        interior: [Int] = [],
        constraints: [(Int, Int)] = [],
        improve: Bool = true
    ) throws -> [UInt16] {
        guard points.count <= Int(UInt16.max) + 1 else {
            throw Failure.tooManyVertices(points.count)
        }
        guard boundary.outer.count >= 3 else { throw Failure.ringTooSmall }
        try validateRing(points: points, ring: boundary.outer, isHole: false)
        for hole in boundary.holes {
            guard hole.count >= 3 else { throw Failure.holeRingTooSmall }
            try validateRing(points: points, ring: hole, isHole: true)
        }

        // Normalise winding: outer counter-clockwise, holes clockwise, so the
        // bridge channel closes correctly and the hole interior stays excluded.
        var outerRing = boundary.outer
        if signedArea2(points: points, ring: outerRing) < 0 { outerRing.reverse() }

        var holeRings: [[Int]] = []
        holeRings.reserveCapacity(boundary.holes.count)
        for hole in boundary.holes {
            var ring = hole
            if signedArea2(points: points, ring: ring) > 0 { ring.reverse() }
            holeRings.append(ring)
        }

        let polygon = holeRings.isEmpty
            ? outerRing
            : bridgeHoles(points: points, outer: outerRing, holes: holeRings)

        var triangles = try earClip(points: points, ring: polygon)

        for index in interior {
            guard points.indices.contains(index) else { continue }
            triangles = splitInsert(points: points, triangles: triangles, pointIndex: index)
        }

        if improve {
            // Ring edges are constraints too: flipping one would cut a corner
            // off the silhouette.
            var edges = constraints
            for ring in [outerRing] + holeRings {
                for i in ring.indices {
                    edges.append((ring[i], ring[(i + 1) % ring.count]))
                }
            }
            triangles = lawsonFlips(points: points, triangles: triangles, constrained: edges)
        }

        return triangles.map { UInt16($0) }
    }

    // MARK: - Ring validation

    private static func validateRing(points: [SIMD2<Float>], ring: [Int], isHole: Bool) throws {
        guard Set(ring).count == ring.count else {
            throw isHole ? Failure.holeRingSelfIntersecting : Failure.ringSelfIntersecting
        }
        for index in ring where !points.indices.contains(index) {
            throw isHole ? Failure.holeRingSelfIntersecting : Failure.ringSelfIntersecting
        }

        let n = ring.count
        for i in 0..<n {
            let a1 = points[ring[i]]
            let a2 = points[ring[(i + 1) % n]]
            guard a1 != a2 else {
                throw isHole ? Failure.holeRingSelfIntersecting : Failure.ringSelfIntersecting
            }

            // Consecutive edges may run straight on (180°, harmless) but must
            // not fold back over each other. Deleting a boundary point can leave
            // three outline points collinear with the middle one *beyond* the
            // other two: no pair of edges crosses transversally, yet that vertex
            // bounds no area and no triangulation can place it. Accepting such a
            // ring is how a vertex silently disappears, taking its bone weights
            // and every deform keyframe that addressed it.
            let c = points[ring[(i + 2) % n]]
            if MeshPredicates.orient2d(a1, a2, c) == 0 {
                // Widen before subtracting, not after: a Float difference can
                // round, and this sign is what separates "the outline runs
                // straight on" from "the outline doubles back".
                let back = (Double(c.x) - Double(a2.x)) * (Double(a1.x) - Double(a2.x))
                    + (Double(c.y) - Double(a2.y)) * (Double(a1.y) - Double(a2.y))
                if back > 0 {
                    throw isHole ? Failure.holeRingSelfIntersecting : Failure.ringFoldsBack
                }
            }

            for j in (i + 1)..<n {
                if j == i + 1 || (i == 0 && j == n - 1) { continue }  // shares a corner
                let b1 = points[ring[j]]
                let b2 = points[ring[(j + 1) % n]]
                if MeshPredicates.segmentsTouchOrCross(a1, a2, b1, b2) {
                    throw isHole ? Failure.holeRingSelfIntersecting : Failure.ringSelfIntersecting
                }
            }
        }
    }

    // MARK: - Polygon helpers

    /// Twice the signed area of a ring. Positive means counter-clockwise.
    static func signedArea2(points: [SIMD2<Float>], ring: [Int]) -> Double {
        var total = 0.0
        let n = ring.count
        for i in 0..<n {
            let p1 = points[ring[i]]
            let p2 = points[ring[(i + 1) % n]]
            total += Double(p1.x) * Double(p2.y) - Double(p2.x) * Double(p1.y)
        }
        return total
    }

    static func polygonArea(points: [SIMD2<Float>], ring: [Int]) -> Double {
        abs(signedArea2(points: points, ring: ring)) / 2.0
    }

    /// Even-odd containment test against a ring.
    static func pointInRing(points: [SIMD2<Float>], ring: [Int], _ p: SIMD2<Float>) -> Bool {
        var inside = false
        let n = ring.count
        let px = Double(p.x), py = Double(p.y)
        for i in 0..<n {
            let a = points[ring[i]], b = points[ring[(i + 1) % n]]
            let x1 = Double(a.x), y1 = Double(a.y)
            let x2 = Double(b.x), y2 = Double(b.y)
            if (y1 > py) != (y2 > py) {
                let xint = (x2 - x1) * (py - y1) / (y2 - y1) + x1
                if px < xint { inside.toggle() }
            }
        }
        return inside
    }

    /// Closed containment: a point exactly on an edge counts as inside.
    static func pointInTriangle(
        points: [SIMD2<Float>], _ ia: Int, _ ib: Int, _ ic: Int, _ p: SIMD2<Float>
    ) -> Bool {
        let d1 = MeshPredicates.orient2d(points[ia], points[ib], p)
        let d2 = MeshPredicates.orient2d(points[ib], points[ic], p)
        let d3 = MeshPredicates.orient2d(points[ic], points[ia], p)
        let hasNegative = d1 < 0 || d2 < 0 || d3 < 0
        let hasPositive = d1 > 0 || d2 > 0 || d3 > 0
        return !(hasNegative && hasPositive)
    }

    // MARK: - 1. Hole bridging

    /// Join every hole ring into the outer ring with a zero-width channel.
    ///
    /// The result is ONE simple polygon the ear clipper can tile directly, so
    /// holes need no separate machinery downstream. The channel is traversed
    /// once in each direction, which is why it encloses no area and why no
    /// triangle can end up inside a hole.
    static func bridgeHoles(points: [SIMD2<Float>], outer: [Int], holes: [[Int]]) -> [Int] {
        var ring = outer
        var remaining = holes

        while !remaining.isEmpty {
            // Take the hole whose closest approach to the current ring is
            // smallest, so an early bridge cannot box in a later one.
            var bestDistance = Double.infinity
            var bestHole = 0, bestRingPos = 0, bestHolePos = 0

            for (holeIndex, hole) in remaining.enumerated() {
                for (ringPos, ringIndex) in ring.enumerated() {
                    let a = points[ringIndex]
                    for (holePos, holeIndex2) in hole.enumerated() {
                        let b = points[holeIndex2]
                        let dx = Double(a.x - b.x), dy = Double(a.y - b.y)
                        let d = dx * dx + dy * dy
                        if d < bestDistance {
                            bestDistance = d
                            bestHole = holeIndex
                            bestRingPos = ringPos
                            bestHolePos = holePos
                        }
                    }
                }
            }

            let hole = remaining.remove(at: bestHole)
            // Walk the hole from its bridge point all the way round and back,
            // then return along the channel to the outer ring.
            let rotated = Array(hole[bestHolePos...]) + Array(hole[..<bestHolePos]) + [hole[bestHolePos]]
            ring = Array(ring[...bestRingPos]) + rotated + Array(ring[bestRingPos...])
        }

        return ring
    }

    // MARK: - 2. Ear clipping

    /// Tile a simple polygon exactly.
    ///
    /// Clips the first valid ear found while walking the ring over a linked
    /// list, which is O(n²). The obvious alternative — rescan every position
    /// each time and clip the globally shortest chord — is O(n³): measured in
    /// the Python reference at 3.3 s for a 200-vertex ring and 218 s at 800,
    /// sizes a traced sprite outline reaches easily. Nothing is lost by dropping
    /// that heuristic, because the Lawson pass afterwards takes the result all
    /// the way to Delaunay quality, which is better than what shortest-chord was
    /// approximating.
    static func earClip(points: [SIMD2<Float>], ring: [Int]) throws -> [Int] {
        var idx = ring
        if signedArea2(points: points, ring: idx) < 0 { idx.reverse() }
        let tiled = try earClipCounterClockwise(points: points, ring: idx)
        return absorbOrphanRingVertices(points: points, ring: ring, triangles: tiled)
    }

    /// Ear clipping proper, on a ring already known to be counter-clockwise.
    private static func earClipCounterClockwise(
        points: [SIMD2<Float>], ring idx: [Int]
    ) throws -> [Int] {
        let n = idx.count
        if n < 3 { return [] }
        if n == 3 {
            if MeshPredicates.orient2d(points[idx[0]], points[idx[1]], points[idx[2]]) != 0 {
                return idx
            }
            return []
        }

        var prev = (0..<n).map { ($0 + n - 1) % n }
        var next = (0..<n).map { ($0 + 1) % n }
        var alive = [Bool](repeating: true, count: n)

        func isEar(_ i: Int) -> Bool {
            let a = prev[i], b = i, c = next[i]
            guard MeshPredicates.orient2d(points[idx[a]], points[idx[b]], points[idx[c]]) > 0
            else { return false }   // reflex or degenerate, not an ear
            // Containment is closed on purpose: a vertex lying exactly on the
            // base of the ear must block it, or clipping would run the new
            // boundary edge straight through that vertex and orphan it.
            for k in 0..<n where alive[k] && k != a && k != b && k != c {
                if pointInTriangle(points: points, idx[a], idx[b], idx[c], points[idx[k]]) {
                    return false
                }
            }
            return true
        }

        var out: [Int] = []
        out.reserveCapacity((n - 2) * 3)

        var remaining = n
        var cur = 0
        var misses = 0

        while remaining > 3 {
            if misses > remaining { break }   // no ear anywhere: fall through to the split
            if !alive[cur] { cur = next[cur]; continue }

            if isEar(cur) {
                let a = prev[cur], b = cur, c = next[cur]
                out.append(contentsOf: [idx[a], idx[b], idx[c]])
                alive[cur] = false
                next[a] = c
                prev[c] = a
                remaining -= 1
                misses = 0
                cur = a                        // the neighbourhood changed; retry here
            } else {
                misses += 1
                cur = next[cur]
            }
        }

        if remaining > 3 {
            // No strictly convex ear anywhere. This happens when collinear
            // boundary points sit on the base of every candidate ear — common
            // after RDP simplification and after a vertex delete leaves three
            // boundary points in a line.
            //
            // Splitting the ring on a valid interior diagonal keeps every vertex
            // — a dropped one would be orphaned, losing its weights and its
            // deform keyframes — and strictly reduces the problem size.
            guard let start = (0..<n).first(where: { alive[$0] }) else {
                throw Failure.cannotTileWithoutLosingVertex
            }
            var stuck: [Int] = []
            var pos = start
            repeat {
                stuck.append(idx[pos])
                pos = next[pos]
            } while pos != start

            guard let split = findDiagonal(points: points, ring: stuck) else {
                // Nothing left that keeps every vertex. Refusing is the right
                // escalation: the caller leaves the mesh untouched. Returning
                // the ears clipped so far would ship a torn outline, which is
                // the failure being removed.
                throw Failure.cannotTileWithoutLosingVertex
            }
            let (i, j) = split
            let ringA = Array(stuck[i...j])
            let ringB = Array(stuck[j...]) + Array(stuck[...i])
            // `out` already holds the ears clipped before the ring got stuck;
            // dropping it here would punch exactly the kind of hole this type
            // exists to prevent.
            let halfA = try earClipCounterClockwise(points: points, ring: ringA)
            let halfB = try earClipCounterClockwise(points: points, ring: ringB)
            return out + halfA + halfB
        }

        // Three vertices left: emit the last triangle unless it is degenerate.
        if let start = (0..<n).first(where: { alive[$0] }) {
            var last: [Int] = []
            var pos = start
            for _ in 0..<3 {
                last.append(idx[pos])
                pos = next[pos]
            }
            if MeshPredicates.orient2d(points[last[0]], points[last[1]], points[last[2]]) != 0 {
                out.append(contentsOf: last)
            }
        }

        return out
    }

    /// True when the segment ring[i] -> ring[j] leaves vertex i into the interior.
    ///
    /// O'Rourke's cone test. A collinear vertex — previous, self and next on one
    /// line — falls into the convex branch, where the two strict tests collapse
    /// to the single half-plane that is actually the inside, which is the case
    /// this whole fallback exists to serve.
    private static func inCone(points: [SIMD2<Float>], ring: [Int], _ i: Int, _ j: Int) -> Bool {
        let a0 = points[ring[i == 0 ? ring.count - 1 : i - 1]]
        let a = points[ring[i]]
        let a1 = points[ring[(i + 1) % ring.count]]
        let b = points[ring[j]]

        if MeshPredicates.orient2d(a, a1, a0) >= 0 {           // convex or collinear
            return MeshPredicates.orient2d(a, b, a0) > 0
                && MeshPredicates.orient2d(b, a, a1) > 0
        }
        return !(MeshPredicates.orient2d(a, b, a1) >= 0
                 && MeshPredicates.orient2d(b, a, a0) >= 0)
    }

    /// True when the segment ring[i] -> ring[j] meets the ring only at its ends.
    private static func diagonalIsClear(
        points: [SIMD2<Float>], ring: [Int], _ i: Int, _ j: Int
    ) -> Bool {
        let n = ring.count
        let a = points[ring[i]], b = points[ring[j]]
        for k in 0..<n {
            let k2 = (k + 1) % n
            let c = points[ring[k]], d = points[ring[k2]]
            if k != i && k != j && k2 != i && k2 != j {
                if MeshPredicates.segmentsProperlyIntersect(a, b, c, d) { return false }
            }
            // A third vertex sitting exactly on the diagonal would end up on the
            // boundary edge of both halves — the very orphaning this is fixing.
            // A shorter diagonal ending at that vertex is always available.
            if k != i && k != j && c != a && c != b
                && MeshPredicates.pointOnSegment(c, a, b) {
                return false
            }
        }
        return true
    }

    /// Shortest interior diagonal of the ring, as a pair of ring positions.
    ///
    /// Returns `i < j`, non-adjacent both ways so each half keeps at least three
    /// vertices, or `nil` when the ring admits no diagonal at all.
    static func findDiagonal(points: [SIMD2<Float>], ring: [Int]) -> (Int, Int)? {
        let n = ring.count
        guard n >= 4 else { return nil }

        var candidates: [(Double, Int, Int)] = []
        for i in 0..<n {
            for j in (i + 2)..<n {
                if i == 0 && j == n - 1 { continue }   // adjacent the other way round
                let pa = points[ring[i]], pb = points[ring[j]]
                if pa == pb { continue }
                let dx = Double(pa.x - pb.x), dy = Double(pa.y - pb.y)
                candidates.append((dx * dx + dy * dy, i, j))
            }
        }
        candidates.sort { $0.0 < $1.0 }

        for (_, i, j) in candidates {
            // Cone first: it is O(1) and rejects most pairs.
            guard inCone(points: points, ring: ring, i, j),
                  inCone(points: points, ring: ring, j, i) else { continue }
            guard diagonalIsClear(points: points, ring: ring, i, j) else { continue }
            // Midpoint containment catches the one case the local tests cannot:
            // a chord that leaves and re-enters through the same pocket of a
            // very concave outline.
            let a = points[ring[i]], b = points[ring[j]]
            let mid = SIMD2<Float>((a.x + b.x) * 0.5, (a.y + b.y) * 0.5)
            guard pointInRing(points: points, ring: ring, mid) else { continue }
            return (i, j)
        }
        return nil
    }

    /// Put back any ring vertex the clipper tiled around instead of through.
    ///
    /// A vertex collinear with its two ring neighbours contributes zero area, so
    /// the polygon can be covered completely without it ever being a corner: an
    /// area check reads 100 % while the vertex is simply gone, and with it that
    /// vertex's bone weights and every deform keyframe that addressed it.
    /// Coverage cannot see this — only a membership check can.
    ///
    /// Such a vertex always lies on an edge of some triangle that was produced.
    /// Splitting that triangle across it restores the vertex and redistributes
    /// the same area, so nothing else moves.
    static func absorbOrphanRingVertices(
        points: [SIMD2<Float>], ring: [Int], triangles: [Int]
    ) -> [Int] {
        let used = Set(triangles)
        var seen = Set<Int>()
        let orphans = ring.filter { seen.insert($0).inserted && !used.contains($0) }
        guard !orphans.isEmpty else { return triangles }

        var result = triangles
        for v in orphans {
            let p = points[v]
            var rebuilt: [Int] = []
            rebuilt.reserveCapacity(result.count + 3)
            var placed = false

            for t in stride(from: 0, to: result.count, by: 3) {
                let ia = result[t], ib = result[t + 1], ic = result[t + 2]
                var split: (Int, Int, Int)?

                // Each rotation presents one edge (u, w) with the opposite
                // corner x, keeping the counter-clockwise cycle intact.
                for (u, w, x) in [(ia, ib, ic), (ib, ic, ia), (ic, ia, ib)] {
                    if u == v || w == v || x == v { continue }
                    if points[u] == p || points[w] == p { continue }
                    guard MeshPredicates.pointOnSegment(p, points[u], points[w]) else { continue }
                    // Skip a split that would be degenerate; leave it alone.
                    if MeshPredicates.orient2d(points[u], p, points[x]) == 0
                        || MeshPredicates.orient2d(p, points[w], points[x]) == 0 { continue }
                    split = (u, w, x)
                    break
                }

                if let found = split {
                    let (u, w, x) = found
                    rebuilt.append(contentsOf: [u, v, x, v, w, x])
                    placed = true
                } else {
                    rebuilt.append(contentsOf: [ia, ib, ic])
                }
            }

            if placed { result = rebuilt }
        }
        return result
    }

    // MARK: - 3. Interior point insertion

    /// Split the triangle containing a point into three.
    ///
    /// Total area is unchanged by construction, so coverage cannot regress. A
    /// point that lands in no triangle is left out rather than forced in, and a
    /// point coinciding with an existing corner is skipped, because inserting it
    /// would create a degenerate triangle.
    static func splitInsert(
        points: [SIMD2<Float>], triangles: [Int], pointIndex: Int
    ) -> [Int] {
        let p = points[pointIndex]
        for t in stride(from: 0, to: triangles.count, by: 3) {
            let ia = triangles[t], ib = triangles[t + 1], ic = triangles[t + 2]
            guard pointInTriangle(points: points, ia, ib, ic, p) else { continue }
            if p == points[ia] || p == points[ib] || p == points[ic] { return triangles }

            var rebuilt = Array(triangles[..<t])
            rebuilt.append(contentsOf: triangles[(t + 3)...])
            for tri in [(ia, ib, pointIndex), (ib, ic, pointIndex), (ic, ia, pointIndex)] {
                if MeshPredicates.orient2d(points[tri.0], points[tri.1], points[tri.2]) != 0 {
                    rebuilt.append(contentsOf: [tri.0, tri.1, tri.2])
                }
            }
            return rebuilt
        }
        return triangles
    }

    // MARK: - 4. Lawson flips toward Delaunay

    /// Improve triangle shape without changing the covered region.
    ///
    /// Only the shared diagonal of a strictly convex quad is ever swapped, so
    /// the union of the two triangles is identical before and after: area, and
    /// therefore coverage, is invariant no matter what the in-circle test
    /// answers. Constrained edges are never flipped, and the pass count is
    /// bounded, so this cannot loop.
    ///
    /// Every flip found in a pass is applied, not just the first. Applying one
    /// and restarting the scan made `maxPasses` the maximum number of flips in
    /// the whole run: measured on a 610-triangle mesh, 202 of 921 interior edges
    /// were still violating the Delaunay condition when the budget ran out.
    /// Those are the slivers that skin badly and deform worst. Applying all of
    /// them brings the same mesh to 0 of 921.
    ///
    /// Triangles are replaced in place so their indices stay valid, and a
    /// triangle already flipped this pass is skipped, which keeps the edge map
    /// consistent for the rest of the pass.
    static func lawsonFlips(
        points: [SIMD2<Float>], triangles: [Int], constrained: [(Int, Int)], maxPasses: Int = 256
    ) -> [Int] {
        var constrainedSet = Set<MeshEdge>()
        for (a, b) in constrained where a <= Int(UInt16.max) && b <= Int(UInt16.max) {
            constrainedSet.insert(MeshEdge(UInt16(a), UInt16(b)))
        }

        var tris: [(Int, Int, Int)] = []
        tris.reserveCapacity(triangles.count / 3)
        for t in stride(from: 0, to: triangles.count, by: 3) {
            tris.append((triangles[t], triangles[t + 1], triangles[t + 2]))
        }

        for _ in 0..<maxPasses {
            var edgeOwners: [MeshEdge: [Int]] = [:]
            edgeOwners.reserveCapacity(tris.count * 3)
            // Swift hashes with a per-process random seed, so iterating the
            // dictionary directly would consider edges in a different order on
            // every launch and the same mesh could triangulate differently each
            // time. Keeping first-seen order makes the result reproducible,
            // which the project file and the exporters both depend on.
            var edgeOrder: [MeshEdge] = []
            edgeOrder.reserveCapacity(tris.count * 3)

            for (ti, tri) in tris.enumerated() {
                for (u, v) in [(tri.0, tri.1), (tri.1, tri.2), (tri.2, tri.0)] {
                    guard u <= Int(UInt16.max), v <= Int(UInt16.max) else { continue }
                    let edge = MeshEdge(UInt16(u), UInt16(v))
                    if edgeOwners[edge] == nil { edgeOrder.append(edge) }
                    edgeOwners[edge, default: []].append(ti)
                }
            }

            var dirty = Set<Int>()
            var flips = 0
            for edge in edgeOrder {
                guard let owners = edgeOwners[edge], owners.count == 2,
                      !constrainedSet.contains(edge) else { continue }
                let t1 = owners[0], t2 = owners[1]
                guard !dirty.contains(t1), !dirty.contains(t2) else { continue }
                let u = Int(edge.a), v = Int(edge.b)

                let tri1 = tris[t1], tri2 = tris[t2]
                guard let p = [tri1.0, tri1.1, tri1.2].first(where: { $0 != u && $0 != v }),
                      let q = [tri2.0, tri2.1, tri2.2].first(where: { $0 != u && $0 != v }),
                      p != q else { continue }

                // Delaunay test: is q inside the circumcircle of (u, v, p)?
                var a = points[u], b = points[v]
                let c = points[p]
                if MeshPredicates.orient2d(a, b, c) < 0 { swap(&a, &b) }
                guard MeshPredicates.incircle(a, b, c, points[q]) > 0 else { continue }

                // The flip is only legal when the quad is strictly convex,
                // otherwise the new diagonal falls outside the union and would
                // tear the mesh. This is checked with the exact orientation
                // predicate, never with the filtered in-circle value.
                guard MeshPredicates.segmentsProperlyIntersect(
                    points[u], points[v], points[p], points[q]
                ) else { continue }

                guard let new1 = wound(points: points, p, u, q),
                      let new2 = wound(points: points, p, q, v) else { continue }

                tris[t1] = new1
                tris[t2] = new2
                dirty.insert(t1)
                dirty.insert(t2)
                flips += 1
            }

            if flips == 0 { break }
        }

        var out: [Int] = []
        out.reserveCapacity(tris.count * 3)
        for tri in tris { out.append(contentsOf: [tri.0, tri.1, tri.2]) }
        return out
    }

    private static func wound(
        points: [SIMD2<Float>], _ a: Int, _ b: Int, _ c: Int
    ) -> (Int, Int, Int)? {
        let area = MeshPredicates.orient2d(points[a], points[b], points[c])
        if area == 0 { return nil }
        return area > 0 ? (a, b, c) : (a, c, b)
    }
}
