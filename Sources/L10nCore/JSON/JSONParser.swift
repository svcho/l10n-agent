import Foundation

public struct JSONParseError: Error, CustomStringConvertible, Sendable {
    public let message: String
    public let line: Int
    public let column: Int

    public var description: String { "\(message) at line \(line), column \(column)" }
}

/// Order-preserving JSON parser. Accepts an optional UTF-8 BOM.
public struct JSONParser {
    private let bytes: [UInt8]
    private var index: Int

    public static func parse(_ data: Data) throws -> JSONValue {
        var parser = JSONParser(bytes: [UInt8](data))
        return try parser.parseDocument()
    }

    public static func parse(_ text: String) throws -> JSONValue {
        try parse(Data(text.utf8))
    }

    private init(bytes: [UInt8]) {
        self.bytes = bytes
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            self.index = 3
        } else {
            self.index = 0
        }
    }

    private mutating func parseDocument() throws -> JSONValue {
        skipWhitespace()
        let value = try parseValue()
        skipWhitespace()
        guard index == bytes.count else { throw error("Unexpected trailing content") }
        return value
    }

    private func error(_ message: String) -> JSONParseError {
        var line = 1
        var column = 1
        for byte in bytes[0..<min(index, bytes.count)] {
            if byte == UInt8(ascii: "\n") {
                line += 1
                column = 1
            } else {
                column += 1
            }
        }
        return JSONParseError(message: message, line: line, column: column)
    }

    private mutating func skipWhitespace() {
        while index < bytes.count {
            switch bytes[index] {
            case 0x20, 0x09, 0x0A, 0x0D: index += 1
            default: return
            }
        }
    }

    private mutating func parseValue() throws -> JSONValue {
        guard index < bytes.count else { throw error("Unexpected end of input") }
        switch bytes[index] {
        case UInt8(ascii: "{"): return .object(try parseObject())
        case UInt8(ascii: "["): return .array(try parseArray())
        case UInt8(ascii: "\""): return .string(try parseString())
        case UInt8(ascii: "t"): try expect("true"); return .bool(true)
        case UInt8(ascii: "f"): try expect("false"); return .bool(false)
        case UInt8(ascii: "n"): try expect("null"); return .null
        default: return .number(try parseNumber())
        }
    }

    private mutating func expect(_ literal: String) throws {
        let literalBytes = Array(literal.utf8)
        guard index + literalBytes.count <= bytes.count,
              Array(bytes[index..<index + literalBytes.count]) == literalBytes
        else { throw error("Expected \(literal)") }
        index += literalBytes.count
    }

    private mutating func parseObject() throws -> JSONObject {
        index += 1
        var members: [JSONObject.Member] = []
        skipWhitespace()
        if index < bytes.count, bytes[index] == UInt8(ascii: "}") {
            index += 1
            return JSONObject(members)
        }
        while true {
            skipWhitespace()
            guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { throw error("Expected object key") }
            let key = try parseString()
            skipWhitespace()
            guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { throw error("Expected ':'") }
            index += 1
            skipWhitespace()
            let value = try parseValue()
            if members.contains(where: { $0.key.utf8.elementsEqual(key.utf8) }) {
                throw error("Duplicate object key \"\(key)\"")
            }
            members.append(JSONObject.Member(key: key, value: value))
            skipWhitespace()
            guard index < bytes.count else { throw error("Unterminated object") }
            if bytes[index] == UInt8(ascii: ",") {
                index += 1
                continue
            }
            if bytes[index] == UInt8(ascii: "}") {
                index += 1
                return JSONObject(members)
            }
            throw error("Expected ',' or '}'")
        }
    }

    private mutating func parseArray() throws -> [JSONValue] {
        index += 1
        var values: [JSONValue] = []
        skipWhitespace()
        if index < bytes.count, bytes[index] == UInt8(ascii: "]") {
            index += 1
            return values
        }
        while true {
            skipWhitespace()
            values.append(try parseValue())
            skipWhitespace()
            guard index < bytes.count else { throw error("Unterminated array") }
            if bytes[index] == UInt8(ascii: ",") {
                index += 1
                continue
            }
            if bytes[index] == UInt8(ascii: "]") {
                index += 1
                return values
            }
            throw error("Expected ',' or ']'")
        }
    }

    private mutating func parseNumber() throws -> String {
        let start = index
        while index < bytes.count, Self.isNumberByte(bytes[index]) {
            index += 1
        }
        guard index > start, let literal = String(bytes: bytes[start..<index], encoding: .utf8),
              Double(literal) != nil
        else { throw error("Invalid value") }
        return literal
    }

    private static func isNumberByte(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "-"), UInt8(ascii: "+"),
             UInt8(ascii: "."), UInt8(ascii: "e"), UInt8(ascii: "E"):
            return true
        default:
            return false
        }
    }

    private mutating func parseString() throws -> String {
        index += 1
        var buffer: [UInt8] = []
        while index < bytes.count {
            let byte = bytes[index]
            switch byte {
            case UInt8(ascii: "\""):
                index += 1
                guard let string = UTF8Text.decode(buffer) else { throw error("Invalid UTF-8 in string") }
                return string
            case UInt8(ascii: "\\"):
                index += 1
                guard index < bytes.count else { throw error("Unterminated escape") }
                let escape = bytes[index]
                index += 1
                switch escape {
                case UInt8(ascii: "\""): buffer.append(UInt8(ascii: "\""))
                case UInt8(ascii: "\\"): buffer.append(UInt8(ascii: "\\"))
                case UInt8(ascii: "/"): buffer.append(UInt8(ascii: "/"))
                case UInt8(ascii: "b"): buffer.append(0x08)
                case UInt8(ascii: "f"): buffer.append(0x0C)
                case UInt8(ascii: "n"): buffer.append(0x0A)
                case UInt8(ascii: "r"): buffer.append(0x0D)
                case UInt8(ascii: "t"): buffer.append(0x09)
                case UInt8(ascii: "u"):
                    var scalarValue = try parseHex4()
                    if (0xD800...0xDBFF).contains(scalarValue) {
                        guard index + 1 < bytes.count, bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u")
                        else { throw error("Unpaired surrogate") }
                        index += 2
                        let low = try parseHex4()
                        guard (0xDC00...0xDFFF).contains(low) else { throw error("Invalid surrogate pair") }
                        scalarValue = 0x10000 + ((scalarValue - 0xD800) << 10) + (low - 0xDC00)
                    }
                    guard let scalar = Unicode.Scalar(scalarValue) else { throw error("Invalid unicode escape") }
                    buffer.append(contentsOf: Array(String(Character(scalar)).utf8))
                default:
                    throw error("Invalid escape")
                }
            case 0x00..<0x20:
                throw error("Unescaped control character in string")
            default:
                buffer.append(byte)
                index += 1
            }
        }
        throw error("Unterminated string")
    }

    private mutating func parseHex4() throws -> UInt32 {
        guard index + 4 <= bytes.count, let text = String(bytes: bytes[index..<index + 4], encoding: .ascii),
              let value = UInt32(text, radix: 16)
        else { throw error("Invalid unicode escape") }
        index += 4
        return value
    }
}
