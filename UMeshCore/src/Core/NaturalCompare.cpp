#include "umeshcore/Core/NaturalCompare.h"

namespace umeshcore {

namespace {

bool isDigit(unsigned char c) { return c >= '0' && c <= '9'; }

unsigned char fold(unsigned char c) {
    return (c >= 'A' && c <= 'Z') ? static_cast<unsigned char>(c - 'A' + 'a') : c;
}

} // namespace

int naturalCompare(const std::string& a, const std::string& b) {
    std::size_t i = 0, j = 0;
    while (i < a.size() && j < b.size()) {
        const unsigned char ca = static_cast<unsigned char>(a[i]);
        const unsigned char cb = static_cast<unsigned char>(b[j]);
        if (isDigit(ca) && isDigit(cb)) {
            // Skip leading zeros, then the longer run is the larger number;
            // equal lengths compare digit by digit.
            while (i < a.size() && a[i] == '0') ++i;
            while (j < b.size() && b[j] == '0') ++j;
            std::size_t ei = i, ej = j;
            while (ei < a.size() && isDigit(static_cast<unsigned char>(a[ei]))) ++ei;
            while (ej < b.size() && isDigit(static_cast<unsigned char>(b[ej]))) ++ej;
            const std::size_t la = ei - i, lb = ej - j;
            if (la != lb) return la < lb ? -1 : 1;
            for (std::size_t k = 0; k < la; ++k) {
                if (a[i + k] != b[j + k]) return a[i + k] < b[j + k] ? -1 : 1;
            }
            i = ei;
            j = ej;
            continue;
        }
        const unsigned char fa = fold(ca), fb = fold(cb);
        if (fa != fb) return fa < fb ? -1 : 1;
        ++i;
        ++j;
    }
    if (i < a.size()) return 1;
    if (j < b.size()) return -1;
    return 0;
}

} // namespace umeshcore
