#pragma once

// Deliberately dependency-free micro test harness (no Catch2/GoogleTest
// fetch): UMeshCore's early phases need to build offline/in CI sandboxes
// without network access. Swap for a real framework later if the project
// grows to want fixtures/matchers; the golden-file comparison tests (see
// tools/golden/) are the ones that actually matter for behavior parity.

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <string>

namespace umeshcore::testing {

inline int& failureCount() {
    static int count = 0;
    return count;
}

inline void reportFailure(const char* file, int line, const std::string& message) {
    std::fprintf(stderr, "FAIL %s:%d: %s\n", file, line, message.c_str());
    ++failureCount();
}

} // namespace umeshcore::testing

#define UM_CHECK(cond)                                                                          \
    do {                                                                                         \
        if (!(cond)) {                                                                           \
            umeshcore::testing::reportFailure(__FILE__, __LINE__, "CHECK failed: " #cond);       \
        }                                                                                        \
    } while (0)

#define UM_CHECK_NEAR(a, b, eps)                                                                 \
    do {                                                                                         \
        const double umCheckA = (a);                                                             \
        const double umCheckB = (b);                                                             \
        const double umCheckEps = (eps);                                                         \
        if (!(std::fabs(umCheckA - umCheckB) <= umCheckEps)) {                                   \
            umeshcore::testing::reportFailure(                                                   \
                __FILE__, __LINE__,                                                              \
                std::string("CHECK_NEAR failed: ") + #a + " (" + std::to_string(umCheckA) +      \
                    ") vs " + #b + " (" + std::to_string(umCheckB) + "), eps=" +                 \
                    std::to_string(umCheckEps));                                                 \
        }                                                                                         \
    } while (0)

#define UM_TEST_MAIN_BEGIN() int main() {
#define UM_TEST_MAIN_END()                                                                       \
    if (umeshcore::testing::failureCount() > 0) {                                                \
        std::fprintf(stderr, "%d check(s) failed\n", umeshcore::testing::failureCount());        \
        return 1;                                                                                \
    }                                                                                             \
    std::fprintf(stderr, "all checks passed\n");                                                 \
    return 0;                                                                                     \
    }
