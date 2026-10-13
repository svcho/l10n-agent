import Foundation
import SwiftParser
import SwiftSyntax

/// Turns code findings into an edit plan and applies it to Swift files and catalogs.
public struct Fixer {
    public let project: Project

    public static let fixableRules: Set<String> = [Rules.unlocalized.id, Rules.textAsKey.id, Rules.concatenation.id]

    public init(project: Project) {
        self.project = project
    }

    // MARK: Planning

    public func plan(rules: Set<String>? = nil, files: [String]? = nil, findingIDs: Set<String>? = nil) throws -> FixPlan {
        let linter = Linter(project: project)
        let wantedRules = (rules ?? Self.fixableRules).compactMap { Rules.info($0)?.id }.filter(Self.fixableRules.contains)
        let options = LintOptions(rules: Set(wantedRules), files: files, code: true, catalogs: false)

        var catalogs: [URL: StringCatalog] = [:]
        for url in project.catalogURLs {
            catalogs[url] = try StringCatalog.load(url)
        }
        let suggester = KeySuggester(policy: project.config.keys)
        let usesSymbols = project.usesSymbols

        var items: [FixItem] = []
        var plannedKeys: [String: [String: String]] = [:]   // catalog → key → sourceValue
        var plannedGroups: [String: String] = [:]             // catalog|scope|role|sourceValue → key
        var fileHashes: [String: String] = [:]

        for url in linter.selectedSwiftFiles(files) {
            let source = try SourceText.read(url)
            let relative = project.relativePath(url)
            for (site, diagnostic) in fixableFindings(source: source.text, relative: relative, linter: linter, options: options) {
                if let findingIDs, !findingIDs.contains(diagnostic.id) { continue }
                fileHashes[relative] = Hashing.sha256(source.text)

                let catalogURL = catalogURL(for: site, fileURL: url)
                let catalogPath = project.relativePath(catalogURL)
                let catalog = catalogs[catalogURL] ?? StringCatalog.empty(url: catalogURL, sourceLanguage: project.sourceLanguage)

                let placeholders = site.segments.compactMap { segment -> FixPlaceholder? in
                    guard case .expression(let expression) = segment else { return nil }
                    let guess = PlaceholderGuess.guess(expression)
                    return FixPlaceholder(expression: expression, specifier: guess.specifier, confident: guess.confident)
                }
                let sourceValue = Self.sourceValue(segments: site.segments, placeholders: placeholders)

                // Reuse an existing manual key or a key planned earlier for the same text.
                var key: String?
                var reuses = false
                let manualSymbols = Dictionary(grouping: catalog.entries.filter { $0.entry.isManual }.map(\.key), by: { SymbolNaming.bareName(for: $0) ?? $0 })
                let symbolIsClean: (String) -> Bool = { key in
                    !usesSymbols || (SymbolNaming.symbol(for: key) != .reserved && (manualSymbols[SymbolNaming.bareName(for: key) ?? key]?.count ?? 0) <= 1)
                }
                // Existing keys are reused only within the same screen scope or from `common.`.
                let scope = suggester.effectiveScope(for: site)
                let scopeMatches: (String) -> Bool = { key in key.hasPrefix(scope + ".") || key.hasPrefix("common.") }
                if let existing = catalog.entries.first(where: { $0.entry.isManual && scopeMatches($0.key) && $0.entry.localization(catalog.sourceLanguage)?.stringUnit?.value == sourceValue && symbolIsClean($0.key) }) {
                    key = existing.key
                    reuses = true
                } else if let planned = plannedGroups["\(catalogPath)|\(suggester.effectiveScope(for: site))|\(site.role)|\(sourceValue)"] {
                    key = planned
                }

                var migrateFrom: String?
                if site.kind == .localizedText, let textKey = site.key, let entry = catalog.entry(textKey), !entry.isManual {
                    migrateFrom = textKey
                }

                let existingSymbols = Set(catalog.entries.filter { $0.entry.isManual }.compactMap { SymbolNaming.bareName(for: $0.key) })
                    .union((plannedKeys[catalogPath] ?? [:]).keys.compactMap { SymbolNaming.bareName(for: $0) })
                let finalKey = key ?? suggester.suggest(for: site) { candidate in
                    catalog.contains(candidate) || plannedKeys[catalogPath]?[candidate] != nil
                        || (usesSymbols && existingSymbols.contains(SymbolNaming.bareName(for: candidate) ?? candidate))
                }
                plannedKeys[catalogPath, default: [:]][finalKey] = sourceValue
                plannedGroups["\(catalogPath)|\(suggester.effectiveScope(for: site))|\(site.role)|\(sourceValue)"] = finalKey

                var comment = site.codeComment ?? suggester.comment(for: site, placeholders: placeholders)
                if let migrateFrom, let existingComment = catalog.entry(migrateFrom)?.comment, !existingComment.isEmpty {
                    comment = existingComment
                }

                var status = FixStatus.ready
                var reason: String?
                if let unfixable = site.unfixableReason {
                    status = .skipped
                    reason = unfixable
                } else if site.api == "LocalizedStringKey" {
                    status = .skipped
                    reason = "LocalizedStringKey(...) cannot take a generated symbol; rewrite manually"
                } else if site.context == .swiftUIKey, site.api.hasPrefix("AttributedString") {
                    status = .skipped
                    reason = "AttributedString(localized:) needs a manual rewrite"
                } else if placeholders.contains(where: { !$0.confident }) {
                    status = .needsReview
                    reason = "placeholder types are guessed from names; confirm the specifiers"
                }

                var item = FixItem(
                    id: diagnostic.id,
                    rule: diagnostic.rule,
                    file: relative,
                    line: site.line,
                    column: site.column,
                    status: status,
                    reason: reason,
                    original: site.originalCode,
                    key: finalKey,
                    comment: comment,
                    sourceValue: sourceValue,
                    placeholders: placeholders,
                    catalog: catalogPath,
                    replacement: "",
                    context: site.context,
                    api: site.api,
                    role: site.role,
                    enclosingType: site.enclosingType,
                    range: site.replaceRange,
                    segments: site.segments,
                    reusesExistingKey: reuses,
                    migrateFrom: migrateFrom
                )
                item.replacement = Self.replacement(for: item, usesSymbols: usesSymbols, table: catalog.tableName, moduleBundle: isInSwiftPackage(url))
                items.append(item)
            }
        }

        return FixPlan(version: 1, codeStyle: usesSymbols ? CodeStyle.symbols.rawValue : CodeStyle.literal.rawValue, files: fileHashes, items: items)
    }

    /// Sites with a fixable finding, honoring rule selection and inline suppressions.
    func fixableFindings(source: String, relative: String, linter: Linter, options: LintOptions) -> [(StringSite, Diagnostic)] {
        let suppressions = Suppressions(source: source)
        return SwiftScanner(userFacing: project.config.userFacing).scan(source: source, path: relative).compactMap { site in
            linter.codeDiagnostics(for: site, keysByTable: [:], options: options)
                .first { Self.fixableRules.contains($0.rule) && !suppressions.suppresses(rule: $0.rule, line: site.line) }
                .map { (site, $0) }
        }
    }

    /// Files inside a Swift package need `bundle: .module` for literal-style lookups.
    /// (Generated symbols already resolve the package bundle themselves.)
    func isInSwiftPackage(_ file: URL) -> Bool {
        PackageTarget.directory(for: file, root: project.root) != nil
    }

    func catalogURL(for site: StringSite, fileURL: URL) -> URL {
        // Package targets bundle their own resources: keep their catalogs inside the target.
        if let target = PackageTarget.directory(for: fileURL, root: project.root) {
            let inTarget = project.catalogURLs.filter { $0.path.hasPrefix(target.path + "/") }
            if let table = site.table, let match = inTarget.first(where: { $0.deletingPathExtension().lastPathComponent == table }) {
                return match
            }
            let filePath = fileURL.standardizedFileURL.path
            if let nearest = inTarget.filter({ $0.lastPathComponent == "Localizable.xcstrings" && filePath.hasPrefix($0.deletingLastPathComponent().path + "/") })
                .max(by: { $0.path.count < $1.path.count }) {
                return nearest
            }
            return target.appendingPathComponent("Localizable.xcstrings").standardizedFileURL
        }
        if let table = site.table, let match = project.catalogURLs.first(where: { $0.deletingPathExtension().lastPathComponent == table }) {
            return match
        }
        if let url = project.defaultCatalogURL(for: fileURL) { return url }
        // No catalog yet: create Localizable.xcstrings next to the topmost source folder.
        let firstComponent = project.relativePath(fileURL).split(separator: "/").first.map(String.init)
        let directory = firstComponent.flatMap { component -> URL? in
            component.hasSuffix(".swift") ? nil : project.root.appendingPathComponent(component)
        } ?? project.root
        return directory.appendingPathComponent("Localizable.xcstrings").standardizedFileURL
    }

    // MARK: Code generation

    /// Catalog value for a literal: interpolations become format specifiers, `%` is escaped
    /// when arguments are present.
    public static func sourceValue(segments: [LiteralSegment], placeholders: [FixPlaceholder]) -> String {
        let hasArguments = !placeholders.isEmpty
        var index = 0
        return segments.map { segment -> String in
            switch segment {
            case .text(let text):
                return hasArguments ? text.replacingOccurrences(of: "%", with: "%%") : text
            case .expression:
                defer { index += 1 }
                return index < placeholders.count ? placeholders[index].specifier : "%@"
            }
        }.joined()
    }

    public static func replacement(for item: FixItem, usesSymbols: Bool, table: String, moduleBundle: Bool = false) -> String {
        if usesSymbols {
            guard let reference = SymbolNaming.reference(for: item.key, table: table, arguments: item.placeholders.map(\.expression)) else { return item.original }
            switch item.context {
            case .swiftUIText: return "Text(\(reference))"
            case .resourceCall: return "LocalizedStringResource\(reference)"
            case .swiftUIKey, .string, .stringLocalizedCall, .nsLocalizedCall: return "String(localized: \(reference))"
            }
        }
        let literal = swiftLiteral(item.segments)
        let tableArgument = (table == "Localizable" ? "" : ", table: \(swiftLiteral([.text(table)]))") + (moduleBundle ? ", bundle: .module" : "")
        let commentArgument = item.comment.isEmpty ? "" : ", comment: \(swiftLiteral([.text(item.comment)]))"
        let keyLiteral = swiftLiteral([.text(item.key)])
        switch item.context {
        case .resourceCall:
            return "LocalizedStringResource(\(keyLiteral), defaultValue: \(literal)\(tableArgument)\(commentArgument))"
        case .swiftUIText:
            return "Text(String(localized: \(keyLiteral), defaultValue: \(literal)\(tableArgument)\(commentArgument)))"
        case .swiftUIKey, .string, .stringLocalizedCall, .nsLocalizedCall:
            return "String(localized: \(keyLiteral), defaultValue: \(literal)\(tableArgument)\(commentArgument))"
        }
    }

    static func swiftLiteral(_ segments: [LiteralSegment]) -> String {
        var output = "\""
        for segment in segments {
            switch segment {
            case .expression(let expression):
                output += "\\(\(expression))"
            case .text(let text):
                for scalar in text.unicodeScalars {
                    switch scalar {
                    case "\\": output += "\\\\"
                    case "\"": output += "\\\""
                    case "\n": output += "\\n"
                    case "\r": output += "\\r"
                    case "\t": output += "\\t"
                    case "\0": output += "\\0"
                    default:
                        if scalar.value < 0x20 || scalar.value == 0x7F {
                            output += "\\u{\(String(scalar.value, radix: 16))}"
                        } else {
                            output.unicodeScalars.append(scalar)
                        }
                    }
                }
            }
        }
        return output + "\""
    }

    // MARK: Preview

    public static func preview(_ plan: FixPlan) -> String {
        var lines: [String] = []
        for item in plan.items {
            let marker: String
            switch item.status {
            case .ready: marker = "fix"
            case .needsReview: marker = "review"
            case .skipped: marker = "skip"
            }
            lines.append("[\(marker)] \(item.file):\(item.line):\(item.column) \(item.rule) \(item.id)")
            if item.status == .skipped {
                lines.append("    \(item.reason ?? "")")
                continue
            }
            lines.append("  - \(item.original)")
            lines.append("  + \(item.replacement)")
            let keyNote = item.reusesExistingKey ? "reuse" : "add"
            lines.append("    \(item.catalog): \(keyNote) \"\(item.key)\" = \"\(item.sourceValue)\"")
            lines.append("    comment: \(item.comment)")
            if let migrateFrom = item.migrateFrom { lines.append("    copies existing translations from \"\(migrateFrom)\"") }
            if let reason = item.reason { lines.append("    note: \(reason)") }
        }
        let ready = plan.items.filter { $0.status == .ready }.count
        let review = plan.items.filter { $0.status == .needsReview }.count
        let skipped = plan.items.filter { $0.status == .skipped }.count
        if !lines.isEmpty { lines.append("") }
        lines.append("\(ready) ready, \(review) need review, \(skipped) skipped")
        return lines.joined(separator: "\n")
    }

    // MARK: Applying

    public func apply(_ plan: FixPlan, includeReview: Bool = false) throws -> ApplyResult {
        try ProjectLock.withLock(root: project.root) {
            try applyLocked(plan, includeReview: includeReview)
        }
    }

    /// Applies a plan. The plan is treated as untrusted input (it may come from an agent or
    /// a file someone edited): every item is matched against a fresh scan of its file, code
    /// and placeholder expressions come from that scan, and only `key`, `comment`,
    /// `placeholders[].specifier` and `status` are taken from the plan.
    private func applyLocked(_ plan: FixPlan, includeReview: Bool) throws -> ApplyResult {
        var result = ApplyResult(applied: [], skipped: [:], filesChanged: [], catalogsChanged: [], keysAdded: [], notes: [])
        // The rewrite style follows the project, never the plan.
        let usesSymbols = project.usesSymbols
        let projectStyle = usesSymbols ? CodeStyle.symbols.rawValue : CodeStyle.literal.rawValue
        guard plan.codeStyle == projectStyle else {
            throw L10nError.planConflict("the plan uses \(plan.codeStyle) style but the project uses \(projectStyle); re-run fix to plan again")
        }
        let linter = Linter(project: project)
        let options = LintOptions(rules: Self.fixableRules, code: true, catalogs: false)
        let projectFiles = Set(project.swiftFiles.map { project.relativePath($0) })
        let projectCatalogs = Set(project.catalogURLs.map { project.relativePath($0) })

        // Refuse to apply onto files that changed since planning; re-scan the rest.
        var sources: [String: SourceText] = [:]
        var freshSites: [String: [StringSite]] = [:]
        for (file, hash) in plan.files.sorted(by: { $0.key < $1.key }) {
            let url = try PathUtil.resolveInside(file, root: project.root)
            let relative = project.relativePath(url)
            guard projectFiles.contains(relative) else {
                throw L10nError.planConflict("\(file) is not a Swift source file of this project")
            }
            let source = try SourceText.read(url)
            guard Hashing.sha256(source.text) == hash else {
                throw L10nError.planConflict("\(file) changed since the plan was created; re-run fix to plan again")
            }
            sources[relative] = source
            freshSites[relative] = fixableFindings(source: source.text, relative: relative, linter: linter, options: options).map(\.0)
        }

        var catalogs: [String: StringCatalog] = [:]
        func catalog(_ path: String) throws -> StringCatalog {
            if let loaded = catalogs[path] { return loaded }
            let url = try PathUtil.resolveInside(path, root: project.root)
            let loaded = FileManager.default.fileExists(atPath: url.path)
                ? try StringCatalog.load(url, fallbackSourceLanguage: project.sourceLanguage)
                : StringCatalog.empty(url: url, sourceLanguage: project.sourceLanguage)
            catalogs[path] = loaded
            return loaded
        }

        // 1. Validate items against the fresh scan and the catalogs.
        var accepted: [(item: FixItem, catalogPath: String)] = []
        var assignedValues: [String: String] = [:] // catalog|key → sourceValue
        for var item in plan.items {
            let eligible = item.status == .ready || (includeReview && item.status == .needsReview)
            guard eligible else {
                result.skipped[item.id] = item.reason ?? item.status.rawValue
                continue
            }
            let file = (try? PathUtil.resolveInside(item.file, root: project.root)).map(project.relativePath) ?? item.file
            guard let site = freshSites[file]?.first(where: { $0.replaceRange == item.range && $0.originalCode == item.original }), site.fixable else {
                result.skipped[item.id] = "no matching fixable string at \(item.file):\(item.line)"
                continue
            }
            let fileURL = project.root.appendingPathComponent(file)
            let expectedCatalog = project.relativePath(catalogURL(for: site, fileURL: fileURL))
            guard let catalogURL = try? PathUtil.resolveInside(item.catalog, root: project.root) else {
                result.skipped[item.id] = "catalog \(item.catalog) is outside the project"
                continue
            }
            let catalogPath = project.relativePath(catalogURL)
            guard catalogPath == expectedCatalog else {
                result.skipped[item.id] = "catalog \(item.catalog) is not the catalog for this file (expected \(expectedCatalog)); re-run fix to plan again"
                continue
            }

            // Code and placeholder expressions always come from the source, never from the plan.
            let expressions = site.segments.compactMap { if case .expression(let expression) = $0 { return expression } else { return nil } }
            guard item.placeholders.count == expressions.count else {
                result.skipped[item.id] = "placeholders do not match the interpolations in the source"
                continue
            }
            var placeholderProblem: String?
            for (index, placeholder) in item.placeholders.enumerated() {
                let tokens = FormatSpecifier.tokens(in: placeholder.specifier)
                guard tokens.count == 1, tokens[0].text == placeholder.specifier, case .argument = tokens[0].kind, !tokens[0].isPositional else {
                    placeholderProblem = "invalid specifier \(placeholder.specifier)"
                    break
                }
                item.placeholders[index].expression = expressions[index]
            }
            if let placeholderProblem {
                result.skipped[item.id] = placeholderProblem
                continue
            }
            item.segments = site.segments
            item.context = site.context
            item.file = file
            item.catalog = catalogPath
            item.sourceValue = Self.sourceValue(segments: item.segments, placeholders: item.placeholders)
            item.migrateFrom = site.kind == .localizedText ? site.key : nil
            let target = try catalog(catalogPath)

            let existing = target.entry(item.key)
            if existing == nil || existing?.isManual == false {
                let violations = project.config.keys.violations(for: item.key)
                if !violations.isEmpty {
                    result.skipped[item.id] = "key \"\(item.key)\" \(violations.joined(separator: "; "))"
                    continue
                }
            }
            if usesSymbols, SymbolNaming.symbol(for: item.key) == .reserved {
                result.skipped[item.id] = "key \"\(item.key)\" cannot generate a Swift symbol"
                continue
            }
            let assignmentKey = "\(catalogPath)|\(item.key)"
            if let assigned = assignedValues[assignmentKey] {
                if assigned != item.sourceValue {
                    result.skipped[item.id] = "key \"\(item.key)\" is planned twice with different text"
                    continue
                }
            } else if let existing {
                guard existing.isManual, existing.localization(target.sourceLanguage)?.stringUnit?.value == item.sourceValue else {
                    result.skipped[item.id] = "key \"\(item.key)\" already exists with different text"
                    continue
                }
            }
            if usesSymbols, let symbol = SymbolNaming.bareName(for: item.key) {
                let clashes = target.entries.contains { $0.entry.isManual && $0.key != item.key && SymbolNaming.bareName(for: $0.key) == symbol }
                    || assignedValues.keys.contains { $0.hasPrefix(catalogPath + "|") && $0 != assignmentKey && SymbolNaming.bareName(for: String($0.dropFirst(catalogPath.count + 1))) == symbol }
                if clashes {
                    result.skipped[item.id] = "key \"\(item.key)\" generates the same Swift symbol as another key"
                    continue
                }
            }
            assignedValues[assignmentKey] = item.sourceValue
            item.replacement = Self.replacement(for: item, usesSymbols: usesSymbols, table: target.tableName, moduleBundle: isInSwiftPackage(fileURL))
            accepted.append((item, catalogPath))
        }

        // 2. Rewrite code, last edit first so earlier offsets stay valid.
        var appliedItems: [FixItem] = []
        for (file, entries) in Dictionary(grouping: accepted, by: { $0.item.file }).sorted(by: { $0.key < $1.key }) {
            guard let source = sources[file] else { continue }
            var bytes = Array(source.text.utf8)
            let originalErrors = Self.syntaxErrorCount(source.text)
            var lowestStart = Int.max
            var fileItems: [FixItem] = []
            for item in entries.map(\.item).sorted(by: { $0.range.start > $1.range.start }) {
                guard item.range.start >= 0, item.range.start <= item.range.end, item.range.end <= bytes.count, item.range.end <= lowestStart else {
                    result.skipped[item.id] = "overlaps another fix"
                    continue
                }
                bytes.replaceSubrange(item.range.start..<item.range.end, with: Array(item.replacement.utf8))
                lowestStart = item.range.start
                fileItems.append(item)
            }
            let updated = String(decoding: bytes, as: UTF8.self)
            guard Self.syntaxErrorCount(updated) <= originalErrors else {
                for item in fileItems { result.skipped[item.id] = "rewrite produced invalid Swift syntax" }
                continue
            }
            guard !fileItems.isEmpty else { continue }
            try SourceText(text: updated, hasBOM: source.hasBOM).write(to: try PathUtil.resolveInside(file, root: project.root))
            result.filesChanged.append(file)
            appliedItems += fileItems
        }

        // 3. Catalog changes, only for code edits that were applied.
        var fingerprints = try FingerprintStore.load(root: project.root)
        var added: Set<String> = []
        for item in appliedItems.sorted(by: { ($0.file, $0.range.start) < ($1.file, $1.range.start) }) {
            var target = try catalog(item.catalog)
            let isNewKey = target.entry(item.key) == nil
            var entry: CatalogEntry
            if let existing = target.entry(item.key) {
                entry = existing
            } else {
                entry = CatalogEntry()
                entry.extractionState = "manual"
                entry.comment = item.comment.isEmpty ? nil : item.comment
                entry.setLocalization(target.sourceLanguage, LocalizationNode(unit: StringUnit(state: StringUnit.State.translated, value: item.sourceValue)))
            }
            if let migrateFrom = item.migrateFrom, migrateFrom != item.key, var old = target.entry(migrateFrom), !old.isManual {
                // Carry existing translations of the English-text key over to the semantic key.
                // Locales the semantic key already translates are kept as they are.
                let oldSource = old.sourceNode(key: migrateFrom, sourceLanguage: target.sourceLanguage)
                let sameText = oldSource.leaves.map(\.unit.value) == [item.sourceValue]
                let newFingerprint = FingerprintStore.sourceFingerprint(entry.sourceNode(key: item.key, sourceLanguage: target.sourceLanguage))
                for locale in old.localizationLocales where locale != target.sourceLanguage && entry.localization(locale) == nil {
                    guard let node = old.localization(locale) else { continue }
                    entry.setLocalization(locale, node)
                    if sameText {
                        fingerprints.set(catalog: item.catalog, key: item.key, locale: locale, fingerprint: newFingerprint)
                    }
                }
                // The English-text key is no longer referenced from this site. Xcode
                // recomputes extractionState on the next build if other code still uses it.
                old.extractionState = "stale"
                target.setEntry(migrateFrom, old)
            }
            target.setEntry(item.key, entry)
            if usesSymbols, target.version == "1.0" {
                target.version = "1.1"
                result.notes.append("\(item.catalog): upgraded catalog format to 1.1 for generated symbols")
            }
            catalogs[item.catalog] = target
            if isNewKey, added.insert("\(item.catalog)|\(item.key)").inserted {
                result.keysAdded.append(item.key)
            }
        }

        for (path, catalog) in catalogs.sorted(by: { $0.key < $1.key }) {
            let original = FileManager.default.fileExists(atPath: catalog.url.path) ? try Data(contentsOf: catalog.url) : nil
            if original != catalog.serialized() {
                try catalog.write()
                result.catalogsChanged.append(path)
            }
        }
        if !result.catalogsChanged.isEmpty {
            try fingerprints.save()
        }
        for created in result.catalogsChanged where !projectCatalogs.contains(created) {
            let url = project.root.appendingPathComponent(created)
            if let manifest = PackageTarget.manifest(containing: url, root: project.root) {
                let text = (try? String(contentsOf: manifest, encoding: .utf8)) ?? ""
                if !text.contains("defaultLocalization") {
                    result.notes.append("Created \(created) in a Swift package; add `defaultLocalization: \"\(project.sourceLanguage)\"` to \(project.relativePath(manifest)) so the catalog is bundled.")
                }
            } else {
                result.notes.append("Created \(created); make sure it is a member of your app target in Xcode.")
            }
        }
        result.applied = appliedItems.map(\.id)
        result.filesChanged.sort()
        result.catalogsChanged.sort()
        return result
    }

    static func syntaxErrorCount(_ source: String) -> Int {
        let tree = Parser.parse(source: source)
        final class Counter: SyntaxVisitor {
            var count = 0
            override func visit(_ token: TokenSyntax) -> SyntaxVisitorContinueKind {
                if token.presence == .missing { count += 1 }
                return .visitChildren
            }
            override func visit(_ node: UnexpectedNodesSyntax) -> SyntaxVisitorContinueKind {
                count += 1
                return .visitChildren
            }
        }
        let counter = Counter(viewMode: .all)
        counter.walk(tree)
        return counter.count
    }
}
