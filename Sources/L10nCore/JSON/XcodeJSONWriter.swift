import Foundation

/// Serializes JSON exactly the way Xcode (and `xcstringstool`) writes String Catalogs:
/// two-space indentation, `" : "` separators, object keys sorted by raw Unicode
/// code point, empty containers written as `{\n\n<indent>}`, no trailing newline.
public enum XcodeJSONWriter {
    public static func string(_ value: JSONValue) -> String {
        var output = ""
        write(value, indent: 0, into: &output)
        return output
    }

    public static func data(_ value: JSONValue) -> Data {
        Data(string(value).utf8)
    }

    /// Code-point ordering. Equivalent to lexicographic UTF-8 byte ordering.
    public static func codePointLess(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
    }

    private static func write(_ value: JSONValue, indent: Int, into output: inout String) {
        switch value {
        case .object(let object):
            let pad = String(repeating: " ", count: indent)
            if object.isEmpty {
                output += "{\n\n\(pad)}"
                return
            }
            let inner = String(repeating: " ", count: indent + 2)
            output += "{\n"
            let sorted = object.members.sorted { codePointLess($0.key, $1.key) }
            for (offset, member) in sorted.enumerated() {
                output += inner
                writeString(member.key, into: &output)
                output += " : "
                write(member.value, indent: indent + 2, into: &output)
                output += offset == sorted.count - 1 ? "\n" : ",\n"
            }
            output += "\(pad)}"
        case .array(let array):
            let pad = String(repeating: " ", count: indent)
            if array.isEmpty {
                output += "[\n\n\(pad)]"
                return
            }
            let inner = String(repeating: " ", count: indent + 2)
            output += "[\n"
            for (offset, element) in array.enumerated() {
                output += inner
                write(element, indent: indent + 2, into: &output)
                output += offset == array.count - 1 ? "\n" : ",\n"
            }
            output += "\(pad)]"
        case .string(let string):
            writeString(string, into: &output)
        case .number(let literal):
            output += literal
        case .bool(let bool):
            output += bool ? "true" : "false"
        case .null:
            output += "null"
        }
    }

    private static func writeString(_ string: String, into output: inout String) {
        output += "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": output += "\\\""
            case "\\": output += "\\\\"
            case "\n": output += "\\n"
            case "\r": output += "\\r"
            case "\t": output += "\\t"
            case "\u{08}": output += "\\b"
            case "\u{0C}": output += "\\f"
            default:
                if scalar.value < 0x20 {
                    output += String(format: "\\u%04x", scalar.value)
                } else {
                    output.unicodeScalars.append(scalar)
                }
            }
        }
        output += "\""
    }
}
