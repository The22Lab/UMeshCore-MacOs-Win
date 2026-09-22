// Tests for Serialization/Json.h -- new code, not a port (see the file
// header: Swift's JSONEncoder/JSONDecoder + Codable has no portable C++
// equivalent, and this project's "no external dependencies" principle
// rules out adopting a third-party JSON library). Round-trips values
// through dump()/parse() and checks the parser against hand-written JSON
// text and its error paths.

#include "umeshcore/Serialization/Json.h"

#include "TestHarness.h"

using namespace umeshcore;

static void testPrimitivesRoundTrip() {
    UM_CHECK(JsonValue::parse("null").isNull());
    UM_CHECK(JsonValue::parse("true").asBool() == true);
    UM_CHECK(JsonValue::parse("false").asBool() == false);
    UM_CHECK_NEAR(JsonValue::parse("42").asDouble(), 42.0, 1e-9);
    UM_CHECK_NEAR(JsonValue::parse("-3.5").asDouble(), -3.5, 1e-9);
    UM_CHECK_NEAR(JsonValue::parse("1.5e2").asDouble(), 150.0, 1e-9);
    UM_CHECK(JsonValue::parse("\"hello\"").asString() == "hello");
}

static void testIntegersDumpWithoutTrailingZero() {
    UM_CHECK(JsonValue::makeNumber(42.0).dump(false) == "42");
    UM_CHECK(JsonValue::makeNumber(-7.0).dump(false) == "-7");
}

static void testStringEscaping() {
    const std::string original = "line1\nline2\t\"quoted\"\\backslash";
    const JsonValue v = JsonValue::makeString(original);
    const std::string dumped = v.dump(false);
    const JsonValue reparsed = JsonValue::parse(dumped);
    UM_CHECK(reparsed.asString() == original);
}

static void testUnicodeEscapeAndSurrogatePair() {
    // é = 'é' (2-byte UTF-8), and a surrogate pair for an emoji
    // outside the BMP (U+1F600 GRINNING FACE, encoded as 😀).
    const JsonValue v = JsonValue::parse("\"caf\\u00e9 \\uD83D\\uDE00\"");
    const std::string& s = v.asString();
    // UTF-8 for U+00E9 is 0xC3 0xA9; for U+1F600 is 0xF0 0x9F 0x98 0x80.
    UM_CHECK(s.find("caf\xC3\xA9") == 0);
    UM_CHECK(s.find("\xF0\x9F\x98\x80") != std::string::npos);
}

static void testArrayRoundTrip() {
    JsonValue::Array arr;
    arr.push_back(JsonValue::makeNumber(1));
    arr.push_back(JsonValue::makeNumber(2));
    arr.push_back(JsonValue::makeString("three"));
    const JsonValue v = JsonValue::makeArray(std::move(arr));

    const std::string dumped = v.dump(true);
    const JsonValue reparsed = JsonValue::parse(dumped);
    UM_CHECK(reparsed.isArray());
    UM_CHECK(reparsed.asArray().size() == 3);
    UM_CHECK_NEAR(reparsed.asArray()[0].asDouble(), 1.0, 1e-9);
    UM_CHECK(reparsed.asArray()[2].asString() == "three");
}

static void testEmptyArrayAndObjectDumpCompactly() {
    UM_CHECK(JsonValue::makeArray().dump(true) == "[]");
    UM_CHECK(JsonValue::makeObject().dump(true) == "{}");
}

static void testObjectKeysAreSortedOnDump() {
    JsonValue obj = JsonValue::makeObject();
    obj.set("zebra", JsonValue::makeNumber(1));
    obj.set("apple", JsonValue::makeNumber(2));
    obj.set("mango", JsonValue::makeNumber(3));

    const std::string dumped = obj.dump(false);
    const std::size_t appleIdx = dumped.find("apple");
    const std::size_t mangoIdx = dumped.find("mango");
    const std::size_t zebraIdx = dumped.find("zebra");
    UM_CHECK(appleIdx != std::string::npos && mangoIdx != std::string::npos && zebraIdx != std::string::npos);
    UM_CHECK(appleIdx < mangoIdx);
    UM_CHECK(mangoIdx < zebraIdx);
}

static void testNestedObjectRoundTrip() {
    JsonValue root = JsonValue::makeObject();
    root.set("name", JsonValue::makeString("hero_body"));
    root.set("hidden", JsonValue::makeBool(false));

    JsonValue position = JsonValue::makeObject();
    position.set("x", JsonValue::makeNumber(1.5));
    position.set("y", JsonValue::makeNumber(-2.25));
    root.set("position", position);

    JsonValue::Array tags;
    tags.push_back(JsonValue::makeString("bone"));
    tags.push_back(JsonValue::makeString("root"));
    root.set("tags", JsonValue::makeArray(std::move(tags)));

    for (bool pretty : {true, false}) {
        const std::string dumped = root.dump(pretty);
        const JsonValue reparsed = JsonValue::parse(dumped);
        UM_CHECK(reparsed.find("name")->asString() == "hero_body");
        UM_CHECK(reparsed.find("hidden")->asBool() == false);
        const JsonValue* pos = reparsed.find("position");
        UM_CHECK(pos != nullptr);
        UM_CHECK_NEAR(pos->find("x")->asDouble(), 1.5, 1e-9);
        UM_CHECK_NEAR(pos->find("y")->asDouble(), -2.25, 1e-9);
        const JsonValue* tagsBack = reparsed.find("tags");
        UM_CHECK(tagsBack != nullptr && tagsBack->asArray().size() == 2);
        UM_CHECK(tagsBack->asArray()[1].asString() == "root");
    }
}

static void testFindReturnsNullptrForMissingKey() {
    const JsonValue obj = JsonValue::makeObject();
    UM_CHECK(obj.find("missing") == nullptr);
}

static void testValueOrMirrorsDecodeIfPresentFallback() {
    JsonValue obj = JsonValue::makeObject();
    obj.set("present", JsonValue::makeNumber(7));
    obj.set("explicitNull", JsonValue::makeNull());

    // Present -> its own value.
    UM_CHECK_NEAR(obj.valueOr("present", JsonValue::makeNumber(-1)).asDouble(), 7.0, 1e-9);
    // Present but null -> fallback (matches `decodeIfPresent(...) ?? default`).
    UM_CHECK_NEAR(obj.valueOr("explicitNull", JsonValue::makeNumber(-1)).asDouble(), -1.0, 1e-9);
    // Missing entirely -> fallback.
    UM_CHECK_NEAR(obj.valueOr("absent", JsonValue::makeNumber(-1)).asDouble(), -1.0, 1e-9);
}

static void testWrongTypeAccessThrows() {
    bool threw = false;
    try {
        (void)JsonValue::makeNumber(1).asString();
    } catch (const std::runtime_error&) {
        threw = true;
    }
    UM_CHECK(threw);
}

static void testMalformedJsonThrows() {
    for (const char* bad : {"", "{", "[1, 2", "{\"a\":}", "tru", "\"unterminated", "{\"a\" 1}"}) {
        bool threw = false;
        try {
            (void)JsonValue::parse(bad);
        } catch (const std::runtime_error&) {
            threw = true;
        }
        UM_CHECK(threw);
    }
}

static void testTrailingDataThrows() {
    bool threw = false;
    try {
        (void)JsonValue::parse("{} garbage");
    } catch (const std::runtime_error&) {
        threw = true;
    }
    UM_CHECK(threw);
}

static void testWhitespaceIsIgnoredBetweenTokens() {
    const JsonValue v = JsonValue::parse("  {  \"a\"  :  [ 1 ,  2 ]  }  ");
    UM_CHECK(v.find("a")->asArray().size() == 2);
}

UM_TEST_MAIN_BEGIN()
    testPrimitivesRoundTrip();
    testIntegersDumpWithoutTrailingZero();
    testStringEscaping();
    testUnicodeEscapeAndSurrogatePair();
    testArrayRoundTrip();
    testEmptyArrayAndObjectDumpCompactly();
    testObjectKeysAreSortedOnDump();
    testNestedObjectRoundTrip();
    testFindReturnsNullptrForMissingKey();
    testValueOrMirrorsDecodeIfPresentFallback();
    testWrongTypeAccessThrows();
    testMalformedJsonThrows();
    testTrailingDataThrows();
    testWhitespaceIsIgnoredBetweenTokens();
UM_TEST_MAIN_END()
