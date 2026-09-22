#include "umeshcore/Serialization/Json.h"

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <sstream>

namespace umeshcore {

JsonValue JsonValue::makeBool(bool v) {
    JsonValue j;
    j.type_ = Type::Bool;
    j.bool_ = v;
    return j;
}

JsonValue JsonValue::makeNumber(double v) {
    JsonValue j;
    j.type_ = Type::Number;
    j.number_ = v;
    return j;
}

JsonValue JsonValue::makeString(std::string v) {
    JsonValue j;
    j.type_ = Type::String;
    j.string_ = std::move(v);
    return j;
}

JsonValue JsonValue::makeArray(Array v) {
    JsonValue j;
    j.type_ = Type::Array;
    j.array_ = std::move(v);
    return j;
}

JsonValue JsonValue::makeObject(Object v) {
    JsonValue j;
    j.type_ = Type::Object;
    j.object_ = std::move(v);
    return j;
}

void JsonValue::requireType(Type expected, const char* what) const {
    if (type_ != expected) throw std::runtime_error(std::string("JsonValue: not a ") + what);
}

bool JsonValue::asBool() const {
    requireType(Type::Bool, "bool");
    return bool_;
}

double JsonValue::asDouble() const {
    requireType(Type::Number, "number");
    return number_;
}

const std::string& JsonValue::asString() const {
    requireType(Type::String, "string");
    return string_;
}

const JsonValue::Array& JsonValue::asArray() const {
    requireType(Type::Array, "array");
    return array_;
}

JsonValue::Array& JsonValue::asArray() {
    requireType(Type::Array, "array");
    return array_;
}

const JsonValue::Object& JsonValue::asObject() const {
    requireType(Type::Object, "object");
    return object_;
}

JsonValue::Object& JsonValue::asObject() {
    requireType(Type::Object, "object");
    return object_;
}

void JsonValue::set(const std::string& key, JsonValue value) {
    requireType(Type::Object, "object");
    object_[key] = std::move(value);
}

const JsonValue* JsonValue::find(const std::string& key) const {
    requireType(Type::Object, "object");
    const auto it = object_.find(key);
    return it == object_.end() ? nullptr : &it->second;
}

JsonValue JsonValue::valueOr(const std::string& key, JsonValue fallback) const {
    const JsonValue* v = find(key);
    return (v == nullptr || v->isNull()) ? fallback : *v;
}

void JsonValue::push_back(JsonValue value) {
    requireType(Type::Array, "array");
    array_.push_back(std::move(value));
}

namespace {

void appendEscapedString(std::string& out, const std::string& s) {
    out.push_back('"');
    for (unsigned char c : s) {
        switch (c) {
            case '"': out += "\\\""; break;
            case '\\': out += "\\\\"; break;
            case '\b': out += "\\b"; break;
            case '\f': out += "\\f"; break;
            case '\n': out += "\\n"; break;
            case '\r': out += "\\r"; break;
            case '\t': out += "\\t"; break;
            default:
                if (c < 0x20) {
                    char buf[8];
                    std::snprintf(buf, sizeof(buf), "\\u%04x", c);
                    out += buf;
                } else {
                    // Left as raw UTF-8 (valid input is assumed already
                    // UTF-8-encoded) -- see Json.h's file header on why
                    // matching Swift's default '/'-escaping isn't a goal.
                    out.push_back(static_cast<char>(c));
                }
        }
    }
    out.push_back('"');
}

void appendNumber(std::string& out, double v) {
    if (std::isnan(v) || std::isinf(v)) {
        // Not valid JSON; write 0 rather than emit invalid output. Nothing
        // in this port's serializable data is expected to be non-finite.
        out += "0";
        return;
    }
    // An integral value (including large magnitudes, e.g. a frame count or
    // a UUID-derived hash component stored as a JSON number) is written
    // without a trailing ".0" so it round-trips cleanly through readers
    // that check `is this an integer literal`.
    if (v == std::floor(v) && std::fabs(v) < 1e15) {
        char buf[32];
        std::snprintf(buf, sizeof(buf), "%.0f", v);
        out += buf;
        return;
    }
    char buf[32];
    std::snprintf(buf, sizeof(buf), "%.9g", v);
    out += buf;
}

void dumpValue(const JsonValue& v, std::string& out, bool pretty, int depth) {
    const std::string indent = pretty ? std::string(static_cast<std::size_t>(depth) * 2, ' ') : std::string();
    const std::string childIndent = pretty ? std::string(static_cast<std::size_t>(depth + 1) * 2, ' ') : std::string();
    const std::string nl = pretty ? "\n" : "";
    const std::string sep = pretty ? ": " : ":";

    switch (v.type()) {
        case JsonValue::Type::Null:
            out += "null";
            return;
        case JsonValue::Type::Bool:
            out += v.asBool() ? "true" : "false";
            return;
        case JsonValue::Type::Number:
            appendNumber(out, v.asDouble());
            return;
        case JsonValue::Type::String:
            appendEscapedString(out, v.asString());
            return;
        case JsonValue::Type::Array: {
            const auto& arr = v.asArray();
            if (arr.empty()) {
                out += "[]";
                return;
            }
            out += "[";
            out += nl;
            for (std::size_t i = 0; i < arr.size(); ++i) {
                out += childIndent;
                dumpValue(arr[i], out, pretty, depth + 1);
                if (i + 1 < arr.size()) out += ",";
                out += nl;
            }
            out += indent;
            out += "]";
            return;
        }
        case JsonValue::Type::Object: {
            const auto& obj = v.asObject();
            if (obj.empty()) {
                out += "{}";
                return;
            }
            out += "{";
            out += nl;
            std::size_t i = 0;
            for (const auto& [key, value] : obj) {
                out += childIndent;
                appendEscapedString(out, key);
                out += sep;
                dumpValue(value, out, pretty, depth + 1);
                if (++i < obj.size()) out += ",";
                out += nl;
            }
            out += indent;
            out += "}";
            return;
        }
    }
}

// --- Parser ---

class Parser {
public:
    explicit Parser(const std::string& text) : text_(text) {}

    JsonValue parseDocument() {
        skipWhitespace();
        JsonValue v = parseValue();
        skipWhitespace();
        if (pos_ != text_.size()) fail("trailing data after JSON document");
        return v;
    }

private:
    const std::string& text_;
    std::size_t pos_ = 0;

    [[noreturn]] void fail(const std::string& message) const {
        throw std::runtime_error("JsonValue::parse: " + message + " at offset " + std::to_string(pos_));
    }

    bool atEnd() const { return pos_ >= text_.size(); }
    char peek() const {
        if (atEnd()) fail("unexpected end of input");
        return text_[pos_];
    }
    char advance() { return text_[pos_++]; }

    void skipWhitespace() {
        while (!atEnd()) {
            const char c = text_[pos_];
            if (c == ' ' || c == '\t' || c == '\n' || c == '\r') {
                ++pos_;
            } else {
                break;
            }
        }
    }

    void expect(char c) {
        if (atEnd() || text_[pos_] != c) fail(std::string("expected '") + c + "'");
        ++pos_;
    }

    bool consumeLiteral(const char* literal) {
        const std::size_t len = std::strlen(literal);
        if (text_.compare(pos_, len, literal) == 0) {
            pos_ += len;
            return true;
        }
        return false;
    }

    JsonValue parseValue() {
        skipWhitespace();
        if (atEnd()) fail("unexpected end of input");
        const char c = peek();
        if (c == '{') return parseObject();
        if (c == '[') return parseArray();
        if (c == '"') return JsonValue::makeString(parseString());
        if (c == 't' || c == 'f') return parseBool();
        if (c == 'n') return parseNull();
        if (c == '-' || (c >= '0' && c <= '9')) return parseNumber();
        fail("unexpected character");
    }

    JsonValue parseObject() {
        expect('{');
        JsonValue::Object obj;
        skipWhitespace();
        if (!atEnd() && peek() == '}') {
            advance();
            return JsonValue::makeObject(std::move(obj));
        }
        while (true) {
            skipWhitespace();
            if (atEnd() || peek() != '"') fail("expected string key");
            std::string key = parseString();
            skipWhitespace();
            expect(':');
            JsonValue value = parseValue();
            obj[std::move(key)] = std::move(value);
            skipWhitespace();
            if (!atEnd() && peek() == ',') {
                advance();
                continue;
            }
            expect('}');
            break;
        }
        return JsonValue::makeObject(std::move(obj));
    }

    JsonValue parseArray() {
        expect('[');
        JsonValue::Array arr;
        skipWhitespace();
        if (!atEnd() && peek() == ']') {
            advance();
            return JsonValue::makeArray(std::move(arr));
        }
        while (true) {
            arr.push_back(parseValue());
            skipWhitespace();
            if (!atEnd() && peek() == ',') {
                advance();
                continue;
            }
            expect(']');
            break;
        }
        return JsonValue::makeArray(std::move(arr));
    }

    static void appendUtf8(std::string& out, unsigned int codepoint) {
        if (codepoint <= 0x7F) {
            out.push_back(static_cast<char>(codepoint));
        } else if (codepoint <= 0x7FF) {
            out.push_back(static_cast<char>(0xC0 | (codepoint >> 6)));
            out.push_back(static_cast<char>(0x80 | (codepoint & 0x3F)));
        } else if (codepoint <= 0xFFFF) {
            out.push_back(static_cast<char>(0xE0 | (codepoint >> 12)));
            out.push_back(static_cast<char>(0x80 | ((codepoint >> 6) & 0x3F)));
            out.push_back(static_cast<char>(0x80 | (codepoint & 0x3F)));
        } else {
            out.push_back(static_cast<char>(0xF0 | (codepoint >> 18)));
            out.push_back(static_cast<char>(0x80 | ((codepoint >> 12) & 0x3F)));
            out.push_back(static_cast<char>(0x80 | ((codepoint >> 6) & 0x3F)));
            out.push_back(static_cast<char>(0x80 | (codepoint & 0x3F)));
        }
    }

    unsigned int parseHex4() {
        if (pos_ + 4 > text_.size()) fail("truncated \\u escape");
        unsigned int value = 0;
        for (int i = 0; i < 4; ++i) {
            const char c = text_[pos_ + static_cast<std::size_t>(i)];
            value <<= 4;
            if (c >= '0' && c <= '9') value |= static_cast<unsigned int>(c - '0');
            else if (c >= 'a' && c <= 'f') value |= static_cast<unsigned int>(c - 'a' + 10);
            else if (c >= 'A' && c <= 'F') value |= static_cast<unsigned int>(c - 'A' + 10);
            else fail("invalid \\u escape");
        }
        pos_ += 4;
        return value;
    }

    std::string parseString() {
        expect('"');
        std::string out;
        while (true) {
            if (atEnd()) fail("unterminated string");
            const char c = advance();
            if (c == '"') break;
            if (c == '\\') {
                if (atEnd()) fail("unterminated escape");
                const char esc = advance();
                switch (esc) {
                    case '"': out.push_back('"'); break;
                    case '\\': out.push_back('\\'); break;
                    case '/': out.push_back('/'); break;
                    case 'b': out.push_back('\b'); break;
                    case 'f': out.push_back('\f'); break;
                    case 'n': out.push_back('\n'); break;
                    case 'r': out.push_back('\r'); break;
                    case 't': out.push_back('\t'); break;
                    case 'u': {
                        unsigned int codepoint = parseHex4();
                        // Combine a UTF-16 surrogate pair into one codepoint.
                        if (codepoint >= 0xD800 && codepoint <= 0xDBFF && pos_ + 1 < text_.size() &&
                            text_[pos_] == '\\' && text_[pos_ + 1] == 'u') {
                            const std::size_t save = pos_;
                            pos_ += 2;
                            const unsigned int low = parseHex4();
                            if (low >= 0xDC00 && low <= 0xDFFF) {
                                codepoint = 0x10000 + ((codepoint - 0xD800) << 10) + (low - 0xDC00);
                            } else {
                                pos_ = save; // Not a low surrogate; leave it for the next escape.
                            }
                        }
                        appendUtf8(out, codepoint);
                        break;
                    }
                    default: fail("invalid escape character");
                }
            } else {
                out.push_back(c);
            }
        }
        return out;
    }

    JsonValue parseBool() {
        if (consumeLiteral("true")) return JsonValue::makeBool(true);
        if (consumeLiteral("false")) return JsonValue::makeBool(false);
        fail("invalid literal");
    }

    JsonValue parseNull() {
        if (consumeLiteral("null")) return JsonValue::makeNull();
        fail("invalid literal");
    }

    JsonValue parseNumber() {
        const std::size_t start = pos_;
        if (!atEnd() && peek() == '-') advance();
        if (atEnd() || !(peek() >= '0' && peek() <= '9')) fail("invalid number");
        while (!atEnd() && peek() >= '0' && peek() <= '9') advance();
        if (!atEnd() && peek() == '.') {
            advance();
            if (atEnd() || !(peek() >= '0' && peek() <= '9')) fail("invalid number");
            while (!atEnd() && peek() >= '0' && peek() <= '9') advance();
        }
        if (!atEnd() && (peek() == 'e' || peek() == 'E')) {
            advance();
            if (!atEnd() && (peek() == '+' || peek() == '-')) advance();
            if (atEnd() || !(peek() >= '0' && peek() <= '9')) fail("invalid number");
            while (!atEnd() && peek() >= '0' && peek() <= '9') advance();
        }
        const std::string token = text_.substr(start, pos_ - start);
        return JsonValue::makeNumber(std::strtod(token.c_str(), nullptr));
    }
};

} // namespace

std::string JsonValue::dump(bool prettyPrinted) const {
    std::string out;
    dumpValue(*this, out, prettyPrinted, 0);
    return out;
}

JsonValue JsonValue::parse(const std::string& text) {
    Parser parser(text);
    return parser.parseDocument();
}

} // namespace umeshcore
