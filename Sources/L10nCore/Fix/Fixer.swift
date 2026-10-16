import Foundation
import SwiftParser
import SwiftSyntax

/// Turns code findings into an edit plan and applies it to Swift files and catalogs.
public struct Fixer {
    public let project: Project

    public static let fixableRules: Set<String> = [Rules.unlocalized.id, Rules.textAsKey.id, Rules.concatenation.id, Rules.nonTextLiteral.id]

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
        let catalogIndex = Linter.CatalogKeyIndex(project.catalogURLs.compactMap { catalogs[$0] })
        let suggester = KeySuggester(policy: project.config.keys)
        // Generated symbol → key, so symbol-style code also shows which keys a type uses.
        var keysBySymbol: [String: String] = [:]
        for url in project.catalogURLs {
            for (key, entry) in catalogs[url]?.entries ?? [] where entry.isManual {
                if let symbol = SymbolNaming.bareName(for: key), keysBySymbol[symbol] == nil { keysBySymbol[symbol] = key }
            }
        }

        var items: [FixItem] = []
        var plannedKeys: [String: [ByteKey: String]] = [:]   // catalog → key → sourceValue
        var plannedGroups: [PlannedGroup: String] = [:]       // same catalog, scope, role and text → key
        var fileHashes: [String: String] = [:]

        for url in linter.selectedSwiftFiles(files) {
            let source = try SourceText.read(url)
            let relative = project.relativePath(url)
            // Symbol naming constraints only matter where this file's rewrites use symbols.
            let fileUsesSymbols = project.usesSymbols(for: url)
            let scan = fixableFindings(source: source.text, relative: relative, fileURL: url, linter: linter, options: options, catalogs: catalogIndex)
            var siblings = Self.referencedKeys(in: scan.sites)
            for (type, names) in ProjectIndex.implicitMembers(in: source.text) {
                siblings[type, default: []] += names.compactMap { keysBySymbol[$0] }
            }
            for (site, diagnostic) in scan.findings {
                if let findingIDs, !findingIDs.contains(diagnostic.id) { continue }
                fileHashes[relative] = Hashing.sha256(source.text)

                guard let catalogURL = catalogURL(for: site, fileURL: url) else {
                    items.append(FixItem(
                        id: diagnostic.id, rule: diagnostic.rule, file: relative, line: site.line, column: site.column,
                        status: .skipped,
                        reason: "several catalogs could own this file; add a catalogRoutes entry to \(L10nConfig.fileName)",
                        original: site.originalCode, key: "", comment: "", sourceValue: site.staticText, placeholders: [],
                        catalog: "", replacement: "", context: site.context, api: site.api, role: site.role,
                        enclosingType: site.enclosingType, range: site.replaceRange, segments: site.segments,
                        reusesExistingKey: false, migrateFrom: nil
                    ))
                    continue
                }
                let catalogPath = project.relativePath(catalogURL)
                let catalog = catalogs[catalogURL] ?? StringCatalog.empty(url: catalogURL, sourceLanguage: project.sourceLanguage)

                if site.kind == .nonText, let key = site.key {
                    // No code change: the extracted key becomes a "Don't translate" entry.
                    items.append(FixItem(
                        id: diagnostic.id, rule: diagnostic.rule, file: relative, line: site.line, column: site.column,
                        status: .ready, reason: nil, original: site.originalCode, key: key, comment: "", sourceValue: key,
                        placeholders: [], catalog: catalogPath, replacement: site.originalCode, context: site.context,
                        api: site.api, role: site.role, enclosingType: site.enclosingType, range: site.replaceRange,
                        segments: site.segments, reusesExistingKey: catalog.contains(key), migrateFrom: nil, doNotTranslate: true
                    ))
                    continue
                }

                let placeholders = Self.placeholders(for: site)
                let sourceValue = Self.sourceValue(segments: site.segments, placeholders: placeholders)

                // New keys follow the keys this type (or file) already uses, e.g. `mac.settings.hotkey`.
                let prefix = suggester.projectPrefix(for: site, siblings: siblings, catalogKeys: catalog.entries.filter { $0.entry.isManual }.map(\.key))
                let scope = prefix ?? suggester.effectiveScope(for: site)
                let group = PlannedGroup(catalog: catalogPath, scope: scope, role: site.role, sourceValue: ByteKey(sourceValue))

                // Reuse an existing manual key or a key planned earlier for the same text.
                var key: String?
                var reuses = false
                let manualSymbols = Dictionary(grouping: catalog.entries.filter { $0.entry.isManual }.map(\.key), by: { SymbolNaming.bareName(for: $0) ?? $0 })
                let symbolIsClean: (String) -> Bool = { key in
                    !fileUsesSymbols || (SymbolNaming.symbol(for: key) != .reserved && (manualSymbols[SymbolNaming.bareName(for: key) ?? key]?.count ?? 0) <= 1)
                }
                // Existing keys are reused only within the same screen scope or from `common.`.
                let scopeMatches: (String) -> Bool = { key in key.hasPrefix(scope + ".") || key.hasPrefix("common.") }
                if let existing = catalog.entries.first(where: { $0.entry.isManual && scopeMatches($0.key) && $0.entry.localization(catalog.sourceLanguage)?.stringUnit?.value == sourceValue && symbolIsClean($0.key) }) {
                    key = existing.key
                    reuses = true
                } else if let planned = plannedGroups[group] {
                    key = planned
                }

                var migrateFrom: String?
                if site.kind == .localizedText, let textKey = site.key, let entry = catalog.entry(textKey), !entry.isManual {
                    migrateFrom = textKey
                }

                let existingSymbols = Set(catalog.entries.filter { $0.entry.isManual }.compactMap { SymbolNaming.bareName(for: $0.key) })
                    .union((plannedKeys[catalogPath] ?? [:]).keys.compactMap { SymbolNaming.bareName(for: $0.string) })
                let finalKey = key ?? suggester.suggest(for: site, prefix: prefix) { candidate in
                    catalog.contains(candidate) || plannedKeys[catalogPath]?[ByteKey(candidate)] != nil
                        || (fileUsesSymbols && existingSymbols.contains(SymbolNaming.bareName(for: candidate) ?? candidate))
                }
                plannedKeys[catalogPath, default: [:]][ByteKey(finalKey)] = sourceValue
                plannedGroups[group] = finalKey

                var comment = site.codeComment ?? suggester.comment(for: site, placeholders: placeholders)
                if let migrateFrom, let existingComment = catalog.entry(migrateFrom)?.comment, !existingComment.isEmpty {
                    comment = existingComment
                }

                var status = FixStatus.ready
                var reasons: [String] = []
                if let unfixable = site.unfixableReason {
                    status = .skipped
                    reasons.append(unfixable)
                } else if site.api == "LocalizedStringKey" {
                    status = .skipped
                    reasons.append("LocalizedStringKey(...) cannot take a generated symbol; rewrite manually")
                } else if site.context == .swiftUIKey, site.api.hasPrefix("AttributedString") {
                    status = .skipped
                    reasons.append("AttributedString(localized:) needs a manual rewrite")
                } else {
                    if site.heuristic {
                        status = .needsReview
                        reasons.append("found only by the name \(site.api); confirm it is shown to users")
                    }
                    if placeholders.contains(where: { !$0.confident }) {
                        status = .needsReview
                        reasons.append("placeholder types are guessed from names; confirm the specifiers")
                    }
                }

                var item = FixItem(
                    id: diagnostic.id,
                    rule: diagnostic.rule,
                    file: relative,
                    line: site.line,
                    column: site.column,
                    status: status,
                    reason: reasons.isEmpty ? nil : reasons.joined(separator: "; "),
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
                item.replacement = Self.replacement(for: item, usesSymbols: project.usesSymbols(for: url), table: catalog.tableName, moduleBundle: isInSwiftPackage(url))
                items.append(item)
            }
        }

        let style = project.codeStyleSummary(files: fileHashes.keys.sorted().map { project.root.appendingPathComponent($0) })
        return FixPlan(version: 1, codeStyle: style, files: fileHashes, items: items)
    }

    static func placeholders(for site: StringSite) -> [FixPlaceholder] {
        var index = 0
        return site.segments.compactMap { segment -> FixPlaceholder? in
            guard case .expression(let expression) = segment else { return nil }
            defer { index += 1 }
            let guess = PlaceholderGuess.guess(expression, declaredType: index < site.typeHints.count ? site.typeHints[index] : nil)
            return FixPlaceholder(expression: expression, specifier: guess.specifier, confident: guess.confident)
        }
    }

    /// Keys the file already looks up, by enclosing type (`""` for top level).
    static func referencedKeys(in sites: [StringSite]) -> [String: [String]] {
        var result: [String: [String]] = [:]
        for site in sites where site.kind == .localizedKey {
            guard let key = site.key else { continue }
            result[site.enclosingType ?? "", default: []].append(key)
        }
        return result
    }

    struct FileScan {
        var findings: [(StringSite, Diagnostic)]
        /// Every site in the file, fixable or not.
        var sites: [StringSite]
    }

    /// Sites with a fixable finding, honoring rule selection and inline suppressions.
    func fixableFindings(source: String, relative: String, fileURL: URL, linter: Linter, options: LintOptions, catalogs: Linter.CatalogKeyIndex) -> FileScan {
        let suppressions = Suppressions(source: source)
        let sites = linter.scanner.scan(source: source, path: relative)
        let keys = linter.fileKeys(for: fileURL, sites: sites, catalogs: catalogs)
        let findings = sites.compactMap { site in
            linter.codeDiagnostics(for: site, keys: keys, options: options)
                // Unfixable sites stay in the plan as skipped items (with the reason); findings
                // that are unfixable for another reason (a raw key shown as text) do not.
                .first { Self.fixableRules.contains($0.rule) && ($0.fixable || !site.fixable) && !suppressions.suppresses(rule: $0.rule, line: site.line) }
                .map { (site, $0) }
        }
        return FileScan(findings: findings, sites: sites)
    }

    /// Files inside a Swift package need `bundle: .module` for literal-style lookups.
    /// (Generated symbols already resolve the package bundle themselves.)
    func isInSwiftPackage(_ file: URL) -> Bool {
        PackageTarget.directory(for: file, root: project.root) != nil
    }

    /// The catalog a site's key belongs to, always resolved within the file's own target:
    /// package targets use catalogs inside the target, app files the nearest catalog for
    /// the table. A table without a catalog yet is created next to the file's default
    /// catalog, keeping its name (`Settings.xcstrings`), never folded into Localizable.
    /// `nil` when several catalogs could own the file and nothing disambiguates them.
    func catalogURL(for site: StringSite, fileURL: URL) -> URL? {
        let inPackage = PackageTarget.directory(for: fileURL, root: project.root) != nil
        if site.table == nil, !inPackage {
            // No explicit table: the configured catalog, else the file's default catalog
            // (nearest Localizable.xcstrings, or the project's only catalog).
            if let configured = project.config.catalog {
                return project.root.appendingPathComponent(configured).standardizedFileURL
            }
            let localizable = project.catalogURLs(forTable: "Localizable", file: fileURL)
            if localizable.count == 1 { return localizable[0] }
            if localizable.isEmpty, let fallback = project.defaultCatalogURL(for: fileURL),
               PackageTarget.directory(for: fallback, root: project.root) == nil {
                return fallback
            }
        }
        let table = site.table ?? "Localizable"
        let candidates = project.catalogURLs(forTable: table, file: fileURL)
        if candidates.count == 1 { return candidates[0] }
        // Several equally plausible catalogs: never guess (the key could land in another
        // target's bundle). A `catalogRoutes` entry resolves it.
        if candidates.count > 1 { return nil }
        return newCatalogDirectory(for: fileURL).appendingPathComponent("\(table).xcstrings").standardizedFileURL
    }

    /// Where a new catalog for `fileURL` goes: its package target, the folder of the file's
    /// default catalog, or the topmost source folder.
    func newCatalogDirectory(for fileURL: URL) -> URL {
        if let routed = project.routedCatalogDirectory(for: fileURL) { return routed }
        if let target = PackageTarget.directory(for: fileURL, root: project.root) {
            let filePath = fileURL.standardizedFileURL.path
            let inTarget = project.catalogURLs.filter { $0.path.hasPrefix(target.path + "/") && filePath.hasPrefix($0.deletingLastPathComponent().path + "/") }
            return inTarget.max(by: { $0.path.count < $1.path.count })?.deletingLastPathComponent() ?? target
        }
        let localizable = project.catalogURLs(forTable: "Localizable", file: fileURL)
        if localizable.count == 1 {
            return localizable[0].deletingLastPathComponent()
        }
        let firstComponent = project.relativePath(fileURL).split(separator: "/").first.map(String.init)
        return firstComponent.flatMap { component -> URL? in
            component.hasSuffix(".swift") ? nil : project.root.appendingPathComponent(component)
        } ?? project.root
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
            // The declaration's type gives the implicit member its context.
            case .resourceValue: return reference
            case .swiftUIKey, .string, .stringLocalizedCall, .nsLocalizedCall: return "String(localized: \(reference))"
            }
        }
        let literal = swiftLiteral(item.segments)
        let isResource = item.context == .resourceCall || item.context == .resourceValue
        // `String(localized:bundle:)` takes a Bundle; LocalizedStringResource takes a BundleDescription.
        let bundleArgument = moduleBundle ? (isResource ? ", bundle: .atURL(Bundle.module.bundleURL)" : ", bundle: .module") : ""
        let tableArgument = (table == "Localizable" ? "" : ", table: \(swiftLiteral([.text(table)]))") + bundleArgument
        let commentArgument = item.comment.isEmpty ? "" : ", comment: \(swiftLiteral([.text(item.comment)]))"
        let keyLiteral = swiftLiteral([.text(item.key)])
        switch item.context {
        case .resourceCall, .resourceValue:
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
            if item.doNotTranslate == true {
                lines.append("  = \(item.original) (code unchanged)")
                lines.append("    \(item.catalog): mark \"\(item.key)\" Don't translate")
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

    /// Re-validates a saved (possibly edited) plan against the project without writing:
    /// replacements, catalog values and comments are recomputed from the edited key,
    /// comment and specifiers, exactly as `apply` would write them.
    public func refresh(_ plan: FixPlan) throws -> FixPlan {
        let prepared = try prepare(plan, includeReview: true)
        // Edits that apply would drop (overlapping, or breaking the file's syntax) show as skipped.
        let rewrite = Self.rewrite(prepared.accepted.map(\.item), sources: prepared.sources)
        var refreshed = plan
        refreshed.items = plan.items.enumerated().map { index, item in
            if var updated = prepared.accepted.first(where: { $0.index == index })?.item {
                if let reason = rewrite.skipped[updated.id] {
                    updated.status = .skipped
                    updated.reason = reason
                    return updated
                }
                updated.status = item.status
                // A guessed-placeholder note no longer applies once the item is marked ready.
                if updated.status == .ready { updated.reason = nil }
                return updated
            }
            guard item.status != .skipped else { return item }
            var skipped = item
            skipped.status = .skipped
            skipped.reason = prepared.skipped[index] ?? "cannot be applied"
            return skipped
        }
        return refreshed
    }

    // MARK: Applying

    public func apply(_ plan: FixPlan, includeReview: Bool = false) throws -> ApplyResult {
        try ProjectLock.withLock(root: project.root) {
            try applyLocked(plan, includeReview: includeReview)
        }
    }

    /// The validated part of a plan, computed in memory.
    struct Prepared {
        var sources: [String: SourceText] = [:]
        /// Accepted items with their index in the plan.
        var accepted: [(index: Int, item: FixItem)] = []
        /// Plan index → reason.
        var skipped: [Int: String] = [:]
        var catalogs: [String: StringCatalog] = [:]
        var index = ProjectIndex()
    }

    /// Validates a plan. The plan is treated as untrusted input (it may come from an agent or
    /// a file someone edited): every item is matched against a fresh scan of its file, code
    /// and placeholder expressions come from that scan, and only `key`, `comment`,
    /// `placeholders[].specifier` and `status` are taken from the plan.
    func prepare(_ plan: FixPlan, includeReview: Bool) throws -> Prepared {
        var prepared = Prepared()
        // The rewrite style follows the project, never the plan; it is decided per file below.
        let projectStyle = project.codeStyleSummary(files: plan.files.keys.sorted().map { project.root.appendingPathComponent($0) })
        guard plan.codeStyle == projectStyle else {
            throw L10nError.planConflict("the plan uses \(plan.codeStyle) style but the project uses \(projectStyle); re-run fix to plan again")
        }
        let linter = Linter(project: project)
        prepared.index = linter.index
        let options = LintOptions(rules: Self.fixableRules, code: true, catalogs: false)
        let projectFiles = Set(project.swiftFiles.map { project.relativePath($0) })
        let catalogIndex = Linter.CatalogKeyIndex(try project.catalogURLs.map { try StringCatalog.load($0) })

        // Refuse to apply onto files that changed since planning; re-scan the rest.
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
            prepared.sources[relative] = source
            freshSites[relative] = fixableFindings(source: source.text, relative: relative, fileURL: url, linter: linter, options: options, catalogs: catalogIndex).findings.map(\.0)
        }

        // (catalog, byte-exact key) → sourceValue
        var assignedValues: [CatalogKey: String] = [:]
        for (index, var item) in plan.items.enumerated() {
            func skip(_ reason: String) { prepared.skipped[index] = reason }
            let eligible = item.status == .ready || (includeReview && item.status == .needsReview)
            guard eligible else {
                skip(item.reason ?? item.status.rawValue)
                continue
            }
            let file = (try? PathUtil.resolveInside(item.file, root: project.root)).map(project.relativePath) ?? item.file
            guard let site = freshSites[file]?.first(where: { $0.replaceRange == item.range && $0.originalCode == item.original }), site.fixable else {
                skip("no matching fixable string at \(item.file):\(item.line)")
                continue
            }
            let fileURL = project.root.appendingPathComponent(file)
            guard let expectedURL = catalogURL(for: site, fileURL: fileURL) else {
                skip("several catalogs could own \(item.file); add a catalogRoutes entry")
                continue
            }
            let expectedCatalog = project.relativePath(expectedURL)
            guard let catalogURL = try? PathUtil.resolveInside(item.catalog, root: project.root) else {
                skip("catalog \(item.catalog) is outside the project")
                continue
            }
            let catalogPath = project.relativePath(catalogURL)
            guard catalogPath == expectedCatalog else {
                skip("catalog \(item.catalog) is not the catalog for this file (expected \(expectedCatalog)); re-run fix to plan again")
                continue
            }
            item.file = file
            item.catalog = catalogPath
            item.context = site.context
            item.segments = site.segments

            if site.kind == .nonText {
                // Only the extracted key is marked; the key always comes from the source.
                guard let key = site.key else { skip("no key to mark"); continue }
                item.key = key
                item.sourceValue = key
                item.placeholders = []
                item.replacement = site.originalCode
                item.doNotTranslate = true
                _ = try loadCatalog(catalogPath, into: &prepared)
                prepared.accepted.append((index, item))
                continue
            }
            item.doNotTranslate = nil

            // Code and placeholder expressions always come from the source, never from the plan.
            let expressions = site.segments.compactMap { if case .expression(let expression) = $0 { return expression } else { return nil } }
            guard item.placeholders.count == expressions.count else {
                skip("placeholders do not match the interpolations in the source")
                continue
            }
            var placeholderProblem: String?
            for (position, placeholder) in item.placeholders.enumerated() {
                let tokens = FormatSpecifier.tokens(in: placeholder.specifier)
                guard tokens.count == 1, tokens[0].text == placeholder.specifier, case .argument = tokens[0].kind, !tokens[0].isPositional else {
                    placeholderProblem = "invalid specifier \(placeholder.specifier)"
                    break
                }
                item.placeholders[position].expression = expressions[position]
            }
            if let placeholderProblem {
                skip(placeholderProblem)
                continue
            }
            item.comment = Self.updatingPlaceholderNotes(item.comment, placeholders: item.placeholders)
            item.sourceValue = Self.sourceValue(segments: item.segments, placeholders: item.placeholders)
            item.migrateFrom = site.kind == .localizedText ? site.key : nil
            let target = try loadCatalog(catalogPath, into: &prepared)

            let existing = target.entry(item.key)
            if existing == nil || existing?.isManual == false {
                let violations = project.config.keys.violations(for: item.key)
                if !violations.isEmpty {
                    skip("key \"\(item.key)\" \(violations.joined(separator: "; "))")
                    continue
                }
            }
            let fileUsesSymbols = project.usesSymbols(for: fileURL)
            if fileUsesSymbols, SymbolNaming.symbol(for: item.key) == .reserved {
                skip("key \"\(item.key)\" cannot generate a Swift symbol")
                continue
            }
            let assignmentKey = CatalogKey(catalog: catalogPath, key: ByteKey(item.key))
            if let assigned = assignedValues[assignmentKey] {
                if assigned != item.sourceValue {
                    skip("key \"\(item.key)\" is planned twice with different text")
                    continue
                }
            } else if let existing {
                guard existing.isManual, existing.localization(target.sourceLanguage)?.stringUnit?.value == item.sourceValue else {
                    skip("key \"\(item.key)\" already exists with different text")
                    continue
                }
            }
            if fileUsesSymbols, let symbol = SymbolNaming.bareName(for: item.key) {
                let clashes = target.entries.contains { $0.entry.isManual && $0.key != item.key && SymbolNaming.bareName(for: $0.key) == symbol }
                    || assignedValues.keys.contains { $0.catalog == catalogPath && $0 != assignmentKey && SymbolNaming.bareName(for: $0.key.string) == symbol }
                if clashes {
                    skip("key \"\(item.key)\" generates the same Swift symbol as another key")
                    continue
                }
            }
            assignedValues[assignmentKey] = item.sourceValue
            item.reusesExistingKey = existing != nil
            item.replacement = Self.replacement(for: item, usesSymbols: fileUsesSymbols, table: target.tableName, moduleBundle: isInSwiftPackage(fileURL))
            prepared.accepted.append((index, item))
        }
        return prepared
    }

    private func loadCatalog(_ path: String, into prepared: inout Prepared) throws -> StringCatalog {
        if let loaded = prepared.catalogs[path] { return loaded }
        let url = try PathUtil.resolveInside(path, root: project.root)
        let loaded = FileManager.default.fileExists(atPath: url.path)
            ? try StringCatalog.load(url, fallbackSourceLanguage: project.sourceLanguage)
            : StringCatalog.empty(url: url, sourceLanguage: project.sourceLanguage)
        prepared.catalogs[path] = loaded
        return loaded
    }

    struct Rewrite {
        var pending: [String: SourceText] = [:]
        /// Items whose edit (or catalog-only change) will be applied.
        var applied: [FixItem] = []
        var skipped: [String: String] = [:]
    }

    /// Applies accepted edits to the sources in memory, last edit first so offsets stay
    /// valid. Overlapping edits and files whose syntax would break are left out.
    static func rewrite(_ accepted: [FixItem], sources: [String: SourceText]) -> Rewrite {
        var result = Rewrite()
        result.applied = accepted.filter { $0.doNotTranslate == true }
        for (file, entries) in Dictionary(grouping: accepted.filter { $0.doNotTranslate != true }, by: { $0.file }).sorted(by: { $0.key < $1.key }) {
            guard let source = sources[file] else { continue }
            var bytes = Array(source.text.utf8)
            let originalErrors = syntaxErrorCount(source.text)
            var lowestStart = Int.max
            var fileItems: [FixItem] = []
            for item in entries.sorted(by: { $0.range.start > $1.range.start }) {
                guard item.range.start >= 0, item.range.start <= item.range.end, item.range.end <= bytes.count, item.range.end <= lowestStart else {
                    result.skipped[item.id] = "overlaps another fix"
                    continue
                }
                bytes.replaceSubrange(item.range.start..<item.range.end, with: Array(item.replacement.utf8))
                lowestStart = item.range.start
                fileItems.append(item)
            }
            let updated = String(decoding: bytes, as: UTF8.self)
            guard syntaxErrorCount(updated) <= originalErrors else {
                for item in fileItems { result.skipped[item.id] = "rewrite produced invalid Swift syntax" }
                continue
            }
            guard !fileItems.isEmpty else { continue }
            result.pending[file] = SourceText(text: updated, hasBOM: source.hasBOM)
            result.applied += fileItems
        }
        return result
    }

    /// Keeps generated notes such as "%@ is keyCode." in step with edited specifiers.
    static func updatingPlaceholderNotes(_ comment: String, placeholders: [FixPlaceholder]) -> String {
        var result = comment
        for (index, placeholder) in placeholders.enumerated() {
            let position = placeholders.count > 1 ? "%\(index + 1)\\$" : "%(?![0-9]+\\$)"
            let pattern = position + "[A-Za-z@]+ is " + NSRegularExpression.escapedPattern(for: placeholder.expression) + "(?=[.;]|$)"
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let note = "\(placeholders.count > 1 ? "%\(index + 1)$" : "%")\(placeholder.specifier.dropFirst()) is \(placeholder.expression)"
            result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: NSRegularExpression.escapedTemplate(for: note))
        }
        return result
    }

    private func applyLocked(_ plan: FixPlan, includeReview: Bool) throws -> ApplyResult {
        var result = ApplyResult(applied: [], skipped: [:], filesChanged: [], catalogsChanged: [], keysAdded: [], notes: [])
        let projectCatalogs = Set(project.catalogURLs.map { project.relativePath($0) })

        // 1. Validate items against the fresh scan and the catalogs.
        var prepared = try prepare(plan, includeReview: includeReview)
        for (index, reason) in prepared.skipped { result.skipped[plan.items[index].id] = reason }
        let sources = prepared.sources
        var catalogs = prepared.catalogs
        let accepted = prepared.accepted.map(\.item)

        // Load all remaining state that can fail before any source file is written, so a
        // broken fingerprints file cannot leave code pointing at keys that were never added.
        var fingerprints = try FingerprintStore.load(root: project.root)

        // 2. Compute the rewritten code (in memory), last edit first so offsets stay valid.
        let rewrite = Self.rewrite(accepted, sources: sources)
        result.skipped.merge(rewrite.skipped) { first, _ in first }
        let pendingSources = rewrite.pending
        let appliedItems = rewrite.applied
        result.filesChanged = pendingSources.keys.sorted()

        // 3. Catalog changes, only for code edits that were applied.
        // English-text keys still used by code that was not rewritten stay live.
        var referencedTextKeys: Set<CatalogKey> = []   // table + byte-exact key
        if appliedItems.contains(where: { $0.migrateFrom != nil }) {
            let scanner = Linter(project: project, index: prepared.index).scanner
            for url in project.swiftFiles {
                let relative = project.relativePath(url)
                guard let source = pendingSources[relative] ?? (try? SourceText.read(url)) else { continue }
                for site in scanner.scan(source: source.text, path: relative) where site.kind == .localizedText || site.kind == .localizedKey {
                    if let key = site.key { referencedTextKeys.insert(CatalogKey(catalog: site.table ?? "Localizable", key: ByteKey(key))) }
                }
            }
        }
        var added: Set<CatalogKey> = []
        for item in appliedItems.sorted(by: { ($0.file, $0.range.start) < ($1.file, $1.range.start) }) {
            if catalogs[item.catalog] == nil { catalogs[item.catalog] = try loadCatalog(item.catalog, into: &prepared) }
            var target = catalogs[item.catalog]!
            let isNewKey = target.entry(item.key) == nil
            if item.doNotTranslate == true {
                var entry = target.entry(item.key) ?? CatalogEntry()
                entry.shouldTranslate = false
                target.setEntry(item.key, entry)
                catalogs[item.catalog] = target
                if isNewKey, added.insert(CatalogKey(catalog: item.catalog, key: ByteKey(item.key))).inserted {
                    result.keysAdded.append(item.key)
                }
                continue
            }
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
                var sameText = oldSource.leaves.map(\.unit.value) == [item.sourceValue]
                // Source-language plural/device variations move with the key, so the source
                // language keeps its forms after the code switches to the semantic key.
                if isNewKey, let oldSourceNode = old.localization(target.sourceLanguage),
                   !oldSourceNode.variations.isEmpty || !oldSourceNode.substitutions.isEmpty {
                    entry.setLocalization(target.sourceLanguage, oldSourceNode)
                    sameText = true
                }
                let newFingerprint = FingerprintStore.sourceFingerprint(entry.sourceNode(key: item.key, sourceLanguage: target.sourceLanguage))
                for locale in old.localizationLocales where locale != target.sourceLanguage {
                    guard let node = old.localization(locale) else { continue }
                    if let existing = entry.localization(locale) {
                        // Keep every leaf the semantic key already has; add the ones it lacks.
                        entry.setLocalization(locale, LocalizationNode(raw: Self.mergeMissing(into: existing.raw, from: node.raw)))
                        continue
                    }
                    entry.setLocalization(locale, node)
                    if sameText {
                        fingerprints.set(catalog: item.catalog, key: item.key, locale: locale, fingerprint: newFingerprint)
                    }
                }
                // Mark the English-text key stale once no code references it anymore
                // (Xcode recomputes extractionState on the next build either way).
                if !referencedTextKeys.contains(CatalogKey(catalog: target.tableName, key: ByteKey(migrateFrom))) {
                    old.extractionState = "stale"
                    target.setEntry(migrateFrom, old)
                }
            }
            target.setEntry(item.key, entry)
            if project.usesSymbols(for: project.root.appendingPathComponent(item.file)), target.version == "1.0" {
                target.version = "1.1"
                result.notes.append("\(item.catalog): upgraded catalog format to 1.1 for generated symbols")
            }
            catalogs[item.catalog] = target
            if isNewKey, added.insert(CatalogKey(catalog: item.catalog, key: ByteKey(item.key))).inserted {
                result.keysAdded.append(item.key)
            }
        }

        // 4. Commit: catalogs and fingerprints first, then code. If any write fails, every
        // file written so far is restored, so code never points at keys that were not added.
        var transaction = FileTransaction()
        do {
            for (path, catalog) in catalogs.sorted(by: { $0.key < $1.key }) {
                if try transaction.write(catalog.serialized(), to: catalog.url) {
                    result.catalogsChanged.append(path)
                }
            }
            if !result.catalogsChanged.isEmpty {
                _ = try transaction.write(fingerprints.serialized(), to: fingerprints.url)
            }
            for (file, source) in pendingSources.sorted(by: { $0.key < $1.key }) {
                _ = try transaction.write(source.data, to: try PathUtil.resolveInside(file, root: project.root))
            }
        } catch {
            transaction.rollBack()
            throw error
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

    /// Adds members of `source` that `destination` lacks, recursively; `destination` always
    /// wins. Nodes whose shape differs (plain `stringUnit` vs `variations`) are not mixed.
    static func mergeMissing(into destination: JSONObject, from source: JSONObject) -> JSONObject {
        let destinationPlain = destination.contains("stringUnit")
        let destinationVaried = destination.contains("variations")
        if (destinationPlain && source.contains("variations") && !destinationVaried)
            || (destinationVaried && source.contains("stringUnit") && !destinationPlain) {
            return destination
        }
        var merged = destination
        for member in source.members {
            if let existing = merged[member.key] {
                if case .object(let existingObject) = existing, case .object(let sourceObject) = member.value, member.key != "stringUnit" {
                    merged[member.key] = .object(mergeMissing(into: existingObject, from: sourceObject))
                }
            } else {
                merged[member.key] = member.value
            }
        }
        return merged
    }

    /// A catalog (or table) plus a byte-exact key.
    struct CatalogKey: Hashable {
        var catalog: String
        var key: ByteKey
    }

    struct PlannedGroup: Hashable {
        var catalog: String
        var scope: String
        var role: String
        var sourceValue: ByteKey
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
