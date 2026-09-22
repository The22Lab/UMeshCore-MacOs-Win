#include "umeshcore/Serialization/Sha256.h"

#include <array>
#include <cstdio>
#include <cstring>

namespace umeshcore {

namespace {

// FIPS 180-4 section 4.2.2: the first 32 bits of the fractional parts of
// the cube roots of the first 64 primes.
constexpr std::array<std::uint32_t, 64> kRoundConstants{
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
};

constexpr std::uint32_t rotr(std::uint32_t value, int bits) {
    return (value >> bits) | (value << (32 - bits));
}

void compress(std::array<std::uint32_t, 8>& state, const std::uint8_t block[64]) {
    std::array<std::uint32_t, 64> w{};
    for (int i = 0; i < 16; ++i) {
        const std::size_t o = static_cast<std::size_t>(i) * 4;
        w[static_cast<std::size_t>(i)] = (static_cast<std::uint32_t>(block[o]) << 24) |
                                         (static_cast<std::uint32_t>(block[o + 1]) << 16) |
                                         (static_cast<std::uint32_t>(block[o + 2]) << 8) |
                                         static_cast<std::uint32_t>(block[o + 3]);
    }
    for (int i = 16; i < 64; ++i) {
        const std::uint32_t s0 = rotr(w[static_cast<std::size_t>(i - 15)], 7) ^
                                 rotr(w[static_cast<std::size_t>(i - 15)], 18) ^
                                 (w[static_cast<std::size_t>(i - 15)] >> 3);
        const std::uint32_t s1 = rotr(w[static_cast<std::size_t>(i - 2)], 17) ^
                                 rotr(w[static_cast<std::size_t>(i - 2)], 19) ^
                                 (w[static_cast<std::size_t>(i - 2)] >> 10);
        w[static_cast<std::size_t>(i)] = w[static_cast<std::size_t>(i - 16)] + s0 +
                                         w[static_cast<std::size_t>(i - 7)] + s1;
    }

    std::uint32_t a = state[0], b = state[1], c = state[2], d = state[3];
    std::uint32_t e = state[4], f = state[5], g = state[6], h = state[7];

    for (int i = 0; i < 64; ++i) {
        const std::uint32_t S1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25);
        const std::uint32_t ch = (e & f) ^ (~e & g);
        const std::uint32_t temp1 = h + S1 + ch + kRoundConstants[static_cast<std::size_t>(i)] +
                                    w[static_cast<std::size_t>(i)];
        const std::uint32_t S0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22);
        const std::uint32_t maj = (a & b) ^ (a & c) ^ (b & c);
        const std::uint32_t temp2 = S0 + maj;

        h = g;
        g = f;
        f = e;
        e = d + temp1;
        d = c;
        c = b;
        b = a;
        a = temp1 + temp2;
    }

    state[0] += a;
    state[1] += b;
    state[2] += c;
    state[3] += d;
    state[4] += e;
    state[5] += f;
    state[6] += g;
    state[7] += h;
}

} // namespace

std::string sha256Hex(const std::uint8_t* data, std::size_t size) {
    // FIPS 180-4 section 5.3.3: the first 32 bits of the fractional parts
    // of the square roots of the first 8 primes.
    std::array<std::uint32_t, 8> state{0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
                                       0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19};

    std::size_t offset = 0;
    while (size - offset >= 64) {
        compress(state, data + offset);
        offset += 64;
    }

    // Padding: 0x80, then zeros, then the message length in bits as a
    // big-endian 64-bit integer, filling one or two final blocks.
    std::uint8_t tail[128] = {};
    const std::size_t remaining = size - offset;
    std::memcpy(tail, data + offset, remaining);
    tail[remaining] = 0x80;
    const std::size_t tailBlocks = (remaining + 1 + 8 > 64) ? 2 : 1;
    const std::uint64_t bitLength = static_cast<std::uint64_t>(size) * 8;
    for (int i = 0; i < 8; ++i) {
        tail[tailBlocks * 64 - 1 - static_cast<std::size_t>(i)] =
            static_cast<std::uint8_t>((bitLength >> (8 * i)) & 0xFF);
    }
    for (std::size_t block = 0; block < tailBlocks; ++block) compress(state, tail + block * 64);

    std::string hex;
    hex.reserve(64);
    char buf[9];
    for (std::uint32_t word : state) {
        std::snprintf(buf, sizeof(buf), "%08x", word);
        hex += buf;
    }
    return hex;
}

std::string sha256Hex(const std::vector<std::uint8_t>& data) {
    return sha256Hex(data.empty() ? reinterpret_cast<const std::uint8_t*>("") : data.data(), data.size());
}

std::string sha256Hex(const std::string& text) {
    return sha256Hex(reinterpret_cast<const std::uint8_t*>(text.data()), text.size());
}

} // namespace umeshcore
