//
//  JSONParser.swift
//  Shared — AgentDeck
//
//  Strict parser for the integer-only JSON wire subset (SPEC §9).
//  Hand-rolled on purpose: Foundation's JSONSerialization cannot guarantee
//  float-free decoding (NSNumber bridges 1 and 1.0), and the signing rule
//  requires that any float anywhere in a frame is a hard protocol error.
//

import Foundation

public enum JSONParseError: Error, Equatable {
    case emptyInput
    case unexpectedEnd(offset: Int)
    case unexpectedCharacter(offset: Int, Character)
    case invalidNumber(offset: Int, String)
    case integerOutOfRange(offset: Int)
    case invalidStringEscape(offset: Int)
    case unpairedSurrogate(offset: Int)
    case unescapedControlCharacter(offset: Int)
    case unterminatedString(offset: Int)
    case duplicateKey(offset: Int, String)
    case trailingContent(offset: Int)
    case depthLimitExceeded(limit: Int)
    case invalidUTF8
}

/// Parses the RFC 8259 JSON grammar minus non-integer numbers.
/// Any `.`, `e`, or `E` in a number is a parse error; integers must fit
/// Int64; duplicate object keys and lone surrogates are rejected.
public struct JSONParser: Sendable {
    /// Maximum nesting depth accepted (defends against stack exhaustion).
    public static let maximumDepth = 256

    private let scalars: [Unicode.Scalar]
    private var offset: Int = 0

    public init(_ data: Data) throws {
        guard let string = String(data: data, encoding: .utf8) else {
            throw JSONParseError.invalidUTF8
        }
        self.scalars = Array(string.unicodeScalars)
    }

    public init(_ string: String) {
        self.scalars = Array(string.unicodeScalars)
    }

    public static func parse(_ data: Data) throws -> JSONValue {
        var parser = try JSONParser(data)
        return try parser.parseDocument()
    }

    public static func parse(_ string: String) throws -> JSONValue {
        var parser = JSONParser(string)
        return try parser.parseDocument()
    }

    private mutating func parseDocument() throws -> JSONValue {
        skipWhitespace()
        let value = try parseValue(depth: 0)
        skipWhitespace()
        guard offset == scalars.count else {
            throw JSONParseError.trailingContent(offset: offset)
        }
        return value
    }

    private mutating func parseValue(depth: Int) throws -> JSONValue {
        guard depth <= JSONParser.maximumDepth else {
            throw JSONParseError.depthLimitExceeded(limit: JSONParser.maximumDepth)
        }
        guard offset < scalars.count else {
            throw JSONParseError.unexpectedEnd(offset: offset)
        }
        switch scalars[offset] {
        case "{": return try parseObject(depth: depth + 1)
        case "[": return try parseArray(depth: depth + 1)
        case "\"": return .string(try parseString())
        case "t": try expectLiteral("true"); return .bool(true)
        case "f": try expectLiteral("false"); return .bool(false)
        case "n": try expectLiteral("null"); return .null
        case "-", "0"..."9": return .int(try parseInteger())
        default:
            throw JSONParseError.unexpectedCharacter(offset: offset, Character(scalars[offset]))
        }
    }

    private mutating func parseObject(depth: Int) throws -> JSONValue {
        offset += 1 // consume "{"
        var object: [String: JSONValue] = [:]
        skipWhitespace()
        if peek("}") {
            offset += 1
            return .object(object)
        }
        while true {
            skipWhitespace()
            guard peek("\"") else {
                throw errorAtOffset(expected: "object key string")
            }
            let keyOffset = offset
            let key = try parseString()
            guard object[key] == nil else {
                throw JSONParseError.duplicateKey(offset: keyOffset, key)
            }
            skipWhitespace()
            guard peek(":") else {
                throw errorAtOffset(expected: "':'")
            }
            offset += 1
            skipWhitespace()
            object[key] = try parseValue(depth: depth)
            skipWhitespace()
            if peek("}") {
                offset += 1
                return .object(object)
            }
            guard peek(",") else {
                throw errorAtOffset(expected: "',' or '}'")
            }
            offset += 1
        }
    }

    private mutating func parseArray(depth: Int) throws -> JSONValue {
        offset += 1 // consume "["
        var array: [JSONValue] = []
        skipWhitespace()
        if peek("]") {
            offset += 1
            return .array(array)
        }
        while true {
            skipWhitespace()
            array.append(try parseValue(depth: depth))
            skipWhitespace()
            if peek("]") {
                offset += 1
                return .array(array)
            }
            guard peek(",") else {
                throw errorAtOffset(expected: "',' or ']'")
            }
            offset += 1
        }
    }

    private mutating func parseString() throws -> String {
        let startOffset = offset
        offset += 1 // consume opening quote
        var result = String.UnicodeScalarView()
        while offset < scalars.count {
            let scalar = scalars[offset]
            switch scalar {
            case "\"":
                offset += 1
                return String(result)
            case "\\":
                offset += 1
                guard offset < scalars.count else {
                    throw JSONParseError.unterminatedString(offset: startOffset)
                }
                let escaped = scalars[offset]
                offset += 1
                switch escaped {
                case "\"": result.append("\"")
                case "\\": result.append("\\")
                case "/": result.append("/")
                case "b": result.append("\u{08}")
                case "f": result.append("\u{0C}")
                case "n": result.append("\n")
                case "r": result.append("\r")
                case "t": result.append("\t")
                case "u":
                    let codeUnit = try parseHex4()
                    if UTF16.isLeadSurrogate(codeUnit) {
                        // Must be followed by \uXXXX trail surrogate.
                        guard offset + 1 < scalars.count,
                              scalars[offset] == "\\", scalars[offset + 1] == "u" else {
                            throw JSONParseError.unpairedSurrogate(offset: offset - 4)
                        }
                        offset += 2
                        let trail = try parseHex4()
                        guard UTF16.isTrailSurrogate(trail) else {
                            throw JSONParseError.unpairedSurrogate(offset: offset - 4)
                        }
                        // Both halves validated above; combine is total.
                        let combinedValue = 0x10000
                            + (UInt32(codeUnit) - 0xD800) * 0x400
                            + (UInt32(trail) - 0xDC00)
                        guard let combined = Unicode.Scalar(combinedValue) else {
                            throw JSONParseError.unpairedSurrogate(offset: offset - 4)
                        }
                        result.append(combined)
                    } else if UTF16.isTrailSurrogate(codeUnit) {
                        throw JSONParseError.unpairedSurrogate(offset: offset - 4)
                    } else if let scalarValue = Unicode.Scalar(UInt32(codeUnit)) {
                        result.append(scalarValue)
                    } else {
                        throw JSONParseError.invalidStringEscape(offset: offset - 4)
                    }
                default:
                    throw JSONParseError.invalidStringEscape(offset: offset - 1)
                }
            default:
                if scalar.value < 0x20 {
                    throw JSONParseError.unescapedControlCharacter(offset: offset)
                }
                result.append(scalar)
                offset += 1
            }
        }
        throw JSONParseError.unterminatedString(offset: startOffset)
    }

    private mutating func parseHex4() throws -> UTF16.CodeUnit {
        guard offset + 4 <= scalars.count else {
            throw JSONParseError.invalidStringEscape(offset: offset)
        }
        var value: UInt32 = 0
        for index in offset..<(offset + 4) {
            guard let digit = JSONParser.asciiHexDigitValue(of: scalars[index]) else {
                throw JSONParseError.invalidStringEscape(offset: index)
            }
            value = value * 16 + UInt32(digit)
        }
        offset += 4
        // Always ≤ 0xFFFF by construction (4 hex digits).
        return UTF16.CodeUnit(value)
    }

    /// Strict ASCII-only hex digit mapping (Unicode hexDigitValue would also
    /// accept full-width digits, which JSON \u escapes do not allow).
    private static func asciiHexDigitValue(of scalar: Unicode.Scalar) -> UInt32? {
        switch scalar {
        case "0"..."9": return scalar.value - 0x30
        case "a"..."f": return scalar.value - 0x61 + 10
        case "A"..."F": return scalar.value - 0x41 + 10
        default: return nil
        }
    }

    private mutating func parseInteger() throws -> Int64 {
        let start = offset
        if peek("-") { offset += 1 }
        guard offset < scalars.count, scalars[offset].isASCIIDigit else {
            throw JSONParseError.invalidNumber(offset: start, currentNumberString(from: start))
        }
        // Leading zeros are invalid JSON ("01").
        if scalars[offset] == "0", offset + 1 < scalars.count, scalars[offset + 1].isASCIIDigit {
            throw JSONParseError.invalidNumber(offset: start, currentNumberString(from: start))
        }
        while offset < scalars.count, scalars[offset].isASCIIDigit {
            offset += 1
        }
        // The v1 wire subset has no floats (SPEC §9): any fraction or
        // exponent marker is a protocol error, not a rounding invitation.
        if offset < scalars.count, scalars[offset] == "." || scalars[offset] == "e" || scalars[offset] == "E" {
            throw JSONParseError.invalidNumber(offset: start, currentNumberString(from: start))
        }
        let text = currentNumberString(from: start)
        guard let value = Int64(text) else {
            throw JSONParseError.integerOutOfRange(offset: start)
        }
        return value
    }

    private func currentNumberString(from start: Int) -> String {
        var end = start
        while end < scalars.count,
              scalars[end].isASCIIDigit || scalars[end] == "-" || scalars[end] == "+"
              || scalars[end] == "." || scalars[end] == "e" || scalars[end] == "E" {
            end += 1
        }
        return String(String.UnicodeScalarView(scalars[start..<end]))
    }

    private mutating func expectLiteral(_ literal: String) throws {
        for expectedScalar in literal.unicodeScalars {
            guard offset < scalars.count, scalars[offset] == expectedScalar else {
                throw errorAtOffset(expected: literal)
            }
            offset += 1
        }
    }

    private func peek(_ scalar: Unicode.Scalar) -> Bool {
        offset < scalars.count && scalars[offset] == scalar
    }

    private mutating func skipWhitespace() {
        while offset < scalars.count {
            switch scalars[offset] {
            case " ", "\t", "\n", "\r": offset += 1
            default: return
            }
        }
    }

    private func errorAtOffset(expected: String) -> JSONParseError {
        if offset < scalars.count {
            return .unexpectedCharacter(offset: offset, Character(scalars[offset]))
        }
        return .unexpectedEnd(offset: offset)
    }
}

extension Unicode.Scalar {
    fileprivate var isASCIIDigit: Bool { value >= 0x30 && value <= 0x39 }
}
