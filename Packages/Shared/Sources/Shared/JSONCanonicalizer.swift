//
//  JSONCanonicalizer.swift
//  Shared — AgentDeck
//
//  RFC 8785 (JCS) canonical serialization for the integer-only JSON subset
//  (SPEC §9 signing rule). Rules implemented:
//   - object members sorted by key in UTF-16 code-unit order (NOT code-point
//     order — they differ between U+E000..U+FFFF and astral characters),
//   - no whitespace,
//   - string escaping identical to ECMAScript JSON.stringify: escape `"`,
//     `\`, and C0 controls (\b \t \n \f \r, others as \u00xx lowercase hex);
//     everything else emitted as raw UTF-8 (including U+2028/U+2029, DEL),
//   - integers in minimal decimal form (the subset has no floats).
//  Because the subset excludes floats, this output IS deterministic across
//  platforms — that is the whole point of the §9 integer-only rule.
//

import Foundation

extension JSONValue {
    /// RFC 8785 canonical UTF-8 encoding. This is the exact byte string the
    /// §9 Ed25519 signature covers (for the frame with `sig` absent).
    public func canonicalBytes() -> Data {
        Data(canonicalString().utf8)
    }

    /// RFC 8785 canonical string form.
    public func canonicalString() -> String {
        var output = String()
        output.reserveCapacity(128)
        writeCanonical(into: &output)
        return output
    }

    private func writeCanonical(into output: inout String) {
        switch self {
        case .null:
            output += "null"
        case .bool(let value):
            output += value ? "true" : "false"
        case .int(let value):
            output += String(value)
        case .string(let string):
            JSONCanonicalEscaping.writeEscaped(string, into: &output)
        case .array(let elements):
            output += "["
            for (index, element) in elements.enumerated() {
                if index > 0 { output += "," }
                element.writeCanonical(into: &output)
            }
            output += "]"
        case .object(let object):
            output += "{"
            // RFC 8785 §3.2.3: sort by UTF-16 code units (ECMAScript
            // Array.prototype.sort on strings), not by Unicode code point.
            let sortedKeys = object.keys.sorted { lhs, rhs in
                lhs.utf16.lexicographicallyPrecedes(rhs.utf16)
            }
            for (index, key) in sortedKeys.enumerated() {
                if index > 0 { output += "," }
                JSONCanonicalEscaping.writeEscaped(key, into: &output)
                output += ":"
                if let value = object[key] {
                    value.writeCanonical(into: &output)
                }
            }
            output += "}"
        }
    }
}

enum JSONCanonicalEscaping {
    /// Minimal escaping identical to ECMAScript JSON.stringify (RFC 8785 §3.2.2.2).
    static func writeEscaped(_ string: String, into output: inout String) {
        output += "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"":
                output += "\\\""
            case "\\":
                output += "\\\\"
            case "\u{08}":
                output += "\\b"
            case "\u{09}":
                output += "\\t"
            case "\u{0A}":
                output += "\\n"
            case "\u{0C}":
                output += "\\f"
            case "\u{0D}":
                output += "\\r"
            default:
                if scalar.value < 0x20 {
                    // Remaining C0 controls: \u00xx with lowercase hex.
                    output += "\\u00"
                    output += Self.lowercaseHexDigit((scalar.value >> 4) & 0xF)
                    output += Self.lowercaseHexDigit(scalar.value & 0xF)
                } else {
                    output.unicodeScalars.append(scalar)
                }
            }
        }
        output += "\""
    }

    private static func lowercaseHexDigit(_ nibble: UInt32) -> String {
        let digits: [String] = [
            "0", "1", "2", "3", "4", "5", "6", "7",
            "8", "9", "a", "b", "c", "d", "e", "f"
        ]
        return digits[Int(nibble)]
    }
}
