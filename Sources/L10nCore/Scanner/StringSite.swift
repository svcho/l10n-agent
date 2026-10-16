import Foundation

/// A piece of a Swift string literal or concatenation: literal text or an interpolated expression.
public enum LiteralSegment: Equatable, Sendable, Codable {
    case text(String)
    case expression(String)
}

/// Where a string appears in code and how it reaches the UI.
public enum SiteKind: String, Equatable, Sendable, Codable {
    /// Passed to an API that already localizes it, using the text itself as the key
    /// (`Text("Welcome")`, `Button("Save")`, `String(localized: "Welcome")`).
    case localizedText
    /// A localization lookup by key (`String(localized: "settings.title")`, `Text("settings.title")`).
    case localizedKey
    /// User-facing text that is never localized (`label.text = "Save"`).
    case unlocalized
    /// User-facing text assembled with `+`.
    case concatenation
    /// `String(format: "...")` with user-facing text.
    case formatString
    /// A literal without letters (`Text("\(count)")`, `Text("%@ · %@")`) that Xcode still
    /// extracts as a catalog key; it needs a "Don't translate" entry, not a translation.
    case nonText
}

/// How a fix must rewrite the code at this site.
public enum ReplacementContext: String, Equatable, Sendable, Codable {
    /// Replace the whole `Text(...)` call.
    case swiftUIText
    /// A SwiftUI parameter typed `LocalizedStringKey`; replace the literal.
    case swiftUIKey
    /// A `String`-typed position; replace the expression.
    case string
    /// Replace the whole `String(localized:)` call.
    case stringLocalizedCall
    /// Replace the whole `LocalizedStringResource(...)` call.
    case resourceCall
    /// A literal initializing or returned as a declared `LocalizedStringResource`;
    /// replace the literal with a `LocalizedStringResource` expression.
    case resourceValue
    /// Replace the whole `NSLocalizedString(...)` call.
    case nsLocalizedCall
}

public struct ByteRange: Equatable, Sendable, Codable {
    public var start: Int
    public var end: Int

    public init(start: Int, end: Int) {
        self.start = start
        self.end = end
    }
}

public struct StringSite: Equatable, Sendable, Codable {
    public var file: String
    public var line: Int
    public var column: Int
    public var kind: SiteKind
    public var context: ReplacementContext
    /// The API that receives the string, e.g. `Text`, `.navigationTitle`, `UIAlertController(title:)`, `label.text`.
    public var api: String
    /// UI role used for key and comment suggestions: `button`, `title`, `label`, …
    public var role: String
    public var segments: [LiteralSegment]
    /// The source code being replaced by a fix.
    public var originalCode: String
    public var replaceRange: ByteRange
    /// For `localizedKey`/`localizedText`: the lookup key as Xcode sees it.
    public var key: String?
    /// For localization calls: the table argument, if any.
    public var table: String?
    /// `String(localized:defaultValue:)` / `NSLocalizedString(value:)` present.
    public var hasDefaultValue: Bool
    public var enclosingType: String?
    /// Why this site cannot be rewritten mechanically; `nil` when it can.
    public var unfixableReason: String?
    /// A `comment:` argument the developer already wrote at the call site.
    public var codeComment: String?
    /// Found only by an argument label or a variable name on an API the tool does not know,
    /// so it may not be shown to users. Fixes for these need review.
    public var heuristic: Bool = false
    /// Declared type of each interpolated expression, in order, when the file declares it
    /// (`keyCode: UInt32`). `nil` entries are unknown.
    public var typeHints: [String?] = []
    /// The function or property the literal is in, e.g. `keyLabel(for:)` or `title`.
    public var enclosingMember: String?

    public var fixable: Bool { unfixableReason == nil }

    public var hasInterpolation: Bool {
        segments.contains { if case .expression = $0 { return true } else { return false } }
    }

    /// Text with interpolations shown as `\(expr)`.
    public var displayText: String {
        segments.map {
            switch $0 {
            case .text(let text): return text
            case .expression(let expression): return "\\(\(expression))"
            }
        }.joined()
    }

    public var staticText: String {
        segments.compactMap { if case .text(let text) = $0 { return text } else { return nil } }.joined()
    }
}
