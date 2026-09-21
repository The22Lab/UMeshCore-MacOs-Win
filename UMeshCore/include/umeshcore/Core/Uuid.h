#pragma once

// Stand-in for Swift's `Foundation.UUID`, used as the universal identity
// type for bones, sprites, meshes, constraints, keyframes, etc. throughout
// the port. Only identity (equality/hashing/ordering) matters for the
// algorithms ported from Swift -- nothing in the app's logic depends on the
// specific bit pattern of a UUID, so this does not need to reproduce
// Swift's UUID generator bit-for-bit (unlike the deterministic slot-name
// hash in Keyframe, which does and gets its own function).

#include <cstdint>
#include <cstdio>
#include <functional>
#include <optional>
#include <random>
#include <string>

namespace umeshcore {

struct Uuid {
    std::uint64_t hi = 0;
    std::uint64_t lo = 0;

    constexpr Uuid() = default;
    constexpr Uuid(std::uint64_t hi_, std::uint64_t lo_) : hi(hi_), lo(lo_) {}

    static constexpr Uuid nil() { return Uuid(0, 0); }
    constexpr bool isNil() const { return hi == 0 && lo == 0; }

    static Uuid generate() {
        thread_local std::mt19937_64 engine{std::random_device{}()};
        thread_local std::uniform_int_distribution<std::uint64_t> dist;
        std::uint64_t hi = dist(engine);
        std::uint64_t lo = dist(engine);
        // RFC 4122 version-4 / variant-1 bits, purely cosmetic (see header
        // comment: nothing depends on this), kept only so a printed UUID
        // looks like the ones Swift produces if it ever shows up in a log.
        hi = (hi & 0xFFFFFFFFFFFF0FFFULL) | 0x0000000000004000ULL;
        lo = (lo & 0x3FFFFFFFFFFFFFFFULL) | 0x8000000000000000ULL;
        return Uuid(hi, lo);
    }

    constexpr bool operator==(const Uuid& o) const { return hi == o.hi && lo == o.lo; }
    constexpr bool operator!=(const Uuid& o) const { return !(*this == o); }
    constexpr bool operator<(const Uuid& o) const {
        return hi != o.hi ? hi < o.hi : lo < o.lo;
    }

    // Parses the canonical 8-4-4-4-12 hex form (dashes optional, case
    // insensitive). Returns nullopt on malformed input. Used for literal
    // fixed-UUID constants (see SceneAnimationTarget) and, later, for
    // reading UUIDs out of serialized project files.
    static std::optional<Uuid> parse(const std::string& text) {
        std::string hex;
        hex.reserve(32);
        for (char c : text) {
            if (c == '-') continue;
            hex.push_back(c);
        }
        if (hex.size() != 32) return std::nullopt;
        std::uint64_t hi = 0;
        std::uint64_t lo = 0;
        for (std::size_t i = 0; i < 32; ++i) {
            const char c = hex[i];
            unsigned nibble;
            if (c >= '0' && c <= '9') nibble = static_cast<unsigned>(c - '0');
            else if (c >= 'a' && c <= 'f') nibble = static_cast<unsigned>(c - 'a' + 10);
            else if (c >= 'A' && c <= 'F') nibble = static_cast<unsigned>(c - 'A' + 10);
            else return std::nullopt;
            if (i < 16) {
                hi = (hi << 4) | nibble;
            } else {
                lo = (lo << 4) | nibble;
            }
        }
        return Uuid(hi, lo);
    }

    std::string toString() const {
        char buf[37];
        std::snprintf(
            buf, sizeof(buf), "%08X-%04X-%04X-%04X-%04X%08X",
            static_cast<unsigned>(hi >> 32), static_cast<unsigned>((hi >> 16) & 0xFFFF),
            static_cast<unsigned>(hi & 0xFFFF), static_cast<unsigned>(lo >> 48),
            static_cast<unsigned>((lo >> 32) & 0xFFFF), static_cast<unsigned>(lo & 0xFFFFFFFF));
        return std::string(buf);
    }
};

struct UuidHash {
    std::size_t operator()(const Uuid& id) const noexcept {
        // 64-bit mix (splitmix64 finalizer) combining hi/lo -- avoids the
        // weak "xor the two halves" hash that collides whenever hi==lo xor
        // patterns repeat, which is common for UUIDs minted in a tight loop
        // by a single-threaded generator.
        std::uint64_t x = id.hi ^ (id.lo + 0x9e3779b97f4a7c15ULL + (id.hi << 6) + (id.hi >> 2));
        x ^= x >> 30; x *= 0xbf58476d1ce4e5b9ULL;
        x ^= x >> 27; x *= 0x94d049bb133111ebULL;
        x ^= x >> 31;
        return static_cast<std::size_t>(x);
    }
};

} // namespace umeshcore
