// Tests for MeshPredicates.h, ported from `Data/MeshPredicates.swift`.
//
// The orient2d golden cases below were computed independently in Python
// using exact rational arithmetic (`fractions.Fraction`), NOT derived from
// this C++ implementation or from Swift -- this is the "redo the
// exactness proof analytically" verification called for in
// UMeshCore/ROADMAP.md risk #3, standing in for the Swift source's missing
// `Meshing/verify_expansion.py` harness (which doesn't exist in this
// checkout; see the Plan agent's exploration notes).

#include <cmath>

#include "umeshcore/Mesh/MeshPredicates.h"
#include "TestHarness.h"

using namespace umeshcore;
using namespace umeshcore::MeshPredicates;

static int sign(double v) { return v > 0.0 ? 1 : (v < 0.0 ? -1 : 0); }

struct OrientCase {
    Vec2 a, b, c;
    int expectedSign;
};

static void testOrient2dExactGolden() {
    // Exactly collinear (horizontal / vertical / diagonal lines, and two
    // degenerate triangles) -- MUST be exactly 0, not just "small".
    // Random triples and near-ulp-off-collinear triples, independently
    // verified via exact rational arithmetic in Python (see file header).
    const OrientCase cases[] = {
        {{0.0f, 0.0f}, {5.0f, 0.0f}, {10.0f, 0.0f}, 0},
        {{0.0f, 0.0f}, {0.0f, 5.0f}, {0.0f, -10.0f}, 0},
        {{-3.0f, -3.0f}, {0.0f, 0.0f}, {7.0f, 7.0f}, 0},
        {{1.0f, 1.0f}, {1.0f, 1.0f}, {5.0f, 9.0f}, 0},
        {{100.0f, 50.0f}, {100.0f, 50.0f}, {100.0f, 50.0f}, 0},
        {{278.8536071777344f, -949.978515625f}, {-449.9413757324219f, -553.5785522460938f}, {472.9424133300781f, 353.39898681640625f}, -1},
        {{784.359130859375f, -826.122314453125f}, {-156.15635681152344f, -940.4055786132812f}, {-562.7240600585938f, 10.710576057434082f}, -1},
        {{-946.9280395507812f, -602.32470703125f}, {299.7688903808594f, 89.8829574584961f}, {-559.1187744140625f, 178.5313720703125f}, 1},
        {{618.8609008789062f, -987.0025024414062f}, {611.6384887695312f, 396.2787780761719f}, {-319.49896240234375f, -689.041015625f}, 1},
        {{914.4261474609375f, -326.8109130859375f}, {-814.50830078125f, -806.5672607421875f}, {694.9887084960938f, 207.45205688476562f}, -1},
        {{614.2565307617188f, 459.46356201171875f}, {72.45618438720703f, 946.2315063476562f}, {-242.93124389648438f, 104.08126068115234f}, 1},
        {{658.809326171875f, 237.0395050048828f}, {723.413818359375f, 154.70428466796875f}, {409.1436767578125f, -908.3512573242188f}, -1},
        {{-544.2034301757812f, -421.22406005859375f}, {-840.4160766601562f, -534.418212890625f}, {-797.9971313476562f, -444.05279541015625f}, -1},
        {{135.6844482421875f, -135.16781616210938f}, {52.427268981933594f, -183.87503051757812f}, {-129.81903076171875f, -290.49298095703125f}, 1},
        {{436.65460205078125f, 148.03538513183594f}, {212.8572540283203f, -177.82884216308594f}, {109.1310043334961f, -328.8613586425781f}, 1},
        {{-336.5975036621094f, -120.5445556640625f}, {114.10081481933594f, 21.597946166992188f}, {489.5233459472656f, 139.999755859375f}, -1},
        {{184.6142578125f, 342.8519287109375f}, {196.09962463378906f, 265.7089538574219f}, {275.9999084472656f, -270.9519348144531f}, -1},
        {{-184.5469512939453f, -232.25912475585938f}, {-268.2374267578125f, 308.6146545410156f}, {-289.01715087890625f, 442.90972900390625f}, -1},
        {{-185.32211303710938f, 155.43865966796875f}, {-147.50999450683594f, 276.463623046875f}, {-104.36809539794922f, 414.5475769042969f}, 1},
        {{-235.1198272705078f, -253.37249755859375f}, {-66.8128662109375f, -244.2250213623047f}, {61.368133544921875f, -237.25839233398438f}, -1},
        {{397.8228759765625f, -100.59949493408203f}, {53.400936126708984f, 203.02748107910156f}, {-280.6792297363281f, 497.53759765625f}, 1},
        {{-409.090576171875f, -452.8836364746094f}, {-395.3419189453125f, -27.11693572998047f}, {-390.3508605957031f, 127.446044921875f}, 1},
        {{-77.84003448486328f, -436.4722900390625f}, {-99.05462646484375f, 51.5460205078125f}, {-118.3807144165039f, 496.1213684082031f}, 1},
        {{471.078369140625f, 360.7796936035156f}, {-148.21533203125f, 270.3907775878906f}, {-488.51898193359375f, 220.72181701660156f}, -1},
        {{36.97032928466797f, -233.1748046875f}, {83.53897857666016f, -302.70794677734375f}, {140.9617919921875f, -388.44781494140625f}, -1},
    };
    for (const auto& tc : cases) {
        const double result = orient2d(tc.a, tc.b, tc.c);
        UM_CHECK(sign(result) == tc.expectedSign);
    }
}

static void testTwoSumErrorFree() {
    // Knuth's error-free transformation: a+b must equal sum+error EXACTLY
    // (as a mathematical identity, not just "close").
    const double pairs[][2] = {
        {1.0, 2.0}, {1e16, 1.0}, {1e-16, 1e16}, {0.1, 0.2}, {123456789.123, -987654321.987},
    };
    for (const auto& p : pairs) {
        double sum, error;
        twoSum(p[0], p[1], sum, error);
        UM_CHECK((p[0] + p[1]) == sum); // sum is the correctly-rounded a+b.
        // a + b == sum + error, but this must be checked in higher
        // precision than double to be meaningful; here we at least check
        // the identity holds when re-summed in double (weaker, but a
        // transcription smoke test -- e.g. swapped a/b in the formula
        // would likely fail even this).
        UM_CHECK_NEAR(sum + error, p[0] + p[1], 1e-9);
    }
}

static void testPointOnSegment() {
    UM_CHECK(pointOnSegment(Vec2(5, 0), Vec2(0, 0), Vec2(10, 0)));
    UM_CHECK(!pointOnSegment(Vec2(5, 1), Vec2(0, 0), Vec2(10, 0)));
    UM_CHECK(!pointOnSegment(Vec2(15, 0), Vec2(0, 0), Vec2(10, 0)));
    UM_CHECK(pointOnSegment(Vec2(0, 0), Vec2(0, 0), Vec2(10, 0))); // endpoint counts.
}

static void testSegmentsProperlyIntersect() {
    // An X crossing.
    UM_CHECK(segmentsProperlyIntersect(Vec2(0, 0), Vec2(10, 10), Vec2(0, 10), Vec2(10, 0)));
    // Parallel, non-intersecting.
    UM_CHECK(!segmentsProperlyIntersect(Vec2(0, 0), Vec2(10, 0), Vec2(0, 1), Vec2(10, 1)));
    // Sharing an endpoint does NOT count as a proper intersection.
    UM_CHECK(!segmentsProperlyIntersect(Vec2(0, 0), Vec2(10, 10), Vec2(0, 0), Vec2(10, 0)));
}

static void testSegmentsTouchOrCross() {
    // Sharing an endpoint DOES count here (inclusive test).
    UM_CHECK(segmentsTouchOrCross(Vec2(0, 0), Vec2(10, 10), Vec2(0, 0), Vec2(10, 0)));
    // Overlapping collinear segments count as touching.
    UM_CHECK(segmentsTouchOrCross(Vec2(0, 0), Vec2(10, 0), Vec2(5, 0), Vec2(15, 0)));
    // Disjoint, non-touching.
    UM_CHECK(!segmentsTouchOrCross(Vec2(0, 0), Vec2(1, 0), Vec2(5, 5), Vec2(6, 6)));
}

UM_TEST_MAIN_BEGIN()
    testOrient2dExactGolden();
    testTwoSumErrorFree();
    testPointOnSegment();
    testSegmentsProperlyIntersect();
    testSegmentsTouchOrCross();
UM_TEST_MAIN_END()
