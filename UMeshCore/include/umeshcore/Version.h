#pragma once

namespace umeshcore {

// Bumped whenever a behavior-affecting change lands (not build metadata) --
// useful for embedding into exported project files so a mismatch between
// the writer and a future reader is diagnosable.
constexpr int kVersionMajor = 0;
constexpr int kVersionMinor = 1;
constexpr int kVersionPatch = 0;

const char* versionString();

} // namespace umeshcore
