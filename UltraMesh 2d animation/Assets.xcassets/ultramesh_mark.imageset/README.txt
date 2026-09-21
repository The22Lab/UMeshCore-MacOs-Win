Drop the original UltraMesh logo here.

An SVG or PDF is best — set it as the 1x slot and Xcode keeps the vector
(preserves-vector-representation is already on), so it stays sharp at every
size the mark is used at. A PNG works too; supply @2x and @3x if you go that
route.

The moment an image is present here, UltraMeshMarkView switches to it with no
code change. Until then it draws the vector transcription in UltraMeshMark.swift.
