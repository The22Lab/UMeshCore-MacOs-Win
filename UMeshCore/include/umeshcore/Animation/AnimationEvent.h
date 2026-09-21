#pragma once

// 1:1 port of `Data/AnimationEvent.swift`.

#include <optional>
#include <string>

#include "umeshcore/Core/Uuid.h"

namespace umeshcore {

// A named event the rig can raise from an animation. The definition lives
// on the skeleton and carries the default payload; individual keyframes on
// the timeline may override it.
struct AnimationEvent {
    Uuid id = Uuid::generate();
    std::string name;

    int defaultInt = 0;
    float defaultFloat = 0.0f;
    std::string defaultString;

    // Optional audio cue, stored as a path so a project stays portable.
    std::string audioPath;
    float volume = 1.0f;
    float balance = 0.0f;

    bool operator==(const AnimationEvent& o) const {
        return id == o.id && name == o.name && defaultInt == o.defaultInt &&
               defaultFloat == o.defaultFloat && defaultString == o.defaultString &&
               audioPath == o.audioPath && volume == o.volume && balance == o.balance;
    }
};

// The payload carried by a single event keyframe. Each field is optional so
// a keyframe can say "use the definition's default" rather than duplicate
// it.
struct AnimationEventPayload {
    std::optional<int> intValue;
    std::optional<float> floatValue;
    std::optional<std::string> stringValue;

    bool overridesAnything() const {
        return intValue.has_value() || floatValue.has_value() || stringValue.has_value();
    }

    struct Resolved {
        int intValue;
        float floatValue;
        std::string stringValue;
    };

    // Resolve against a definition, filling in whatever this payload leaves
    // open.
    Resolved resolved(const AnimationEvent& definition) const {
        return Resolved{
            intValue.value_or(definition.defaultInt), floatValue.value_or(definition.defaultFloat),
            stringValue.value_or(definition.defaultString)};
    }

    bool operator==(const AnimationEventPayload& o) const {
        return intValue == o.intValue && floatValue == o.floatValue && stringValue == o.stringValue;
    }
};

// An event that playback has crossed, reported to whoever is listening.
struct FiredAnimationEvent {
    Uuid eventID;
    std::string name;
    int frame = 0;
    int intValue = 0;
    float floatValue = 0.0f;
    std::string stringValue;
};

} // namespace umeshcore
