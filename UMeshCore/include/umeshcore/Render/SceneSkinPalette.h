#pragma once

// 1:1 port of `Render/SceneGPU/SceneSkinPalette.swift` -- a rig instance's
// bones folded into the matrices a vertex shader can use.
//
// THE FOLD. `Mesh::skinnedVertices` wraps each bone transform in two
// per-sprite affines: `B` maps a bind vertex into the space the
// inverse-bind matrices expect, and `A` maps the blended result back. Both
// are affine and the bone's own matrix depends only on the bone, so
//
//     N = A * (world * inverseBind) * B
//
// is ONE matrix per sprite per bone, and the shader is then the textbook
// four-weight sum. Thirty matrices instead of 8320, with the per-vertex
// work moved to hardware built for it. The Swift harness measured the CPU
// path doing 16 640 UUID-keyed dictionary lookups and 8320 matrix products
// per frame for one eight-sprite rig, to arrive at about thirty distinct
// matrices.
//
// Everything downstream folds in too -- the sprite's posed transform and
// the layer's lift out of the card's plane into scene world are affine and
// constant for the frame:
//
//     N = rigToWorld * spriteToRig * A * (world * inverseBind) * B
//
// `rigToWorld` LIFTS INTO THREE DIMENSIONS (`SceneLayer::liftToWorld`
// takes a plane point to a world one), so what the shader writes is a 3D
// point. Flattening it to z = 0 puts a rig 652 units out of place as soon
// as the camera leaves the front view.
//
// THE CONDITION, WHICH IS THE WHOLE OF THIS TYPE. The fold is correct ONLY
// if the weights sum to one: pushing an affine inside a weighted sum adds
// its translation once per influence instead of once. The data does not
// guarantee normalised weights -- the weight brush normalises,
// auto-weighting caps at four without renormalising, and `skinnedVertices`
// divides by the total defensively, so nothing upstream ever complains.
// Measured: 700 units out of place on a 400x600 sprite with the sprite
// affine alone, 1343 with all three folded in, which reads as a rigging
// mistake rather than a renderer one. So `influences` normalises, here, on
// the way to the GPU, and nothing else may skip it.
//
// Scoping, per the port's "inject what's needed" rule: the Swift
// initializer takes a whole `Mesh` and reads exactly one field of it, so
// this takes that field (`boneInverseBindMatrices`) and leaves Render
// independent of Mesh. Same for the skeleton: the caller passes the pose it
// already has.
//
// The Swift harness cited throughout (`Editor/verify_scene_gpu_skinning.py`
// -- the exactness to 1e-13, the 652/700/1343/38.3/22.7-unit figures) does
// not exist in this repository; see CLAUDE.md. The tests assert the
// properties those numbers were measuring.

#include <cstdint>
#include <unordered_map>
#include <vector>

#include "umeshcore/Core/Uuid.h"
#include "umeshcore/Math/Mat4.h"

namespace umeshcore {

struct VertexBoneWeight;

// Four slots and four weights, summing to one.
struct SkinnedInfluences {
    std::uint16_t slots[4] = {0, 0, 0, 0};
    Vec4 weights;
};

class SceneSkinPalette {
public:
    // At most four bones move a vertex, which is what `autoWeightMesh`,
    // `skinImageToSkeleton` and the weight brush all already cap at.
    static constexpr int kMaximumInfluences = 4;

    // SLOT ZERO IS THE IDENTITY, always.
    //
    // A vertex with no influences must come out at its bind position. The
    // CPU says so with a branch on the weight total; a shader that
    // branches per vertex on a weight sum has a divergent branch in its
    // hottest loop. So the palette reserves slot zero for `A * B` -- which
    // is the identity, because A is B's inverse -- and an unweighted
    // vertex is written as one influence of weight 1 on slot zero. No
    // branch, same answer.
    //
    // Building the palette straight from the bone list instead puts the
    // first bone in slot zero, and then every unweighted vertex rides that
    // bone.
    static constexpr std::uint16_t kIdentitySlot = 0;

    SceneSkinPalette() = default;

    // `boneOrder` is the skeleton's own order, never a set's iteration
    // order: a slot taken from an unordered container would move between
    // runs, and the slot indices are baked into an uploaded vertex buffer.
    SceneSkinPalette(
        const std::vector<Uuid>& boneOrder, const std::unordered_map<Uuid, Mat4, UuidHash>& worldMatrices,
        const std::unordered_map<Uuid, Mat4, UuidHash>& boneInverseBindMatrices, const Mat4& bindToWorld,
        const Mat4& worldToBind, const Mat4& spriteToRig, const Mat4& rigToWorld);

    // Folded matrices, slot 0 the identity and the rest in bone order.
    const std::vector<Mat4>& matrices() const { return matrices_; }
    // Where each bone landed.
    const std::unordered_map<Uuid, std::uint16_t, UuidHash>& slots() const { return slots_; }

    // How many vertices had to give up an influence, over the whole sprite.
    //
    // COUNTED AND REPORTED, not swallowed. `Mesh::skinnedVertices` uses
    // EVERY influence a vertex has; a vertex shader takes four. Every tool
    // in the app already caps at four, so this should be zero on anything
    // painted here, and a mesh that arrives from somewhere else will not
    // render identically to the CPU path. The Swift harness measured a
    // fifth influence carrying 16% of a vertex's weight moving it 22.7
    // units on a 400x600 sprite -- small, bounded by the weight dropped,
    // and not nothing. Staying quiet about it is what makes a renderer look
    // broken rather than limited.
    int truncatedVertices() const { return truncatedVertices_; }

    // One vertex's influences, capped, normalised and padded to four.
    //
    // CAPPED BEFORE NORMALISING. The four that survive are renormalised
    // between themselves, so they sum to one and the fold stays exact.
    // Normalising first and then dropping the tail leaves the vertex short
    // of its full weight, which pulls it towards its bind position -- a
    // slump exactly where a mesh is most finely painted, measured at 38.3
    // units between the two orders on the same data.
    SkinnedInfluences influences(const std::vector<VertexBoneWeight>& weights);

private:
    std::vector<Mat4> matrices_;
    std::unordered_map<Uuid, std::uint16_t, UuidHash> slots_;
    int truncatedVertices_ = 0;
};

} // namespace umeshcore
