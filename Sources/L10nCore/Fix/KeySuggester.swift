import Foundation

/// Deterministic semantic key and comment suggestions:
/// `<scope>.<slug>[.<role>]`, e.g. `settings.saveChanges.button`.
public struct KeySuggester: Sendable {
    public let policy: KeyPolicy

    public init(policy: KeyPolicy) {
        self.policy = policy
    }

    static let typeSuffixes = ["ViewController", "ViewModel", "Controller", "View", "Screen", "Cell", "Model", "Sheet", "Page", "Row", "Store"]
    static let stopwords: Set<String> = ["a", "an", "the", "to", "of", "for", "and", "or", "your", "you", "is", "are", "this", "that", "with", "in", "on", "at", "be", "it", "by", "from", "my", "our", "we", "i"]
    static let roleSegments: [String: String] = [
        "button": "button", "title": "title", "subtitle": "subtitle", "label": "label", "toggle": "toggle",
        "picker": "picker", "link": "link", "placeholder": "placeholder", "menu": "menu", "header": "header",
        "tab": "tab", "help": "help", "a11yLabel": "accessibilityLabel", "a11yHint": "accessibilityHint",
        "a11yValue": "accessibilityValue", "alertTitle": "alertTitle", "dialogTitle": "dialogTitle", "badge": "badge",
        "searchPrompt": "searchPrompt", "alert": "alert", "action": "action", "message": "message", "hint": "hint",
        "caption": "caption", "shortcut": "shortcut", "alertMessage": "alertMessage",
    ]

    /// Generic UI words shared across screens under the `common` scope.
    static let commonWords: Set<String> = [
        "ok", "cancel", "done", "save", "delete", "edit", "close", "back", "next", "continue", "retry",
        "yes", "no", "add", "remove", "share", "search", "settings", "loading", "error", "undo", "redo",
    ]

    /// `common` for generic words such as "Cancel", else the screen-derived scope.
    public func effectiveScope(for site: StringSite) -> String {
        let text = site.staticText.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)).lowercased()
        if !site.hasInterpolation, Self.commonWords.contains(text),
           policy.scopes.isEmpty || policy.scopes.contains("common") {
            return "common"
        }
        return scope(for: site)
    }

    public func scope(for site: StringSite) -> String {
        var name = site.enclosingType ?? URL(fileURLWithPath: site.file).deletingPathExtension().lastPathComponent
        name = name.split(separator: ".").first.map(String.init) ?? name
        for suffix in Self.typeSuffixes where name.hasSuffix(suffix) && name.count > suffix.count {
            name = String(name.dropLast(suffix.count))
            break
        }
        var scope = format(words: SymbolNaming.splitWords(name).flatMap(Self.splitCamel))
        if scope.isEmpty { scope = "common" }
        if !policy.scopes.isEmpty, !policy.scopes.contains(scope) {
            scope = policy.scopes.contains("common") ? "common" : policy.scopes[0]
        }
        return scope
    }

    /// The dotted prefix shared by the keys the enclosing type (else the file) already uses,
    /// so new keys follow the project's scheme (`mac.settings.hotkey`). Generic words keep
    /// the `common` scope. `nil` when there is nothing to follow.
    /// When the type and file use no keys, `catalogKeys` (the catalog's manual keys) may
    /// still share one first segment (`mac.` in a Mac target's catalog); the type-derived
    /// scope then goes under it (`mac.appSettings`).
    public func projectPrefix(for site: StringSite, siblings: [String: [String]], catalogKeys: [String] = []) -> String? {
        let fallbackScope = effectiveScope(for: site)
        if fallbackScope == "common" { return nil }
        // Error descriptions go where the catalog keeps its errors (`error.…`).
        if site.api.hasPrefix("userInfo["), let errorScope = Self.errorScope(catalogKeys),
           policy.scopes.isEmpty || policy.scopes.contains(errorScope) {
            return errorScope
        }
        var keys = siblings[site.enclosingType ?? ""] ?? []
        if keys.isEmpty { keys = siblings.values.flatMap { $0 } }
        if keys.count < 2, let dominant = Self.dominantFirstSegment(catalogKeys), dominant != fallbackScope {
            if !policy.scopes.isEmpty, !policy.scopes.contains(dominant) { return nil }
            // `macAppSettings` under `mac` becomes `mac.appSettings`.
            var words = Self.splitCamel(fallbackScope)
            if words.first?.lowercased() == dominant.lowercased(), words.count > 1 { words.removeFirst() }
            let rest = format(words: words)
            return rest.isEmpty || policy.maxDepth < 4 ? dominant : "\(dominant).\(rest)"
        }
        let split = keys.map { $0.split(separator: ".", omittingEmptySubsequences: false).map(String.init) }.filter { $0.count >= 2 }
        // One key says little about a scheme (it may belong to another screen).
        guard split.count >= 2, let first = split.first else { return nil }
        var common: [String] = []
        for (index, segment) in first.enumerated() where index < first.count - 1 {
            guard split.allSatisfy({ index < $0.count - 1 && $0[index] == segment }) else { break }
            common.append(segment)
        }
        // Leave room for the text and role segments.
        common = Array(common.prefix(max(1, policy.maxDepth - 2)))
        guard let scope = common.first, !scope.isEmpty else { return nil }
        if !policy.scopes.isEmpty, !policy.scopes.contains(scope) { return nil }
        return common.joined(separator: ".")
    }

    /// `error` or `errors` when at least 3 keys start with it.
    static func errorScope(_ keys: [String]) -> String? {
        for scope in ["error", "errors"] where keys.filter({ $0.hasPrefix(scope + ".") }).count >= 3 {
            return scope
        }
        return nil
    }

    /// The first segment at least 80% of (5 or more) keys share.
    static func dominantFirstSegment(_ keys: [String]) -> String? {
        guard keys.count >= 5 else { return nil }
        let counts = Dictionary(grouping: keys.compactMap { $0.split(separator: ".").first.map(String.init) }, by: { $0 }).mapValues(\.count)
        guard let (segment, count) = counts.max(by: { $0.value < $1.value }), Double(count) >= Double(keys.count) * 0.8 else { return nil }
        return segment
    }

    public func suggest(for site: StringSite, prefix: String? = nil, isTaken: (String) -> Bool) -> String {
        let scope = prefix ?? effectiveScope(for: site)
        let words = site.segments.flatMap { segment -> [String] in
            guard case .text(let text) = segment else { return [] }
            return SymbolNaming.splitWords(text.folding(options: [.diacriticInsensitive], locale: nil)).filter { $0.allSatisfy(\.isASCII) }
        }
        var meaningful = words.filter { !Self.stopwords.contains($0.lowercased()) }
        if meaningful.isEmpty { meaningful = words }
        // Long phrases keep their head and their last word ("Model container not yet
        // initialized" → modelContainerInitialized) instead of stopping mid-phrase.
        // A negation in the middle is kept, so the key does not say the opposite.
        let negations: Set<String> = ["not", "no", "never", "without", "cannot", "cant", "dont", "isnt"]
        let slugWords = meaningful.count > 3
            ? Array(meaningful.prefix(2)) + meaningful.dropFirst(2).dropLast().filter { negations.contains($0.lowercased()) }.prefix(1) + [meaningful.last!]
            : meaningful
        var slug = format(words: slugWords)
        if slug.isEmpty { slug = "text" }
        if let first = slug.first, first.isNumber { slug = "n" + slug }

        let role = Self.roleSegments[site.role]
        var segments = scope.split(separator: ".").map(String.init)
        let scopeCount = segments.count
        if slug.lowercased() != segments.last?.lowercased() { segments.append(slug) }
        if let role, segments.count < policy.maxDepth, role.lowercased() != slug.lowercased() { segments.append(formatSegment(role)) }
        while segments.count < policy.minDepth { segments.append("text") }

        let base = segments.joined(separator: ".")
        var candidate = base
        var counter = 2
        while isTaken(candidate) {
            var numbered = segments
            let slugIndex = segments.count > scopeCount ? scopeCount : segments.count - 1
            numbered[slugIndex] += "\(counter)"
            candidate = numbered.joined(separator: ".")
            counter += 1
        }
        return candidate
    }

    public func comment(for site: StringSite, placeholders: [FixPlaceholder]) -> String {
        let where_ = site.enclosingType ?? URL(fileURLWithPath: site.file).deletingPathExtension().lastPathComponent
        let description: String
        switch site.role {
        case "button": description = "Button title"
        case "title": description = "Title"
        case "alertTitle": description = "Alert title"
        case "alertMessage": description = "Alert message"
        case "dialogTitle": description = "Confirmation dialog title"
        case "hint": description = "Hint text"
        case "label": description = "Label"
        case "picker": description = "Picker label"
        case "help": description = "Help tooltip"
        case "badge": description = "Badge"
        case "caption": description = "Caption"
        case "subtitle": description = "Subtitle"
        case "message": description = "Message"
        case "placeholder": description = "Placeholder text of an input field"
        case "searchPrompt": description = "Search field prompt"
        case "toggle": description = "Toggle label"
        case "a11yLabel": description = "Accessibility label"
        case "a11yHint": description = "Accessibility hint"
        case "header": description = "Section header"
        case "menu": description = "Menu title"
        case "link": description = "Link title"
        case "tab": description = "Tab title"
        default: description = "Text"
        }
        var comment: String
        if let member = site.enclosingMember, member != "body" {
            comment = "\(description) in \(where_).\(member)."
        } else {
            comment = "\(description) in \(where_)."
        }
        if !placeholders.isEmpty {
            let explanations = placeholders.enumerated().map { index, placeholder in
                "\(placeholders.count > 1 ? "%\(index + 1)$" : "%")\(placeholder.specifier.dropFirst()) is \(placeholder.expression)"
            }
            comment += " " + explanations.joined(separator: "; ") + "."
        }
        return comment
    }

    func format(words: [String]) -> String {
        let lower = words.map { $0.lowercased() }.filter { !$0.isEmpty }
        guard let first = lower.first else { return "" }
        switch policy.style {
        case .dottedCamel: return first + lower.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
        case .dottedLower: return lower.joined()
        case .dottedSnake: return lower.joined(separator: "_")
        }
    }

    func formatSegment(_ camel: String) -> String {
        format(words: Self.splitCamel(camel))
    }

    static func splitCamel(_ word: String) -> [String] {
        var parts: [String] = []
        var current = ""
        for character in word {
            if character.isUppercase, !current.isEmpty, current.last?.isUppercase == false {
                parts.append(current)
                current = ""
            }
            current.append(character)
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }
}
