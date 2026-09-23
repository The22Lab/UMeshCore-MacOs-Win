// 1:1 port of the test corpus in
// `UltraMesh 2d animationTests/MeshKernelTests.swift` -- same shapes, same
// expected areas, same adversarial cases (the bone silhouette that lost
// 2.2% of its coverage, the comb shape that lost 42.9%, folded/collinear
// rings). Reusing this exact corpus (rather than inventing a new one) is
// deliberate: these are proven adversarial cases for this specific
// algorithm, called out explicitly in UMeshCore/ROADMAP.md's Phase 1 plan.

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <limits>
#include <unordered_map>
#include <unordered_set>

#include "umeshcore/Mesh/MeshKernel.h"
#include "umeshcore/Mesh/MeshPredicates.h"
#include "umeshcore/Mesh/MeshValidator.h"
#include "TestHarness.h"

using namespace umeshcore;

namespace {

struct Shape {
    std::vector<Vec2> points;
    std::vector<int> outer;
    std::vector<std::vector<int>> holes;
    double expectedArea;
};

Vec2 p(float x, float y) { return Vec2(x, y); }

Shape square() { return {{p(0, 0), p(100, 0), p(100, 100), p(0, 100)}, {0, 1, 2, 3}, {}, 10000}; }

Shape shapeL() {
    return {
        {p(0, 0), p(120, 0), p(120, 40), p(40, 40), p(40, 120), p(0, 120)},
        {0, 1, 2, 3, 4, 5},
        {},
        8000};
}

Shape shapeC() {
    return {
        {p(0, 0), p(120, 0), p(120, 30), p(30, 30), p(30, 90), p(120, 90), p(120, 120), p(0, 120)},
        {0, 1, 2, 3, 4, 5, 6, 7},
        {},
        9000};
}

Shape shapeU() {
    return {
        {p(0, 0), p(40, 0), p(40, 90), p(80, 90), p(80, 0), p(120, 0), p(120, 120), p(0, 120)},
        {0, 1, 2, 3, 4, 5, 6, 7},
        {},
        10800};
}

Shape bone() {
    std::vector<Vec2> pts = {
        p(-55, 60),  p(-18, 40), p(-18, -40), p(-55, -60), p(-55, -150), p(55, -150),
        p(55, -60),  p(18, -40), p(18, 40),   p(55, 60),   p(55, 150),   p(-55, 150)};
    std::vector<int> outer;
    for (int i = 0; i < 12; ++i) outer.push_back(i);
    return {pts, outer, {}, 25600};
}

Shape comb() {
    std::vector<Vec2> pts = {
        p(0, 0),   p(12, 0),  p(12, 100), p(24, 100), p(24, 0),   p(36, 0),  p(36, 100),
        p(48, 100), p(48, 0), p(60, 0),   p(60, 100), p(72, 100), p(72, 0),  p(84, 0),
        p(84, 100), p(96, 100), p(96, 0), p(108, 0),  p(108, 100), p(120, 100), p(120, 0),
        p(120, -25), p(0, -25)};
    std::vector<int> outer;
    for (std::size_t i = 0; i < pts.size(); ++i) outer.push_back(static_cast<int>(i));
    return {pts, outer, {}, 9000};
}

Shape collinearHeavy() {
    std::vector<Vec2> pts;
    for (int i = 0; i < 10; ++i) pts.push_back(p(static_cast<float>(i) * 10, 0));
    for (int i = 0; i < 10; ++i) pts.push_back(p(100, static_cast<float>(i) * 10));
    for (int i = 0; i < 10; ++i) pts.push_back(p(100 - static_cast<float>(i) * 10, 100));
    for (int i = 0; i < 10; ++i) pts.push_back(p(0, 100 - static_cast<float>(i) * 10));
    std::vector<int> outer;
    for (int i = 0; i < 40; ++i) outer.push_back(i);
    return {pts, outer, {}, 10000};
}

Shape plateWithThreeHoles() {
    std::vector<Vec2> pts = {
        p(0, 0),   p(200, 0), p(200, 200), p(0, 200), p(30, 30), p(30, 70),  p(70, 70),
        p(70, 30), p(130, 30), p(130, 70), p(170, 70), p(170, 30), p(80, 130), p(80, 170),
        p(120, 170), p(120, 130)};
    return {pts, {0, 1, 2, 3}, {{4, 5, 6, 7}, {8, 9, 10, 11}, {12, 13, 14, 15}}, 35200};
}

std::vector<std::pair<std::string, Shape>> boundaryOnlyCorpus() {
    return {
        {"square", square()},   {"L", shapeL()},   {"C", shapeC()},
        {"U", shapeU()},        {"bone", bone()},  {"comb", comb()},
        {"collinear-heavy", collinearHeavy()},
    };
}

// Deterministic interior points via xorshift64* -- not required to be
// bit-identical to Swift's own xorshift64* implementation (this is test
// scaffolding, not a behavior under test), just deterministic within this
// C++ test binary so a failure is reproducible from the seed alone.
struct XorShift64Star {
    std::uint64_t state;
    explicit XorShift64Star(std::uint64_t seed) : state(seed) {}
    double next() {
        state ^= state >> 12;
        state ^= state << 25;
        state ^= state >> 27;
        const std::uint64_t scrambled = (state * 2685821657736338717ULL) >> 11;
        return static_cast<double>(scrambled) / static_cast<double>(std::uint64_t(1) << 53);
    }
};

std::vector<int> interiorPoints(
    std::vector<Vec2>& points, const std::vector<int>& outer, const std::vector<std::vector<int>>& holes,
    int count, std::uint64_t seed = 12345) {
    XorShift64Star rng(seed);

    float minX = std::numeric_limits<float>::max(), maxX = std::numeric_limits<float>::lowest();
    float minY = std::numeric_limits<float>::max(), maxY = std::numeric_limits<float>::lowest();
    for (int i : outer) {
        minX = std::min(minX, points[i].x);
        maxX = std::max(maxX, points[i].x);
        minY = std::min(minY, points[i].y);
        maxY = std::max(maxY, points[i].y);
    }

    std::vector<int> added;
    int attempts = 0;
    while (static_cast<int>(added.size()) < count && attempts < count * 400) {
        ++attempts;
        const Vec2 candidate(
            minX + static_cast<float>(rng.next()) * (maxX - minX),
            minY + static_cast<float>(rng.next()) * (maxY - minY));
        if (!MeshKernel::pointInRing(points, outer, candidate)) continue;
        bool insideHole = false;
        for (const auto& hole : holes) {
            if (MeshKernel::pointInRing(points, hole, candidate)) insideHole = true;
        }
        if (insideHole) continue;
        bool tooClose = false;
        for (const auto& existing : points) {
            if (std::abs(existing.x - candidate.x) < 0.5f && std::abs(existing.y - candidate.y) < 0.5f) {
                tooClose = true;
                break;
            }
        }
        if (tooClose) continue;
        points.push_back(candidate);
        added.push_back(static_cast<int>(points.size()) - 1);
    }
    return added;
}

double triangleListArea(const std::vector<Vec2>& points, const std::vector<std::uint16_t>& tris) {
    double covered = 0.0;
    for (std::size_t t = 0; t + 2 < tris.size(); t += 3) {
        covered +=
            std::abs(MeshPredicates::signedArea2(points[tris[t]], points[tris[t + 1]], points[tris[t + 2]])) / 2.0;
    }
    return covered;
}

} // namespace

static void testEveryShapeIsWatertightBoundaryOnly() {
    for (auto& [name, shape] : boundaryOnlyCorpus()) {
        MeshKernel::Boundary boundary{shape.outer, shape.holes};
        auto tris = MeshKernel::triangulate(shape.points, boundary);
        auto report = MeshValidator::validate(shape.points, tris, shape.outer, shape.holes);
        UM_CHECK(report.isValid());

        const double ratio = MeshValidator::coverageRatio(shape.points, tris, shape.outer, shape.holes);
        UM_CHECK_NEAR(ratio, 1.0, 1e-9);

        if (shape.expectedArea > 0) {
            const double covered = triangleListArea(shape.points, tris);
            UM_CHECK_NEAR(covered, shape.expectedArea, shape.expectedArea * 1e-9);
        }
    }
}

static void testEveryShapeIsWatertightWithInteriorPoints() {
    for (auto& [name, shape] : boundaryOnlyCorpus()) {
        std::vector<Vec2> points = shape.points;
        auto interior = interiorPoints(points, shape.outer, shape.holes, 40);
        UM_CHECK(static_cast<int>(interior.size()) > 20);

        MeshKernel::Boundary boundary{shape.outer, shape.holes};
        auto tris = MeshKernel::triangulate(points, boundary, interior);
        auto report = MeshValidator::validate(points, tris, shape.outer, shape.holes);
        UM_CHECK(report.isValid());
        UM_CHECK_NEAR(MeshValidator::coverageRatio(points, tris, shape.outer, shape.holes), 1.0, 1e-9);
    }
}

static void testHolesAreExcludedAndTheRestIsCovered() {
    Shape shape = plateWithThreeHoles();
    std::vector<Vec2> points = shape.points;
    MeshKernel::Boundary boundary{shape.outer, shape.holes};
    auto tris = MeshKernel::triangulate(points, boundary);
    auto report = MeshValidator::validate(points, tris, shape.outer, shape.holes);
    UM_CHECK(report.isValid());
    UM_CHECK_NEAR(MeshValidator::coverageRatio(points, tris, shape.outer, shape.holes), 1.0, 1e-9);

    const double covered = triangleListArea(points, tris);
    UM_CHECK_NEAR(covered, shape.expectedArea, shape.expectedArea * 1e-9);

    auto interior = interiorPoints(points, shape.outer, shape.holes, 30);
    auto tris2 = MeshKernel::triangulate(points, boundary, interior);
    UM_CHECK(MeshValidator::validate(points, tris2, shape.outer, shape.holes).isValid());
}

static void testDeletingAnInteriorVertexStaysWatertight() {
    Shape shape = bone();
    std::vector<Vec2> points = shape.points;
    auto interior = interiorPoints(points, shape.outer, shape.holes, 40);
    UM_CHECK(static_cast<int>(interior.size()) > 20);

    const int victim = interior[interior.size() / 2];
    std::unordered_map<int, int> remap;
    std::vector<Vec2> kept;
    for (std::size_t i = 0; i < points.size(); ++i) {
        if (static_cast<int>(i) == victim) continue;
        remap[static_cast<int>(i)] = static_cast<int>(kept.size());
        kept.push_back(points[i]);
    }
    std::vector<int> newOuter;
    for (int v : shape.outer) newOuter.push_back(remap.at(v));
    std::vector<int> newInterior;
    for (int v : interior) {
        if (v != victim) newInterior.push_back(remap.at(v));
    }

    MeshKernel::Boundary boundary{newOuter, {}};
    auto tris = MeshKernel::triangulate(kept, boundary, newInterior);
    auto report = MeshValidator::validate(kept, tris, newOuter);
    UM_CHECK(report.isValid());
    UM_CHECK_NEAR(MeshValidator::coverageRatio(kept, tris, newOuter), 1.0, 1e-9);
}

static void testFoldedOutlineIsRejected() {
    // The Swift test (`MeshKernelTests.testFoldedOutlineIsRejected`) asserts
    // this throws `.ringFoldsBack`, reasoning that vertices 0/2/3 are
    // collinear so the consecutive-triple fold check at ring position i=2
    // fires. Independently tracing `validateRing`'s literal algorithm
    // (by hand and cross-checked in Python with exact rational arithmetic)
    // shows a DIFFERENT check fires first: at i=1, edge(1,2) vs edge(3,0)
    // are non-adjacent, and vertex 2 happens to sit exactly ON edge(3,0)
    // (since 0/2/3 are collinear) -- so `segmentsTouchOrCross` at i=1
    // returns true and throws RingSelfIntersecting *before* the loop ever
    // reaches i=2's fold-back check. This is a genuine property of the
    // algorithm as written (loop order i=0,1,2,3, early-return on first
    // throw), not a transcription choice -- see the Python trace referenced
    // in this port's commit message. CONFIRMED against the real Swift binary:
    // run in Xcode, the Swift test failed with exactly this --
    // `.ringSelfIntersecting` where it expected `.ringFoldsBack` -- so the
    // Swift test was stale and now asserts the same case as this one.
    std::vector<Vec2> points = {p(120, 0), p(30, 30), p(30, 90), p(0, 120)};
    bool threw = false;
    try {
        MeshKernel::Boundary boundary{{0, 1, 2, 3}, {}};
        MeshKernel::triangulate(points, boundary);
    } catch (const MeshKernel::TriangulationError& e) {
        threw = true;
        UM_CHECK(e.failure == MeshKernel::Failure::RingSelfIntersecting);
    }
    UM_CHECK(threw);

    bool anyProperCrossing = false;
    const std::vector<int> ring = {0, 1, 2, 3};
    for (int i = 0; i < 4; ++i) {
        for (int j = i + 1; j < 4; ++j) {
            if (j == i + 1 || (i == 0 && j == 3)) continue;
            if (MeshPredicates::segmentsProperlyIntersect(
                    points[ring[i]], points[ring[(i + 1) % 4]], points[ring[j]], points[ring[(j + 1) % 4]])) {
                anyProperCrossing = true;
            }
        }
    }
    UM_CHECK(!anyProperCrossing);
}

static void testSelfIntersectingOutlineIsRejected() {
    std::vector<Vec2> points = {p(0, 0), p(10, 10), p(10, 0), p(0, 10)};
    bool threw = false;
    try {
        MeshKernel::Boundary boundary{{0, 1, 2, 3}, {}};
        MeshKernel::triangulate(points, boundary);
    } catch (const MeshKernel::TriangulationError&) {
        threw = true;
    }
    UM_CHECK(threw);
}

static void testTooFewPointsIsRejected() {
    std::vector<Vec2> points = {p(0, 0), p(1, 1)};
    bool threw = false;
    try {
        MeshKernel::Boundary boundary{{0, 1}, {}};
        MeshKernel::triangulate(points, boundary);
    } catch (const MeshKernel::TriangulationError&) {
        threw = true;
    }
    UM_CHECK(threw);
}

static void testCollinearButStraightVertexIsAccepted() {
    std::vector<Vec2> points = {p(0, 0), p(50, 0), p(100, 0), p(100, 100), p(0, 100)};
    const std::vector<int> ring = {0, 1, 2, 3, 4};
    MeshKernel::Boundary boundary{ring, {}};
    auto tris = MeshKernel::triangulate(points, boundary);
    std::unordered_set<int> used(tris.begin(), tris.end());
    for (int v : ring) UM_CHECK(used.contains(v));
    UM_CHECK(MeshValidator::validate(points, tris, ring).isValid());
}

static void testTriangulationIsDeterministic() {
    Shape shape = bone();
    std::vector<Vec2> points = shape.points;
    auto interior = interiorPoints(points, shape.outer, shape.holes, 40);
    MeshKernel::Boundary boundary{shape.outer, {}};
    auto a = MeshKernel::triangulate(points, boundary, interior);
    auto b = MeshKernel::triangulate(points, boundary, interior);
    UM_CHECK(a == b);
}

static void testTriangulationNeverRenumbersAVertex() {
    Shape shape = bone();
    std::vector<Vec2> points = shape.points;
    auto interior = interiorPoints(points, shape.outer, shape.holes, 30);
    const std::vector<Vec2> before = points;
    MeshKernel::Boundary boundary{shape.outer, {}};
    MeshKernel::triangulate(points, boundary, interior);
    UM_CHECK(points.size() == before.size());
    for (std::size_t i = 0; i < points.size(); ++i) UM_CHECK(points[i] == before[i]);
}

static void testOrphanVertexIsAbsorbedWithoutChangingArea() {
    std::vector<Vec2> points = {p(0, 0), p(50, 0), p(100, 0), p(100, 100), p(0, 100)};
    const std::vector<int> ring = {0, 1, 2, 3, 4};
    // A tiling that covers the square completely but never mentions vertex 1.
    const std::vector<int> skipped = {0, 2, 3, 0, 3, 4};
    auto area = [&](const std::vector<int>& t) {
        double total = 0.0;
        for (std::size_t i = 0; i + 2 < t.size(); i += 3) {
            total += std::abs(MeshPredicates::signedArea2(points[t[i]], points[t[i + 1]], points[t[i + 2]])) / 2.0;
        }
        return total;
    };
    auto repaired = MeshKernel::absorbOrphanRingVertices(points, ring, skipped);
    UM_CHECK(std::find(repaired.begin(), repaired.end(), 1) != repaired.end());
    UM_CHECK_NEAR(area(repaired), area(skipped), 1e-9);
}

UM_TEST_MAIN_BEGIN()
    testEveryShapeIsWatertightBoundaryOnly();
    testEveryShapeIsWatertightWithInteriorPoints();
    testHolesAreExcludedAndTheRestIsCovered();
    testDeletingAnInteriorVertexStaysWatertight();
    testFoldedOutlineIsRejected();
    testSelfIntersectingOutlineIsRejected();
    testTooFewPointsIsRejected();
    testCollinearButStraightVertexIsAccepted();
    testTriangulationIsDeterministic();
    testTriangulationNeverRenumbersAVertex();
    testOrphanVertexIsAbsorbedWithoutChangingArea();
UM_TEST_MAIN_END()
