import Foundation

public struct FixPlaceholder: Codable, Equatable, Sendable {
    /// The Swift expression interpolated at this position.
    public var expression: String
    /// Catalog format specifier, e.g. `%@`, `%lld`, `%lf`.
    public var specifier: String
    /// `false` when the type was guessed from naming; review before applying.
    public var confident: Bool

    public init(expression: String, specifier: String, confident: Bool) {
        self.expression = expression
        self.specifier = specifier
        self.confident = confident
    }
}

public enum FixStatus: String, Codable, Sendable {
    /// Will be applied.
    case ready
    /// Applied only when confirmed (`--include-review`, or set to `ready` in the plan).
    case needsReview
    /// Cannot be fixed mechanically.
    case skipped
}

/// One code site turned into a catalog key plus a code rewrite.
///
/// A coding agent may edit `key`, `comment`, `placeholders[].specifier` and `status`
/// before applying; the replacement code is recomputed from those fields.
public struct FixItem: Codable, Equatable, Sendable {
    public var id: String
    public var rule: String
    public var file: String
    public var line: Int
    public var column: Int
    public var status: FixStatus
    public var reason: String?
    public var original: String
    public var key: String
    public var comment: String
    public var sourceValue: String
    public var placeholders: [FixPlaceholder]
    public var catalog: String
    public var replacement: String
    public var context: ReplacementContext
    /// The API receiving the text, e.g. `Button`, `.navigationTitle`, `label.text`.
    public var api: String
    /// UI role: `button`, `title`, `label`, …
    public var role: String
    public var enclosingType: String?
    public var range: ByteRange
    public var segments: [LiteralSegment]
    /// The key already exists with the same source text and is reused.
    public var reusesExistingKey: Bool
    /// An English-text key whose translations are copied to the new key.
    public var migrateFrom: String?
}

public struct FixPlan: Codable, Equatable, Sendable {
    public var version: Int
    public var codeStyle: String
    /// SHA-256 of each touched file when the plan was made; apply refuses if a file changed.
    public var files: [String: String]
    public var items: [FixItem]
}

public struct ApplyResult: Codable, Equatable, Sendable {
    public var applied: [String]
    public var skipped: [String: String]
    public var filesChanged: [String]
    public var catalogsChanged: [String]
    public var keysAdded: [String]
    public var notes: [String]
}
