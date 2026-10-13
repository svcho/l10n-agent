import Foundation

/// A JSON value that keeps object members in their original order, keeps
/// number literals verbatim, and compares keys by exact UTF-8 bytes.
///
/// String Catalogs must round-trip losslessly: unknown fields survive and
/// keys are never Unicode-normalized (Xcode treats `é` and `e\u{301}` as
/// different keys).
public indirect enum JSONValue: Equatable, Sendable {
    case object(JSONObject)
    case array([JSONValue])
    case string(String)
    case number(String)
    case bool(Bool)
    case null

    public var objectValue: JSONObject? {
        if case .object(let object) = self { return object }
        return nil
    }

    public var stringValue: String? {
        if case .string(let string) = self { return string }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let bool) = self { return bool }
        return nil
    }

    public var intValue: Int? {
        if case .number(let literal) = self { return Int(literal) }
        return nil
    }

    public subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }
}

public struct JSONObject: Equatable, Sendable {
    public struct Member: Equatable, Sendable {
        public var key: String
        public var value: JSONValue

        public init(key: String, value: JSONValue) {
            self.key = key
            self.value = value
        }

        public static func == (lhs: Member, rhs: Member) -> Bool {
            lhs.key.utf8.elementsEqual(rhs.key.utf8) && lhs.value == rhs.value
        }
    }

    public var members: [Member]

    public init(_ members: [Member] = []) {
        self.members = members
    }

    public init(_ pairs: KeyValuePairs<String, JSONValue>) {
        self.members = pairs.map { Member(key: $0.key, value: $0.value) }
    }

    public var keys: [String] { members.map(\.key) }
    public var isEmpty: Bool { members.isEmpty }

    private func index(of key: String) -> Int? {
        members.firstIndex { $0.key.utf8.elementsEqual(key.utf8) }
    }

    public subscript(key: String) -> JSONValue? {
        get { index(of: key).map { members[$0].value } }
        set {
            if let newValue {
                if let existing = index(of: key) {
                    members[existing].value = newValue
                } else {
                    members.append(Member(key: key, value: newValue))
                }
            } else if let existing = index(of: key) {
                members.remove(at: existing)
            }
        }
    }

    public func contains(_ key: String) -> Bool {
        index(of: key) != nil
    }
}

extension JSONValue {
    /// Converts a Foundation JSON object (from `JSONSerialization`) into a `JSONValue`.
    public init(foundation value: Any) {
        switch value {
        case let dictionary as [String: Any]:
            self = .object(JSONObject(dictionary.keys.sorted().map {
                JSONObject.Member(key: $0, value: JSONValue(foundation: dictionary[$0]!))
            }))
        case let array as [Any]:
            self = .array(array.map(JSONValue.init(foundation:)))
        case let string as String:
            self = .string(string)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else {
                self = .number(number.stringValue)
            }
        default:
            self = .null
        }
    }

    /// Converts into Foundation types for `JSONSerialization`/`Codable` bridging.
    public var foundationValue: Any {
        switch self {
        case .object(let object):
            var dictionary: [String: Any] = [:]
            for member in object.members { dictionary[member.key] = member.value.foundationValue }
            return dictionary
        case .array(let array): return array.map(\.foundationValue)
        case .string(let string): return string
        case .number(let literal): return Double(literal).map { $0 == $0.rounded() && abs($0) < 1e15 ? Int($0) as Any : $0 as Any } ?? literal
        case .bool(let bool): return bool
        case .null: return NSNull()
        }
    }
}
