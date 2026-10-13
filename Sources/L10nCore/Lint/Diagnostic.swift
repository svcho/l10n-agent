import Foundation

public struct RuleInfo: Sendable, Equatable, Codable {
    public let id: String
    public let name: String
    public let defaultSeverity: Severity
    public let summary: String
}

public enum Rules {
    public static let catalogParse = RuleInfo(id: "L10N100", name: "catalog-parse", defaultSeverity: .error, summary: "A String Catalog could not be parsed.")
    public static let unlocalized = RuleInfo(id: "L10N001", name: "unlocalized-string", defaultSeverity: .warning, summary: "User-facing text reaches the UI without localization.")
    public static let textAsKey = RuleInfo(id: "L10N002", name: "text-as-key", defaultSeverity: .warning, summary: "Localized text uses its own English copy as key instead of a semantic key.")
    public static let concatenation = RuleInfo(id: "L10N003", name: "concatenated-string", defaultSeverity: .warning, summary: "User-facing text is assembled by concatenation or String(format:), which translators cannot reorder.")
    public static let missingKey = RuleInfo(id: "L10N004", name: "missing-key", defaultSeverity: .error, summary: "Code looks up a key that no String Catalog defines.")
    public static let pluralCandidate = RuleInfo(id: "L10N005", name: "plural-candidate", defaultSeverity: .info, summary: "A count is interpolated into text; a plural variation is likely needed.")
    public static let missingTranslation = RuleInfo(id: "L10N101", name: "missing-translation", defaultSeverity: .warning, summary: "A key has no translation for a target locale.")
    public static let needsReview = RuleInfo(id: "L10N102", name: "needs-review", defaultSeverity: .info, summary: "A translation is waiting for human review.")
    public static let staleTranslation = RuleInfo(id: "L10N103", name: "stale-translation", defaultSeverity: .warning, summary: "The source text changed after the translation was made.")
    public static let formatMismatch = RuleInfo(id: "L10N104", name: "format-mismatch", defaultSeverity: .error, summary: "A translation's format specifiers do not match the source (by argument index and type).")
    public static let missingComment = RuleInfo(id: "L10N105", name: "missing-comment", defaultSeverity: .info, summary: "A key has no comment to give translators context.")
    public static let unusedKey = RuleInfo(id: "L10N106", name: "unused-key", defaultSeverity: .info, summary: "Xcode marked the key stale: no code references it anymore.")
    public static let keyStyle = RuleInfo(id: "L10N107", name: "key-style", defaultSeverity: .warning, summary: "A manual key does not follow the configured key style.")
    public static let glossary = RuleInfo(id: "L10N108", name: "glossary", defaultSeverity: .warning, summary: "A translation does not use the required glossary term.")
    public static let untranslatedCopy = RuleInfo(id: "L10N109", name: "untranslated-copy", defaultSeverity: .info, summary: "A translation is identical to the source text.")
    public static let symbolCollision = RuleInfo(id: "L10N110", name: "symbol-collision", defaultSeverity: .error, summary: "Keys generate the same Swift symbol, or a reserved one; Xcode fails the build.")
    public static let sourceLanguageMismatch = RuleInfo(id: "L10N111", name: "source-language", defaultSeverity: .warning, summary: "A catalog's sourceLanguage differs from the project's source language.")

    public static let all: [RuleInfo] = [
        unlocalized, textAsKey, concatenation, missingKey, pluralCandidate,
        catalogParse, missingTranslation, needsReview, staleTranslation, formatMismatch, missingComment,
        unusedKey, keyStyle, glossary, untranslatedCopy, symbolCollision, sourceLanguageMismatch,
    ]

    public static func info(_ id: String) -> RuleInfo? {
        all.first { $0.id == id || $0.name == id }
    }
}

public struct Diagnostic: Codable, Equatable, Sendable {
    /// Stable identifier, usable across runs to select findings to fix.
    public var id: String
    public var rule: String
    public var name: String
    public var severity: Severity
    public var message: String
    public var file: String
    public var line: Int?
    public var column: Int?
    public var key: String?
    public var locales: [String]?
    public var fixable: Bool

    public init(rule: RuleInfo, severity: Severity, message: String, file: String, line: Int? = nil, column: Int? = nil, key: String? = nil, locales: [String]? = nil, fixable: Bool = false, identity: String = "") {
        self.rule = rule.id
        self.name = rule.name
        self.severity = severity
        self.message = message
        self.file = file
        self.line = line
        self.column = column
        self.key = key
        self.locales = locales
        self.fixable = fixable
        self.id = "\(rule.id)-" + Hashing.shortHash([rule.id, file, key ?? "", identity, line.map(String.init) ?? "", column.map(String.init) ?? ""].joined(separator: "\u{1F}")).prefix(8)
    }
}

public struct LintSummary: Codable, Equatable, Sendable {
    public var errors = 0
    public var warnings = 0
    public var infos = 0
    public var swiftFiles = 0
    public var catalogs = 0

    public init() {}
}

public struct LintReport: Codable, Equatable, Sendable {
    public var diagnostics: [Diagnostic]
    public var summary: LintSummary

    public func failed(threshold: Severity) -> Bool {
        diagnostics.contains { $0.severity >= threshold && $0.severity != .off }
    }
}
