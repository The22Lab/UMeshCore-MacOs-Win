import Foundation

/// Which slot of the IK builder is being filled from the canvas.
enum IKBuilderSlot: String, Equatable {
    case chain
    case target
}

/// A half-finished IK constraint being authored in the builder panel.
///
/// The old flow inferred everything from the multi-selection: whichever bone
/// sat deepest in the hierarchy silently became the target. That is impossible
/// to predict from the viewport and breaks outright for the common setup
/// where the target handle is an unparented bone — it is the SHALLOWEST bone,
/// so the rule picked the wrong one every time. Here the chain and the target
/// are separate, explicit slots.
struct IKBuilderDraft: Equatable {
    var chain: [UUID] = []
    var targetID: UUID?
    /// Non-nil while the canvas is in pick mode for that slot.
    var pickingSlot: IKBuilderSlot?
    var name: String = ""
    var bendPositive: Bool = true
    var mix: Float = 1.0

    var isEmpty: Bool { chain.isEmpty && targetID == nil }
}

/// One thing wrong (or merely worth knowing) about a draft.
struct IKBuilderProblem: Identifiable, Equatable {
    /// The message doubles as the identity: two identical complaints are one
    /// complaint, and the list stays stable across re-evaluation.
    var id: String { message }
    let message: String
    /// Blocking problems prevent creation; non-blocking ones are advice.
    let isBlocking: Bool
}

struct IKBuilderValidation: Equatable {
    var problems: [IKBuilderProblem] = []

    var blocking: [IKBuilderProblem] { problems.filter { $0.isBlocking } }
    var advisory: [IKBuilderProblem] { problems.filter { !$0.isBlocking } }
    var canCreate: Bool { blocking.isEmpty }
}

enum IKBuilderRules {

    /// Bones from `ancestor` down to `descendant`, inclusive, or nil when they
    /// are not on the same branch. Walking UP from the descendant is what makes
    /// this cheap: every bone has exactly one parent, so there is nothing to
    /// search.
    static func path(from ancestor: UUID, to descendant: UUID, skeleton: Skeleton) -> [UUID]? {
        if ancestor == descendant { return [ancestor] }
        var reversed: [UUID] = [descendant]
        var current = skeleton.bone(descendant)?.parentID
        var safety = 0
        while let id = current, safety < 256 {
            reversed.append(id)
            if id == ancestor { return reversed.reversed() }
            current = skeleton.bone(id)?.parentID
            safety += 1
        }
        return nil
    }

    /// True when `candidate` is `root` or sits underneath it.
    static func isDescendant(_ candidate: UUID, of root: UUID, skeleton: Skeleton) -> Bool {
        path(from: root, to: candidate, skeleton: skeleton) != nil
    }

    /// Adds a bone to the chain the way an artist expects.
    ///
    /// Clicking the shoulder and then the hand fills in the elbow — the whole
    /// arm — instead of leaving a two-bone chain with a hole in it. Clicking a
    /// bone already in the chain removes it, so the same click undoes itself.
    static func addToChain(_ boneID: UUID, chain: [UUID], skeleton: Skeleton) -> [UUID] {
        if let index = chain.firstIndex(of: boneID) {
            // Removing an interior bone would leave a gap, so the tail goes too.
            return Array(chain.prefix(index))
        }
        guard let first = chain.first, let last = chain.last else { return [boneID] }

        // Extend downward: the new bone is below the current tip.
        if let downward = path(from: last, to: boneID, skeleton: skeleton) {
            return chain + Array(downward.dropFirst())
        }
        // Extend upward: the new bone is above the current root.
        if let upward = path(from: boneID, to: first, skeleton: skeleton) {
            return Array(upward.dropLast()) + chain
        }
        // Not on this branch at all. Appended anyway so nothing the artist did
        // disappears; validation then says exactly where the run breaks.
        return chain + [boneID]
    }

    /// One bone plus how deep it sits, for an indented picker.
    struct OrderedBone: Identifiable, Equatable {
        var id: UUID { bone.id }
        let bone: Bone
        let depth: Int
    }

    /// Bones in hierarchy order, children sorted by name.
    ///
    /// `Skeleton.orderedBones` walks a dictionary's values, so its order is not
    /// stable between runs — fine for iterating, unusable for a list a person
    /// has to find a bone in twice.
    static func hierarchicalOrder(skeleton: Skeleton) -> [OrderedBone] {
        var out: [OrderedBone] = []
        var visited = Set<UUID>()

        func visit(_ id: UUID, depth: Int) {
            guard visited.insert(id).inserted, let bone = skeleton.bone(id) else { return }
            out.append(OrderedBone(bone: bone, depth: depth))
            let children = skeleton.childrenOf(id).compactMap { skeleton.bone($0) }
            for child in children.sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) {
                visit(child.id, depth: depth + 1)
            }
        }

        for rootID in skeleton.rootIDs { visit(rootID, depth: 0) }
        // Anything unreachable from a root still has to be pickable.
        for bone in skeleton.bones.values.sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) {
            visit(bone.id, depth: 0)
        }
        return out
    }

    static func validate(_ draft: IKBuilderDraft, skeleton: Skeleton) -> IKBuilderValidation {
        var problems: [IKBuilderProblem] = []

        func name(_ id: UUID) -> String { skeleton.bone(id)?.name ?? "?" }

        if draft.chain.isEmpty {
            problems.append(IKBuilderProblem(
                message: "Add at least one bone to the chain.", isBlocking: true))
        }

        // The chain has to be one unbroken parent → child run, because the
        // solver walks it as a single limb.
        for index in 1..<max(draft.chain.count, 1) {
            let previous = draft.chain[index - 1]
            let current = draft.chain[index]
            if skeleton.bone(current)?.parentID != previous {
                let parentName = skeleton.bone(current)?.parentID.map { name($0) } ?? "none"
                problems.append(IKBuilderProblem(
                    message: "“\(name(current))” does not continue the chain — its parent is “\(parentName)”, not “\(name(previous))”.",
                    isBlocking: true))
            }
        }

        guard let targetID = draft.targetID else {
            problems.append(IKBuilderProblem(
                message: "Choose the target bone the chain should reach for.", isBlocking: true))
            return IKBuilderValidation(problems: problems)
        }

        if draft.chain.contains(targetID) {
            problems.append(IKBuilderProblem(
                message: "“\(name(targetID))” is part of the chain. A chain cannot reach for one of its own bones.",
                isBlocking: true))
        } else if let tip = draft.chain.last,
                  isDescendant(targetID, of: tip, skeleton: skeleton) {
            // The solver would move the chain, which moves the target, which
            // moves the chain. The Unity runtime refuses this outright rather
            // than looping, so catching it here keeps both sides honest.
            problems.append(IKBuilderProblem(
                message: "“\(name(targetID))” is a child of the chain, so moving the chain moves the target. Parent it outside the chain.",
                isBlocking: true))
        }

        if draft.chain.count > 2 {
            problems.append(IKBuilderProblem(
                message: "\(draft.chain.count)-bone chains solve with FABRIK (iterative). One and two bones solve exactly.",
                isBlocking: false))
        }
        if draft.mix < 0.999 {
            problems.append(IKBuilderProblem(
                message: "Mix is below 100%, so the constraint will only partly override the pose.",
                isBlocking: false))
        }

        return IKBuilderValidation(problems: problems)
    }

    /// One plain sentence describing what the finished constraint will do.
    static func summary(_ draft: IKBuilderDraft, skeleton: Skeleton) -> String {
        guard let targetID = draft.targetID, let target = skeleton.bone(targetID) else {
            return "Pick a chain and a target to see what this will do."
        }
        guard let tipID = draft.chain.last, let tip = skeleton.bone(tipID) else {
            return "Pick the bones that should bend."
        }
        let rootName = skeleton.bone(draft.chain[0])?.name ?? "?"
        let chainText = draft.chain.count == 1
            ? "“\(rootName)”"
            : "“\(rootName)” → “\(tip.name)” (\(draft.chain.count) bones)"
        return "\(chainText) will bend so its tip reaches “\(target.name)”."
    }
}
