//
//  JSONValueTests.swift
//  SharedTests — AgentDeck
//
//  Tests for the integer-only JSON model, the strict parser, and the
//  RFC 8785 (JCS) canonical serializer (SPEC §9 signing rule).
//

import Foundation
import Testing
@testable import Shared

@Suite("JSONValue model")
struct JSONValueModelTests {
    @Test("field helpers read typed values")
    func fieldHelpers() throws {
        let value: JSONValue = .object([
            ("name", .string("agentdeck")),
            ("count", .int(7)),
            ("big", .int(9_000_000_000)),
            ("flag", .bool(true)),
            ("items", .array([.string("a"), .string("b")])),
            ("opt", .null)
        ])
        #expect(try value.stringField("name") == "agentdeck")
        #expect(try value.intField("count") == 7)
        #expect(try value.u64Field("big") == 9_000_000_000)
        #expect(try value.boolField("flag") == true)
        #expect(try value.stringArrayField("items") == ["a", "b"])
        #expect(try value.optionalStringField("opt") == nil)
        #expect(try value.optionalStringField("absent") == nil)
    }

    @Test("field helpers reject wrong types and missing fields")
    func fieldHelperErrors() {
        let value: JSONValue = .object([("n", .string("not-a-number")), ("neg", .int(-1))])
        #expect(throws: JSONValueDecodingError.missingField("missing")) {
            _ = try value.stringField("missing")
        }
        #expect(throws: JSONValueDecodingError.wrongType(field: "n", expected: "integer")) {
            _ = try value.intField("n")
        }
        #expect(throws: JSONValueDecodingError.integerOutOfRange(field: "neg")) {
            _ = try value.u64Field("neg")
        }
    }

    @Test("u64 encoding rejects values above Int64.max instead of clamping")
    func u64OverflowThrows() {
        #expect(throws: JSONValueDecodingError.integerOutOfRange(field: "u64")) {
            _ = try JSONValue.u64(UInt64.max)
        }
    }

    @Test("identifier wire round-trips")
    func identifiers() throws {
        let uuid = try #require(UUID(uuidString: "11111111-2222-3333-4444-555555555555"))
        let session = SessionID(uuid: uuid)
        #expect(session.wireString == "11111111-2222-3333-4444-555555555555")
        #expect(try SessionID(jsonValue: session.toJSONValue()) == session)

        let cursor = EventCursor(sessionID: session, lastEventSequence: 42)
        let cursorJSON = try cursor.toJSONValue()
        #expect(try EventCursor(jsonValue: cursorJSON) == cursor)

        #expect(AgentIdentifier("com.example.adapter") != nil)
        #expect(AgentIdentifier("") == nil)
        #expect(AgentIdentifier("has space") == nil)
    }
}

@Suite("JCS canonical serialization (RFC 8785)")
struct JSONCanonicalizationTests {
    @Test("object keys sort in UTF-16 code-unit order, not code-point order")
    func utf16KeyOrder() {
        // U+1F600 (😀) encodes as UTF-16 lead surrogate 0xD83D, which sorts
        // BEFORE U+E000 in UTF-16 order — but AFTER it in code-point order.
        let value: JSONValue = .object([
            ("\u{1F600}", .int(1)),
            ("\u{E000}", .int(2)),
            ("z", .int(3)),
            ("aa", .int(4)),
            ("a", .int(5))
        ])
        #expect(value.canonicalString() == ##"{"a":5,"aa":4,"z":3,"😀":1,""## + "\u{E000}" + ##"":2}"##)
    }

    @Test("escaping is minimal per ECMAScript JSON.stringify")
    func minimalEscaping() {
        let value: JSONValue = .object([
            ("s", .string("q\"bs\\sl/\u{08}\u{09}\u{0A}\u{0C}\u{0D}\u{01}\u{1F}\u{7F}\u{2028}\u{2029}é😀"))
        ])
        // NUL–1F: escaped (named or \u00xx lowercase). DEL, U+2028, U+2029,
        // non-ASCII, forward slash: raw UTF-8.
        #expect(value.canonicalString()
            == "{\"s\":\"q\\\"bs\\\\sl/\\b\\t\\n\\f\\r\\u0001\\u001f\u{7F}\u{2028}\u{2029}é😀\"}")
    }

    @Test("integers serialize minimally")
    func integerForms() {
        #expect(JSONValue.int(0).canonicalString() == "0")
        #expect(JSONValue.int(-5).canonicalString() == "-5")
        #expect(JSONValue.int(Int64.max).canonicalString() == "9223372036854775807")
        #expect(JSONValue.int(Int64.min).canonicalString() == "-9223372036854775808")
    }

    @Test("nested structures serialize without whitespace")
    func nested() {
        let value: JSONValue = .object([
            ("outer", .object([("b", .array([.int(-5), .bool(true), .null])), ("a", .string(""))])),
            ("empty", .object([:])),
            ("list", .array([]))
        ])
        #expect(value.canonicalString() == #"{"empty":{},"list":[],"outer":{"a":"","b":[-5,true,null]}}"#)
    }

    @Test("canonical output parses back to the identical value")
    func canonicalRoundTrip() throws {
        let value: JSONValue = .object([
            ("unicode", .string("mixed é😀\u{2028}\u{0} text")),
            ("ints", .array([.int(0), .int(-1), .int(Int64.max), .int(Int64.min)])),
            ("deep", .array([.object([("x", .array([.array([.bool(false)])]))])]))
        ])
        #expect(try JSONParser.parse(value.canonicalString()) == value)
    }
}

@Suite("Strict integer-only parser")
struct JSONParserTests {
    @Test("parses the full subset")
    func fullSubset() throws {
        let text = #" { "a" : [1, -2, 9223372036854775807], "b": {"c": "xAé"}, "d": true, "e": false, "f": null } "#
        let parsed = try JSONParser.parse(text)
        #expect(parsed == .object([
            ("a", .array([.int(1), .int(-2), .int(Int64.max)])),
            ("b", .object([("c", .string("xAé"))])),
            ("d", .bool(true)),
            ("e", .bool(false)),
            ("f", .null)
        ]))
    }

    @Test("parses escapes and surrogate pairs")
    func escapes() throws {
        #expect(try JSONParser.parse(#""😀""#) == .string("😀"))
        #expect(try JSONParser.parse(#""aAb""#) == .string("aAb"))
        // JSON text: "\/\b\f\n\r\t\"" (quote, escaped slash, named escapes, escaped quote, quote).
        #expect(try JSONParser.parse("\"\\/\\b\\f\\n\\r\\t\\\"\"") == .string("/\u{08}\u{0C}\n\r\t\""))
    }

    @Test("rejects every float form — the wire has no floats")
    func rejectsFloats() {
        for text in ["1.5", "1e3", "1E3", "-0.5", "2.", "[1.0]", "{\"x\":1e-2}"] {
            #expect(throws: JSONParseError.self, "\(text) must not parse") {
                _ = try JSONParser.parse(text)
            }
        }
    }

    @Test("rejects malformed numbers and Int64 overflow")
    func rejectsBadNumbers() {
        for text in ["01", "-", "+1", "9223372036854775808", "-9223372036854775809", "--1"] {
            #expect(throws: JSONParseError.self, "\(text) must not parse") {
                _ = try JSONParser.parse(text)
            }
        }
    }

    @Test("rejects duplicate object keys")
    func rejectsDuplicateKeys() {
        #expect(throws: JSONParseError.duplicateKey(offset: 7, "a")) {
            _ = try JSONParser.parse(#"{"a":1,"a":2}"#)
        }
    }

    @Test("rejects lone surrogates")
    func rejectsLoneSurrogates() {
        for text in [#""\uD800""#, #""\uDC00""#, #""\uD800\u0041""#, #""\uD800\uD800\uDC00""#] {
            #expect(throws: JSONParseError.self, "\(text) must not parse") {
                _ = try JSONParser.parse(text)
            }
        }
    }

    @Test("rejects unescaped control characters and bad escapes")
    func rejectsBadStrings() {
        #expect(throws: JSONParseError.unescapedControlCharacter(offset: 1)) {
            _ = try JSONParser.parse("\"\u{01}\"")
        }
        #expect(throws: JSONParseError.self) { _ = try JSONParser.parse(#""\x""#) }
        #expect(throws: JSONParseError.self) { _ = try JSONParser.parse(#""\u12""#) }
        #expect(throws: JSONParseError.self) { _ = try JSONParser.parse(#""unterminated"#) }
        #expect(throws: JSONParseError.self) { _ = try JSONParser.parse(#""\uAB❌""#) }
    }

    @Test("rejects trailing content, empty input, invalid UTF-8")
    func rejectsGarbage() {
        #expect(throws: JSONParseError.trailingContent(offset: 5)) {
            _ = try JSONParser.parse("null x")
        }
        #expect(throws: JSONParseError.unexpectedEnd(offset: 0)) {
            _ = try JSONParser.parse("")
        }
        #expect(throws: JSONParseError.invalidUTF8) {
            _ = try JSONParser.parse(Data([0xFF, 0xFE, 0x22]))
        }
        #expect(throws: JSONParseError.self) { _ = try JSONParser.parse("nul") }
        #expect(throws: JSONParseError.self) { _ = try JSONParser.parse("[1,]") }
        #expect(throws: JSONParseError.self) { _ = try JSONParser.parse("{a:1}") }
    }

    @Test("enforces the nesting depth limit")
    func depthLimit() throws {
        let deep = String(repeating: "[", count: JSONParser.maximumDepth + 5)
        #expect(throws: JSONParseError.depthLimitExceeded(limit: JSONParser.maximumDepth)) {
            _ = try JSONParser.parse(deep)
        }
        // Exactly at the limit still parses.
        let atLimit = String(repeating: "[", count: JSONParser.maximumDepth)
            + String(repeating: "]", count: JSONParser.maximumDepth)
        #expect(throws: Never.self) { _ = try JSONParser.parse(atLimit) }
    }

    @Test("parses Int64 boundary values")
    func int64Boundaries() throws {
        #expect(try JSONParser.parse("9223372036854775807") == .int(Int64.max))
        #expect(try JSONParser.parse("-9223372036854775808") == .int(Int64.min))
        #expect(try JSONParser.parse("-0") == .int(0))
    }
}
