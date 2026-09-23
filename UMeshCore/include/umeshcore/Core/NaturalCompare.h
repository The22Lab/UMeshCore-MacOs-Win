#pragma once

// Foundation's `localizedStandardCompare`, the sort the Finder uses -- the
// one the Swift source reaches for whenever a list of names has to be
// something a person can find a name in twice (bone pickers, the IK
// builder's hierarchy). Its two properties that matter to an artist:
//
//   - CASE-INSENSITIVE: "arm" and "Arm" sort together.
//   - NUMERIC RUNS COMPARE BY VALUE: "Bone 2" comes before "Bone 10". A
//     plain byte compare puts "Bone 10" first, which is the order nobody
//     expects in a rig with more than nine bones.
//
// DIVERGENCE, AND ITS LIMIT. The Swift call is locale-aware (Unicode
// collation, diacritic folding). This is not: case folding is ASCII only,
// and any other byte compares by value. For the names a rig actually has
// -- ASCII words and numbers, which is what `Bone N` and every import path
// produce -- the two agree; for accented or non-Latin names they may order
// differently. Nothing is saved in this order; it only decides how a list
// is shown, so a difference is cosmetic, never data.
//
// Equal-comparing names that differ only in case or leading zeros return
// 0; callers that need a total order break the tie themselves (by id).

#include <string>

namespace umeshcore {

// <0, 0, >0 as strcmp.
int naturalCompare(const std::string& a, const std::string& b);

inline bool naturalLess(const std::string& a, const std::string& b) {
    return naturalCompare(a, b) < 0;
}

} // namespace umeshcore
