import Foundation

public struct LintOptions: Sendable {
    /// Restrict to these rule IDs or names. `nil` runs every enabled rule.
    public var rules: Set<String>?
    /// Restrict code scanning to these paths (relative to the project root).
    public var files: [String]?
    public var code: Bool
    public var catalogs: Bool

    public init(rules: Set<String>? = nil, files: [String]? = nil, code: Bool = true, catalogs: Bool = true) {
        self.rules = rules
        self.files = files
        self.code = code
        self.catalogs = catalogs
    }
}

/// Inline suppressions: `// l10n-agent:ignore [L10N001,…]` on the line or the line above,
/// and `// l10n-agent:disable-file [L10N001,…]` anywhere in the file.
struct Suppressions {
    private var lines: [Int: Set<String>] = [:]
    private var file: Set<String>?

    init(source: String) {
        for (offset, line) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            guard let range = line.range(of: "l10n-agent:") else { continue }
            let directive = line[range.upperBound...]
            let parts = directive.split(whereSeparator: { $0 == " " || $0 == "," || $0 == "\t" }).map(String.init)
            guard let command = parts.first else { continue }
            let rules = Set(parts.dropFirst().filter { $0.hasPrefix("L10N") || Rules.info($0) != nil }.map { Rules.info($0)?.id ?? $0 })
            let lineNumber = offset + 1
            switch command {
            case "ignore":
                let standalone = line.trimmingCharacters(in: .whitespaces).hasPrefix("//")
                let target = standalone ? lineNumber + 1 : lineNumber
                lines[target, default: []].formUnion(rules.isEmpty ? ["*"] : rules)
            case "disable-file":
                file = (file ?? []).union(rules.isEmpty ? ["*"] : rules)
            default:
                continue
            }
        }
    }

    func suppresses(rule: String, line: Int) -> Bool {
        if let file, file.contains("*") || file.contains(rule) { return true }
        guard let rules = lines[line] else { return false }
        return rules.contains("*") || rules.contains(rule)
    }
}

public struct Linter {
    public let project: Project

    public init(project: Project) {
        self.project = project
    }

    func severity(_ rule: RuleInfo) -> Severity {
        project.config.rules[rule.id] ?? project.config.rules[rule.name] ?? (
            rule.id == Rules.textAsKey.id && !project.config.semanticKeys ? .off :
            rule.id == Rules.keyStyle.id && !project.config.semanticKeys ? .off :
            rule.defaultSeverity
        )
    }

    func enabled(_ rule: RuleInfo, _ options: LintOptions) -> Bool {
        if let selected = options.rules, !selected.contains(rule.id), !selected.contains(rule.name) { return false }
        return severity(rule) != .off
    }

    public func run(_ options: LintOptions = LintOptions()) throws -> LintReport {
        var diagnostics: [Diagnostic] = []
        var summary = LintSummary()

        var catalogs: [StringCatalog] = []
        for url in project.catalogURLs {
            do {
                catalogs.append(try StringCatalog.load(url))
            } catch let error as L10nError {
                if enabled(Rules.catalogParse, options) {
                    diagnostics.append(Diagnostic(rule: Rules.catalogParse, severity: severity(Rules.catalogParse), message: error.description, file: project.relativePath(url), line: 1))
                }
            }
        }
        summary.catalogs = project.catalogURLs.count

        if options.code {
            let (codeDiagnostics, scanned) = try lintCode(catalogs: catalogs, options: options)
            diagnostics += codeDiagnostics
            summary.swiftFiles = scanned
        }
        if options.catalogs {
            diagnostics += try lintCatalogs(catalogs, options: options)
        }

        diagnostics.sort { lhs, rhs in
            if lhs.file != rhs.file { return lhs.file.utf8.lexicographicallyPrecedes(rhs.file.utf8) }
            if (lhs.line ?? 0) != (rhs.line ?? 0) { return (lhs.line ?? 0) < (rhs.line ?? 0) }
            if (lhs.column ?? 0) != (rhs.column ?? 0) { return (lhs.column ?? 0) < (rhs.column ?? 0) }
            return lhs.rule < rhs.rule
        }
        for diagnostic in diagnostics {
            switch diagnostic.severity {
            case .error: summary.errors += 1
            case .warning: summary.warnings += 1
            case .info: summary.infos += 1
            case .off: break
            }
        }
        return LintReport(diagnostics: diagnostics, summary: summary)
    }

    // MARK: Code

    /// Scans Swift files and returns the string sites, honoring file filters and suppressions.
    public func scanSites(files: [String]? = nil) throws -> [StringSite] {
        let scanner = SwiftScanner(userFacing: project.config.userFacing)
        var sites: [StringSite] = []
        for url in selectedSwiftFiles(files) {
            let source = try String(contentsOf: url, encoding: .utf8)
            sites += scanner.scan(source: source, path: project.relativePath(url))
        }
        return sites
    }

    func selectedSwiftFiles(_ files: [String]?) -> [URL] {
        guard let files, !files.isEmpty else { return project.swiftFiles }
        let wanted = Set(files.map { project.relativePath((try? PathUtil.resolveInside($0, root: project.root)) ?? project.root.appendingPathComponent($0)) })
        return project.swiftFiles.filter { url in
            let relative = project.relativePath(url)
            return wanted.contains(relative) || wanted.contains { relative.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
        }
    }

    func lintCode(catalogs: [StringCatalog], options: LintOptions) throws -> ([Diagnostic], Int) {
        let scanner = SwiftScanner(userFacing: project.config.userFacing)
        var diagnostics: [Diagnostic] = []
        let files = selectedSwiftFiles(options.files)
        // Keys are compared by exact bytes, like Xcode does.
        let keysByCatalog = Dictionary(catalogs.map { ($0.url.standardizedFileURL, Set($0.keys.map(ByteKey.init))) }, uniquingKeysWith: { first, _ in first })

        for url in files {
            let source = try String(contentsOf: url, encoding: .utf8)
            let relative = project.relativePath(url)
            let suppressions = Suppressions(source: source)
            let sites = scanner.scan(source: source, path: relative)
            // Keys this file can resolve, per table, from the catalogs of its own target.
            var keysByTable: [String: Set<ByteKey>] = [:]
            for table in Set(sites.map { $0.table ?? "Localizable" }) {
                keysByTable[table] = project.catalogURLs(forTable: table, file: url)
                    .reduce(into: Set<ByteKey>()) { $0.formUnion(keysByCatalog[$1.standardizedFileURL] ?? []) }
            }
            for site in sites {
                for diagnostic in codeDiagnostics(for: site, keysByTable: keysByTable, options: options)
                where !suppressions.suppresses(rule: diagnostic.rule, line: site.line) {
                    diagnostics.append(diagnostic)
                }
            }
        }
        return (diagnostics, files.count)
    }

    func codeDiagnostics(for site: StringSite, keysByTable: [String: Set<ByteKey>], options: LintOptions) -> [Diagnostic] {
        var result: [Diagnostic] = []
        func add(_ rule: RuleInfo, _ message: String, fixable: Bool) {
            guard enabled(rule, options) else { return }
            result.append(Diagnostic(rule: rule, severity: severity(rule), message: message, file: site.file, line: site.line, column: site.column, key: site.key, fixable: fixable, identity: site.displayText))
        }
        let quoted = "\"\(Self.abbreviate(site.displayText))\""

        switch site.kind {
        case .unlocalized:
            add(Rules.unlocalized, "\(quoted) is shown to users via \(site.api) but is not localized", fixable: site.fixable)
        case .localizedText:
            add(Rules.textAsKey, "\(quoted) is localized with its English text as key (\(site.api)); use a semantic key", fixable: site.fixable)
        case .localizedKey:
            if let key = site.key, !site.hasDefaultValue {
                let table = site.table ?? "Localizable"
                if !(keysByTable[table]?.contains(ByteKey(key)) ?? false) {
                    add(Rules.missingKey, "Key \"\(key)\" is not defined in \(table).xcstrings", fixable: false)
                }
            }
        case .concatenation:
            add(Rules.concatenation, "\(quoted) is built with + for \(site.api); use one localized string with interpolation", fixable: site.fixable)
        case .formatString:
            add(Rules.concatenation, "\(quoted) uses String(format:); use String(localized:) with interpolation", fixable: false)
        }

        if site.kind != .localizedKey, let plural = Self.pluralHint(site.segments) {
            add(Rules.pluralCandidate, "\"\(plural)\" interpolates a count into text; add a plural variation in the catalog", fixable: false)
        }
        return result
    }

    static func pluralHint(_ segments: [LiteralSegment]) -> String? {
        for (index, segment) in segments.enumerated() {
            guard case .expression(let expression) = segment,
                  PlaceholderGuess.guess(expression).specifier == "%lld",
                  index + 1 < segments.count, case .text(let next) = segments[index + 1]
            else { continue }
            let word = next.drop(while: { $0 == " " }).prefix(while: \.isLetter)
            if next.first == " ", word.count > 2, word.hasSuffix("s") {
                return "\\(\(expression))\(next.prefix(word.count + 1))"
            }
        }
        return nil
    }

    static func abbreviate(_ text: String) -> String {
        let flattened = text.replacingOccurrences(of: "\n", with: "\\n")
        return flattened.count > 60 ? String(flattened.prefix(57)) + "..." : flattened
    }

    // MARK: Catalogs

    func lintCatalogs(_ catalogs: [StringCatalog], options: LintOptions) throws -> [Diagnostic] {
        var diagnostics: [Diagnostic] = []
        let fingerprints = try FingerprintStore.load(root: project.root)
        let targetLocales = project.targetLocales(catalogs: catalogs)
        let projectSource = project.sourceLanguage

        for catalog in catalogs {
            let file = project.relativePath(catalog.url)
            let lines = Self.keyLines(catalog: catalog)
            let source = catalog.sourceLanguage
            func add(_ rule: RuleInfo, _ message: String, key: String?, locales: [String]? = nil, fixable: Bool = false) {
                guard enabled(rule, options) else { return }
                diagnostics.append(Diagnostic(rule: rule, severity: severity(rule), message: message, file: file, line: key.flatMap { lines[$0] } ?? 1, column: key == nil ? nil : 5, key: key, locales: locales, fixable: fixable, identity: locales?.joined(separator: ",") ?? ""))
            }

            if source != projectSource {
                add(Rules.sourceLanguageMismatch, "Catalog sourceLanguage is \"\(source)\" but the project source language is \"\(projectSource)\"", key: nil)
            }

            var manualKeys: [String] = []
            for (key, entry) in catalog.entries {
                if entry.isManual { manualKeys.append(key) }
                if entry.isStale {
                    add(Rules.unusedKey, "Key \"\(key)\" is no longer referenced in code (extractionState: stale)", key: key)
                    continue
                }
                if entry.isManual, project.config.semanticKeys {
                    let violations = project.config.keys.violations(for: key)
                    if !violations.isEmpty {
                        add(Rules.keyStyle, "Key \"\(key)\" \(violations.joined(separator: "; "))", key: key)
                    }
                }
                guard entry.shouldTranslate else { continue }
                let sourceNode = entry.sourceNode(key: key, sourceLanguage: source)
                let sourceText = sourceNode.leaves.first?.unit.value ?? key
                guard sourceText.contains(where: \.isLetter) else { continue }

                if entry.comment?.trimmingCharacters(in: .whitespaces).isEmpty ?? true {
                    add(Rules.missingComment, "Key \"\(key)\" has no comment for translators", key: key)
                }

                let currentFingerprint = FingerprintStore.sourceFingerprint(sourceNode)
                var missing: [String] = []
                var review: [String] = []
                var stale: [String] = []
                var identical: [String] = []

                for locale in targetLocales {
                    guard let target = entry.localization(locale) else {
                        missing.append(locale)
                        continue
                    }
                    let leaves = target.leaves
                    if !TranslationEngine.isComplete(target, source: sourceNode, locale: locale, overrides: project.config.pluralCategories) {
                        missing.append(locale)
                        continue
                    }
                    if leaves.contains(where: { $0.unit.state == StringUnit.State.needsReview }) {
                        review.append(locale)
                    }
                    if let recorded = fingerprints.fingerprint(catalog: file, key: key, locale: locale), recorded != currentFingerprint {
                        stale.append(locale)
                    }
                    for (name, substitution) in target.substitutions.sorted(by: { $0.key < $1.key }) {
                        guard let expected = sourceNode.substitutions[name] else { continue }
                        if substitution.argNum != expected.argNum || substitution.formatSpecifier != expected.formatSpecifier {
                            add(Rules.formatMismatch, "Translation \(locale) of \"\(key)\": substitution %#@\(name)@ uses argument \(substitution.argNum.map(String.init) ?? "?") (\(substitution.formatSpecifier ?? "?")) but the source uses \(expected.argNum.map(String.init) ?? "?") (\(expected.formatSpecifier ?? "?"))", key: key, locales: [locale])
                        }
                    }
                    for leaf in leaves {
                        guard let match = FormatParity.sourceLeaf(for: leaf.path, in: sourceNode) else { continue }
                        if let problem = FormatParity.problem(source: match.leaf.value, target: leaf.unit.value, allowsOmission: match.isPluralCase && leaf.path.last != "other") {
                            let where_ = leaf.label.isEmpty ? "" : " (\(leaf.label))"
                            add(Rules.formatMismatch, "Translation \(locale)\(where_) of \"\(key)\": \(problem)", key: key, locales: [locale])
                        }
                        if leaf.unit.value == match.leaf.value, leaf.unit.value.contains(" "), leaf.unit.value.contains(where: \.isLetter) {
                            if !identical.contains(locale) { identical.append(locale) }
                        }
                    }
                    for (term, translations) in project.config.glossary.sorted(by: { $0.key < $1.key }) {
                        guard let required = translations[locale] else { continue }
                        // Every variation whose source uses the term must use the required translation.
                        let violating = leaves.filter { leaf in
                            guard let match = FormatParity.sourceLeaf(for: leaf.path, in: sourceNode),
                                  match.leaf.value.range(of: term, options: .caseInsensitive) != nil
                            else { return false }
                            return leaf.unit.value.range(of: required, options: .caseInsensitive) == nil
                        }
                        if !violating.isEmpty {
                            let where_ = violating.map(\.label).filter { !$0.isEmpty }
                            let scope = where_.isEmpty ? "" : " (\(where_.joined(separator: ", ")))"
                            add(Rules.glossary, "Translation \(locale) of \"\(key)\"\(scope) should use \"\(required)\" for \"\(term)\"", key: key, locales: [locale])
                        }
                    }
                }

                if !missing.isEmpty {
                    add(Rules.missingTranslation, "Key \"\(key)\" is missing translations for \(missing.joined(separator: ", "))", key: key, locales: missing, fixable: true)
                }
                if !review.isEmpty {
                    add(Rules.needsReview, "Key \"\(key)\" needs review in \(review.joined(separator: ", "))", key: key, locales: review)
                }
                if !stale.isEmpty {
                    add(Rules.staleTranslation, "Source of \"\(key)\" changed since it was translated to \(stale.joined(separator: ", "))", key: key, locales: stale, fixable: true)
                }
                if !identical.isEmpty {
                    add(Rules.untranslatedCopy, "Translation of \"\(key)\" is identical to the source in \(identical.joined(separator: ", "))", key: key, locales: identical)
                }
            }

            // Symbol checks only apply where Xcode actually generates symbols for this catalog.
            if project.usesSymbols(for: catalog.url) {
                for key in manualKeys where SymbolNaming.symbol(for: key) == .reserved {
                    add(Rules.symbolCollision, "Key \"\(key)\" is too close to a Swift keyword to generate a symbol", key: key)
                }
                for group in SymbolNaming.collisions(among: manualKeys) {
                    let name = SymbolNaming.bareName(for: group[0]) ?? ""
                    for key in group {
                        add(Rules.symbolCollision, "Keys \(group.map { "\"\($0)\"" }.joined(separator: ", ")) all generate the symbol .\(name)", key: key)
                    }
                }
            }
        }
        return diagnostics
    }

    /// Line of each key in the catalog file (Xcode formatting: `    "key" : {`).
    static func keyLines(catalog: StringCatalog) -> [String: Int] {
        guard let text = try? String(contentsOf: catalog.url, encoding: .utf8) else { return [:] }
        var result: [String: Int] = [:]
        var lineNumber = 1
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("    \""), !line.hasPrefix("     "), let end = line.range(of: "\" : ") {
                let encoded = line[line.index(line.startIndex, offsetBy: 4)..<end.upperBound].dropLast(3)
                if let value = try? JSONParser.parse(String(encoded)), let key = value.stringValue {
                    result[key] = lineNumber
                }
            }
            lineNumber += 1
        }
        return result
    }
}
