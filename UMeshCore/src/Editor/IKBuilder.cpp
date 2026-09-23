#include "umeshcore/Editor/IKBuilder.h"

#include <algorithm>
#include <unordered_set>

#include "umeshcore/Core/NaturalCompare.h"

namespace umeshcore {

std::vector<IKBuilderProblem> IKBuilderValidation::blocking() const {
    std::vector<IKBuilderProblem> out;
    for (const auto& p : problems) {
        if (p.isBlocking) out.push_back(p);
    }
    return out;
}

std::vector<IKBuilderProblem> IKBuilderValidation::advisory() const {
    std::vector<IKBuilderProblem> out;
    for (const auto& p : problems) {
        if (!p.isBlocking) out.push_back(p);
    }
    return out;
}

bool IKBuilderValidation::canCreate() const {
    for (const auto& p : problems) {
        if (p.isBlocking) return false;
    }
    return true;
}

namespace IKBuilderRules {

namespace {

// Name order with an id tie-break, so equal names are still a total order.
bool byName(const Bone& a, const Bone& b) {
    const int c = naturalCompare(a.name, b.name);
    if (c != 0) return c < 0;
    return a.id < b.id;
}

std::string nameOf(Uuid id, const Skeleton& skeleton) {
    const Bone* b = skeleton.bone(id);
    return b != nullptr ? b->name : "?";
}

} // namespace

std::optional<std::vector<Uuid>> path(Uuid ancestor, Uuid descendant, const Skeleton& skeleton) {
    if (ancestor == descendant) return std::vector<Uuid>{ancestor};
    std::vector<Uuid> reversed{descendant};
    const Bone* start = skeleton.bone(descendant);
    std::optional<Uuid> current = start != nullptr ? start->parentID : std::nullopt;
    int safety = 0;
    while (current.has_value() && safety < 256) {
        reversed.push_back(*current);
        if (*current == ancestor) {
            std::reverse(reversed.begin(), reversed.end());
            return reversed;
        }
        const Bone* b = skeleton.bone(*current);
        current = b != nullptr ? b->parentID : std::nullopt;
        safety += 1;
    }
    return std::nullopt;
}

bool isDescendant(Uuid candidate, Uuid root, const Skeleton& skeleton) {
    return path(root, candidate, skeleton).has_value();
}

std::vector<Uuid> addToChain(Uuid boneID, const std::vector<Uuid>& chain, const Skeleton& skeleton) {
    auto found = std::find(chain.begin(), chain.end(), boneID);
    if (found != chain.end()) return std::vector<Uuid>(chain.begin(), found);
    if (chain.empty()) return {boneID};
    const Uuid first = chain.front(), last = chain.back();

    if (auto downward = path(last, boneID, skeleton)) {
        std::vector<Uuid> out = chain;
        out.insert(out.end(), downward->begin() + 1, downward->end());
        return out;
    }
    if (auto upward = path(boneID, first, skeleton)) {
        std::vector<Uuid> out(upward->begin(), upward->end() - 1);
        out.insert(out.end(), chain.begin(), chain.end());
        return out;
    }
    std::vector<Uuid> out = chain;
    out.push_back(boneID);
    return out;
}

std::vector<IKBuilderOrderedBone> hierarchicalOrder(const Skeleton& skeleton) {
    std::vector<IKBuilderOrderedBone> out;
    std::unordered_set<Uuid, UuidHash> visited;

    // An explicit stack rather than recursion, so a deep rig cannot run the
    // call stack out; children are pushed in reverse so they pop in name
    // order, which is the order the recursive Swift visits them in.
    const auto visitFrom = [&](Uuid start, int startDepth) {
        std::vector<std::pair<Uuid, int>> stack{{start, startDepth}};
        while (!stack.empty()) {
            const auto [id, depth] = stack.back();
            stack.pop_back();
            const Bone* bone = skeleton.bone(id);
            if (bone == nullptr || !visited.insert(id).second) continue;
            out.push_back(IKBuilderOrderedBone{*bone, depth});
            std::vector<Bone> children;
            for (Uuid child : skeleton.childrenOf(id)) {
                if (const Bone* c = skeleton.bone(child)) children.push_back(*c);
            }
            std::sort(children.begin(), children.end(), byName);
            for (auto it = children.rbegin(); it != children.rend(); ++it) {
                stack.emplace_back(it->id, depth + 1);
            }
        }
    };

    for (Uuid root : skeleton.rootIDs) visitFrom(root, 0);
    std::vector<Bone> all;
    all.reserve(skeleton.bones().size());
    for (const auto& entry : skeleton.bones()) all.push_back(entry.second);
    std::sort(all.begin(), all.end(), byName);
    for (const Bone& b : all) visitFrom(b.id, 0);
    return out;
}

IKBuilderValidation validate(const IKBuilderDraft& draft, const Skeleton& skeleton) {
    IKBuilderValidation result;
    auto& problems = result.problems;

    if (draft.chain.empty()) {
        problems.push_back({"Add at least one bone to the chain.", true});
    }

    for (std::size_t index = 1; index < draft.chain.size(); ++index) {
        const Uuid previous = draft.chain[index - 1];
        const Uuid current = draft.chain[index];
        const Bone* bone = skeleton.bone(current);
        const std::optional<Uuid> parent = bone != nullptr ? bone->parentID : std::nullopt;
        if (!(parent.has_value() && *parent == previous)) {
            const std::string parentName = parent.has_value() ? nameOf(*parent, skeleton) : "none";
            problems.push_back(
                {"“" + nameOf(current, skeleton) + "” does not continue the chain — its parent is “" +
                     parentName + "”, not “" + nameOf(previous, skeleton) + "”.",
                 true});
        }
    }

    if (!draft.targetID.has_value()) {
        problems.push_back({"Choose the target bone the chain should reach for.", true});
        return result;
    }
    const Uuid targetID = *draft.targetID;

    if (std::find(draft.chain.begin(), draft.chain.end(), targetID) != draft.chain.end()) {
        problems.push_back(
            {"“" + nameOf(targetID, skeleton) +
                 "” is part of the chain. A chain cannot reach for one of its own bones.",
             true});
    } else if (!draft.chain.empty() && isDescendant(targetID, draft.chain.back(), skeleton)) {
        // The solver would move the chain, which moves the target, which
        // moves the chain. The Unity runtime refuses this outright.
        problems.push_back(
            {"“" + nameOf(targetID, skeleton) +
                 "” is a child of the chain, so moving the chain moves the target. Parent it outside the chain.",
             true});
    }

    if (draft.chain.size() > 2) {
        problems.push_back(
            {std::to_string(draft.chain.size()) +
                 "-bone chains solve with FABRIK (iterative). One and two bones solve exactly.",
             false});
    }
    if (draft.mix < 0.999f) {
        problems.push_back({"Mix is below 100%, so the constraint will only partly override the pose.", false});
    }
    return result;
}

std::string summary(const IKBuilderDraft& draft, const Skeleton& skeleton) {
    const Bone* target = draft.targetID.has_value() ? skeleton.bone(*draft.targetID) : nullptr;
    if (target == nullptr) return "Pick a chain and a target to see what this will do.";
    const Bone* tip = draft.chain.empty() ? nullptr : skeleton.bone(draft.chain.back());
    if (tip == nullptr) return "Pick the bones that should bend.";
    const std::string rootName = nameOf(draft.chain.front(), skeleton);
    const std::string chainText =
        draft.chain.size() == 1
            ? "“" + rootName + "”"
            : "“" + rootName + "” → “" + tip->name + "” (" +
                  std::to_string(draft.chain.size()) + " bones)";
    return chainText + " will bend so its tip reaches “" + target->name + "”.";
}

} // namespace IKBuilderRules

} // namespace umeshcore
