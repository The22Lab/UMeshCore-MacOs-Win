// Tests for Skin.h, ported from `Data/Skin.swift`.

#include "umeshcore/Model/Skin.h"
#include "TestHarness.h"

using namespace umeshcore;

static void testFlattenOwnAttachmentWinsOverIncluded() {
    const Uuid spriteX = Uuid::generate();
    const Uuid spriteY = Uuid::generate();
    const Uuid spriteZ = Uuid::generate();

    Skin base("base");
    base.attachments["head"] = spriteY;
    base.attachments["hat"] = spriteZ;

    Skin derived("derived");
    derived.attachments["head"] = spriteX; // overrides base's head
    derived.includedSkinIDs = {base.id};

    const std::vector<Skin> skins = {base, derived};
    const auto flattened = SkinResolver::flatten(derived.id, skins);

    UM_CHECK(flattened.at("head").has_value() && *flattened.at("head") == spriteX);
    UM_CHECK(flattened.at("hat").has_value() && *flattened.at("hat") == spriteZ);
}

static void testFlattenBreaksCycles() {
    Skin a("a");
    Skin b("b");
    a.includedSkinIDs = {b.id};
    b.includedSkinIDs = {a.id}; // cycle: a -> b -> a
    a.attachments["slot"] = Uuid::generate();

    const std::vector<Skin> skins = {a, b};
    // Must terminate (not hang) and resolve what's reachable.
    const auto flattened = SkinResolver::flatten(a.id, skins);
    UM_CHECK(flattened.contains("slot"));
}

static void testExplicitlyEmptySlotDiffersFromNoOpinion() {
    Skin s("s");
    const std::string slot = "hat";
    UM_CHECK(!s.attachment(slot).has_value()); // no opinion: outer nullopt.

    s.setAttachment(std::nullopt, slot); // deliberately empty.
    const auto a = s.attachment(slot);
    UM_CHECK(a.has_value());      // key is present now...
    UM_CHECK(!a->has_value());    // ...but the slot is explicitly empty.

    s.clearAttachment(slot);
    UM_CHECK(!s.attachment(slot).has_value()); // back to "no opinion".
}

static void testResolveUsesOverrideThenSetupThenFirstMember() {
    // Distinct IDs per slot's member set -- hiddenImageIDs is aggregated
    // across all slots, so reusing an ID across slots (shown in one,
    // hidden in another) would make a single "hidden" assertion ambiguous
    // by construction, not a bug in the resolver.
    const Uuid overrideA = Uuid::generate();
    const Uuid overrideB = Uuid::generate();
    const Uuid overrideC = Uuid::generate();
    const Uuid setupA = Uuid::generate();
    const Uuid setupB = Uuid::generate();
    const Uuid neitherA = Uuid::generate();
    const Uuid neitherC = Uuid::generate();

    Skin skin("skin");
    skin.attachments["slotWithOverride"] = overrideB;

    const std::unordered_map<std::string, std::vector<Uuid>> slotMembers = {
        {"slotWithOverride", {overrideA, overrideB, overrideC}},
        {"slotWithSetupOnly", {setupA, setupB}},
        {"slotWithNeither", {neitherA, neitherC}},
    };
    const std::unordered_map<std::string, SlotAttachment> setup = {{"slotWithSetupOnly", setupA}};

    const auto resolution =
        SkinResolver::resolve(skin.id, {skin}, slotMembers, setup);

    UM_CHECK(resolution.slots.at("slotWithOverride").has_value());
    UM_CHECK(*resolution.slots.at("slotWithOverride") == overrideB);
    UM_CHECK(resolution.hiddenImageIDs.contains(overrideA));
    UM_CHECK(resolution.hiddenImageIDs.contains(overrideC));
    UM_CHECK(!resolution.hiddenImageIDs.contains(overrideB));

    UM_CHECK(*resolution.slots.at("slotWithSetupOnly") == setupA);
    UM_CHECK(resolution.hiddenImageIDs.contains(setupB));
    UM_CHECK(!resolution.hiddenImageIDs.contains(setupA));

    // No override, no setup -> falls back to the first member.
    UM_CHECK(*resolution.slots.at("slotWithNeither") == neitherA);
}

static void testResolveLeavesSingleMemberSlotUntouched() {
    const Uuid onlyMember = Uuid::generate();
    const std::unordered_map<std::string, std::vector<Uuid>> slotMembers = {{"lonely", {onlyMember}}};
    const auto resolution = SkinResolver::resolve(std::nullopt, {}, slotMembers, {});
    UM_CHECK(*resolution.slots.at("lonely") == onlyMember);
    // A single-member slot is not a real variant point: never hidden.
    UM_CHECK(!resolution.hiddenImageIDs.contains(onlyMember));
}

static void testResolveEmptySlotHidesEveryMember() {
    const Uuid memberA = Uuid::generate();
    const Uuid memberB = Uuid::generate();

    Skin skin("skin");
    skin.setAttachment(std::nullopt, "slot"); // deliberately empty.

    const std::unordered_map<std::string, std::vector<Uuid>> slotMembers = {{"slot", {memberA, memberB}}};
    const auto resolution = SkinResolver::resolve(skin.id, {skin}, slotMembers, {});

    UM_CHECK(!resolution.slots.at("slot").has_value());
    UM_CHECK(resolution.hiddenImageIDs.contains(memberA));
    UM_CHECK(resolution.hiddenImageIDs.contains(memberB));
}

UM_TEST_MAIN_BEGIN()
    testFlattenOwnAttachmentWinsOverIncluded();
    testFlattenBreaksCycles();
    testExplicitlyEmptySlotDiffersFromNoOpinion();
    testResolveUsesOverrideThenSetupThenFirstMember();
    testResolveLeavesSingleMemberSlotUntouched();
    testResolveEmptySlotHidesEveryMember();
UM_TEST_MAIN_END()
