import Foundation

/// Asks the local model for better semantic keys and translator comments for a fix plan.
/// Every suggestion is validated (key style, uniqueness, symbol collisions); invalid
/// suggestions keep the deterministic key.
public struct LLMKeyNamer {
    public let project: Project
    public let model: ChatModel

    public init(project: Project, model: ChatModel) {
        self.project = project
        self.model = model
    }

    public func improve(_ plan: FixPlan, batchSize: Int = 25) async throws -> FixPlan {
        var plan = plan
        let candidates = plan.items.indices.filter { plan.items[$0].status != .skipped && !plan.items[$0].reusesExistingKey }
        guard !candidates.isEmpty else { return plan }

        var catalogKeys: [String: Set<String>] = [:]
        for url in project.catalogURLs {
            if let catalog = try? StringCatalog.load(url) {
                catalogKeys[project.relativePath(url)] = Set(catalog.keys)
            }
        }

        for start in stride(from: 0, to: candidates.count, by: batchSize) {
            let indices = Array(candidates[start..<min(start + batchSize, candidates.count)])
            let response = try await model.complete(system: systemPrompt(), user: userPrompt(indices.map { plan.items[$0] }))
            let suggestions = Self.parse(response)

            for index in indices {
                let item = plan.items[index]
                guard let suggestion = suggestions[item.id] else { continue }
                if let comment = suggestion.comment?.trimmingCharacters(in: .whitespacesAndNewlines), !comment.isEmpty, comment.count <= 300 {
                    plan.items[index].comment = comment
                }
                guard let key = suggestion.key?.trimmingCharacters(in: .whitespacesAndNewlines), key != item.key,
                      project.config.keys.violations(for: key).isEmpty
                else { continue }
                let usedByOthers = plan.items.enumerated().contains { other in
                    other.offset != index && other.element.catalog == item.catalog && other.element.key == key && other.element.sourceValue != item.sourceValue
                }
                let symbolClash = project.usesSymbols && plan.items.enumerated().contains { other in
                    other.offset != index && other.element.key != key && SymbolNaming.bareName(for: other.element.key) == SymbolNaming.bareName(for: key)
                }
                if usedByOthers || symbolClash || catalogKeys[item.catalog]?.contains(key) == true || SymbolNaming.symbol(for: key) == .reserved {
                    continue
                }
                plan.items[index].key = key
            }
        }

        // Identical text in one catalog keeps sharing one key.
        var firstKey: [String: String] = [:]
        for index in plan.items.indices where plan.items[index].status != .skipped {
            let group = "\(plan.items[index].catalog)|\(plan.items[index].sourceValue)"
            if let key = firstKey[group] {
                plan.items[index].key = key
            } else {
                firstKey[group] = plan.items[index].key
            }
        }

        for index in plan.items.indices {
            let table = URL(fileURLWithPath: plan.items[index].catalog).deletingPathExtension().lastPathComponent
            plan.items[index].replacement = Fixer.replacement(for: plan.items[index], usesSymbols: plan.codeStyle == CodeStyle.symbols.rawValue, table: table)
        }
        return plan
    }

    func systemPrompt() -> String {
        let policy = project.config.keys
        let example: String
        switch policy.style {
        case .dottedCamel: example = "settings.darkMode.toggle"
        case .dottedLower: example = "settings.darkmode.toggle"
        case .dottedSnake: example = "settings.dark_mode.toggle"
        }
        var lines = [
            "You name localization keys for an Apple platform app and write comments for translators.",
            "For each item return a semantic key and a comment.",
            "Key rules: \(policy.minDepth) to \(policy.maxDepth) dot-separated segments, style \(policy.style.rawValue) (example: \(example)). Start with the screen or feature, then what the text is, then its UI role. Do not copy whole sentences into the key.",
            "Comment rules: one or two short sentences saying where the text appears and what it does, plus what each placeholder (%@, %lld, …) stands for. Do not repeat the text itself.",
        ]
        if !policy.scopes.isEmpty {
            lines.append("The first segment must be one of: \(policy.scopes.joined(separator: ", ")).")
        }
        if !policy.forbiddenPrefixes.isEmpty {
            lines.append("Never start a key with: \(policy.forbiddenPrefixes.joined(separator: ", ")).")
        }
        lines.append(#"Reply with only a JSON object: {"keys":[{"id":"…","key":"…","comment":"…"}]}. No markdown."#)
        return lines.joined(separator: "\n")
    }

    func userPrompt(_ items: [FixItem]) -> String {
        let payload: [[String: Any]] = items.map { item in
            var object: [String: Any] = [
                "id": item.id,
                "text": item.sourceValue,
                "uiRole": item.role,
                "api": item.api,
                "file": item.file,
                "suggestedKey": item.key,
            ]
            if let type = item.enclosingType { object["type"] = type }
            if !item.placeholders.isEmpty {
                object["placeholders"] = item.placeholders.map { "\($0.specifier) = \($0.expression)" }
            }
            return object
        }
        let data = (try? JSONSerialization.data(withJSONObject: ["items": payload], options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    struct Suggestion {
        var key: String?
        var comment: String?
    }

    static func parse(_ response: String) -> [String: Suggestion] {
        var text = response
        while let start = text.range(of: "<think>"), let end = text.range(of: "</think>", range: start.upperBound..<text.endIndex) {
            text.removeSubrange(start.lowerBound..<end.upperBound)
        }
        guard let first = text.firstIndex(of: "{"), let last = text.lastIndex(of: "}"), first < last,
              let value = try? JSONParser.parse(String(text[first...last])),
              case .array(let list)? = value["keys"] ?? value["items"]
        else { return [:] }
        var result: [String: Suggestion] = [:]
        for element in list {
            guard let id = element["id"]?.stringValue else { continue }
            result[id] = Suggestion(key: element["key"]?.stringValue, comment: element["comment"]?.stringValue)
        }
        return result
    }
}
