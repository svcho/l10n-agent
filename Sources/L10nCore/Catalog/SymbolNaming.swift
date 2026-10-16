import Foundation

/// Reproduces how Xcode's "Generate String Catalog Symbols" names the
/// `LocalizedStringResource` symbol for a manual key (verified against
/// `xcstringstool generate-symbols`, Xcode 27).
public enum SymbolNaming {
    public enum Result: Equatable, Sendable {
        case name(String)
        /// Xcode rejects these keys ("too close to a reserved keyword").
        case reserved
    }

    static let rejectedKeys: Set<String> = ["self", "Self", "Type", "Protocol"]

    static let swiftKeywords: Set<String> = [
        "associatedtype", "class", "deinit", "enum", "extension", "fileprivate", "func", "import", "init",
        "inout", "internal", "let", "open", "operator", "private", "precedencegroup", "protocol", "public",
        "rethrows", "static", "struct", "subscript", "typealias", "var", "break", "case", "catch", "continue",
        "default", "defer", "do", "else", "fallthrough", "for", "guard", "if", "in", "repeat", "return",
        "throw", "switch", "where", "while", "Any", "as", "await", "false", "is", "nil", "super", "throws",
        "true", "try",
    ]

    public static func symbol(for key: String) -> Result {
        if rejectedKeys.contains(key) { return .reserved }
        if swiftKeywords.contains(key) { return .name("`\(key)`") }

        let words = splitWords(key)
        guard !words.isEmpty else { return .name("_") }

        let needsPrefix = key.first.map { $0 == "_" || ($0.isASCII && $0.isNumber) } ?? false
        var name = needsPrefix ? "_" : ""
        for (offset, word) in words.enumerated() {
            if offset == 0, !needsPrefix {
                name += lowercasingLeadingUppercaseRun(word)
            } else {
                name += capitalizedWord(word)
            }
        }
        return .name(name)
    }

    /// Catalogs other than `Localizable` get their symbols nested in a namespace named
    /// after the table: `Settings.xcstrings` → `LocalizedStringResource.Settings.someKey`.
    public static func tableNamespace(_ table: String) -> String? {
        guard table != "Localizable" else { return nil }
        let words = splitWords(table)
        guard !words.isEmpty else { return nil }
        let prefix = table.first.map { $0 == "_" || ($0.isASCII && $0.isNumber) } ?? false ? "_" : ""
        return prefix + words.map(capitalizedWord).joined()
    }

    /// Implicit member reference usable where a `LocalizedStringResource` is expected,
    /// e.g. `.welcomeTitle`, `.Settings.welcomeTitle`, `.greeting(name)`.
    public static func reference(for key: String, table: String, arguments: [String] = []) -> String? {
        guard case .name(let name) = symbol(for: key) else { return nil }
        let namespace = tableNamespace(table).map { "\($0)." } ?? ""
        let call = arguments.isEmpty ? "" : "(\(arguments.joined(separator: ", ")))"
        return ".\(namespace)\(name)\(call)"
    }

    /// The identifier without backticks, used for collision checks.
    public static func bareName(for key: String) -> String? {
        guard case .name(let name) = symbol(for: key) else { return nil }
        return name.trimmingCharacters(in: CharacterSet(charactersIn: "`"))
    }

    /// Groups keys that would generate the same symbol (a build error in Xcode).
    public static func collisions(among keys: [String]) -> [[String]] {
        var groups: [String: [String]] = [:]
        for key in keys {
            guard let name = bareName(for: key) else { continue }
            groups[name, default: []].append(key)
        }
        return groups.values.filter { $0.count > 1 }.map { $0.sorted(by: XcodeJSONWriter.codePointLess) }
            .sorted { $0[0].utf8.lexicographicallyPrecedes($1[0].utf8) }
    }

    static func splitWords(_ key: String) -> [String] {
        var words: [String] = []
        var current = ""
        var previous: Character?
        for character in key {
            if character.isLetter || character.isNumber {
                if let previous, previous.isNumber, character.isLetter, !current.isEmpty {
                    words.append(current)
                    current = ""
                }
                current.append(character)
            } else if !current.isEmpty {
                words.append(current)
                current = ""
            }
            previous = character.isLetter || character.isNumber ? character : nil
        }
        if !current.isEmpty { words.append(current) }
        return words
    }

    private static func lowercasingLeadingUppercaseRun(_ word: String) -> String {
        guard let first = word.first, first.isUppercase else { return word }
        let run = word.prefix { $0.isUppercase }
        return run.lowercased() + word.dropFirst(run.count)
    }

    private static func capitalizedWord(_ word: String) -> String {
        let letters = word.filter(\.isLetter)
        if !letters.isEmpty, letters.allSatisfy(\.isUppercase), letters.count > 1 {
            return word.prefix(1).uppercased() + word.dropFirst().lowercased()
        }
        return word.prefix(1).uppercased() + word.dropFirst()
    }
}
