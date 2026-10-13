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

    public func suggest(for site: StringSite, isTaken: (String) -> Bool) -> String {
        let scope = effectiveScope(for: site)
        let words = site.segments.flatMap { segment -> [String] in
            guard case .text(let text) = segment else { return [] }
            return SymbolNaming.splitWords(text.folding(options: [.diacriticInsensitive], locale: nil)).filter { $0.allSatisfy(\.isASCII) }
        }
        var meaningful = words.filter { !Self.stopwords.contains($0.lowercased()) }
        if meaningful.isEmpty { meaningful = words }
        var slug = format(words: Array(meaningful.prefix(3)))
        if slug.isEmpty { slug = "text" }
        if let first = slug.first, first.isNumber { slug = "n" + slug }

        let role = Self.roleSegments[site.role]
        var segments = [scope]
        if slug.lowercased() != scope.lowercased() { segments.append(slug) }
        if let role, segments.count < policy.maxDepth, role.lowercased() != slug.lowercased() { segments.append(formatSegment(role)) }
        while segments.count < policy.minDepth { segments.append("text") }

        let base = segments.joined(separator: ".")
        var candidate = base
        var counter = 2
        while isTaken(candidate) {
            var numbered = segments
            let slugIndex = segments.count > 1 ? 1 : 0
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
        var comment = "\(description) in \(where_)."
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
