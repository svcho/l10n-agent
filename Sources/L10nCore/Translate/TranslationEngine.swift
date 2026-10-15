import Foundation

public struct TranslateOptions: Sendable {
    public var locales: [String]?
    public var keys: [String]?
    public var catalogs: [String]?
    public var dryRun: Bool
    public var batchSize: Int?

    public init(locales: [String]? = nil, keys: [String]? = nil, catalogs: [String]? = nil, dryRun: Bool = false, batchSize: Int? = nil) {
        self.locales = locales
        self.keys = keys
        self.catalogs = catalogs
        self.dryRun = dryRun
        self.batchSize = batchSize
    }
}

/// One translatable piece of a key for one locale: a plain string unit, or a full set
/// of plural forms (top-level, per device, or inside a `%#@name@` substitution).
public struct TranslationUnit: Codable, Equatable, Sendable {
    public var id: String
    public var catalog: String
    public var key: String
    public var locale: String
    public var path: [String]
    public var source: String?
    public var sourceForms: [String: String]?
    public var categories: [String]?
    public var comment: String?
    /// `missing`, `stale` or `invalid` (machine translation with broken format specifiers).
    public var reason: String

    public var isPlural: Bool { sourceForms != nil }
}

public struct TranslationIssue: Codable, Equatable, Sendable {
    public var catalog: String
    public var key: String
    public var locale: String
    public var reason: String
}

public struct TranslateReport: Codable, Equatable, Sendable {
    public var model: String?
    public var dryRun: Bool
    public var planned: Int
    public var translated: Int
    public var perLocale: [String: Int]
    public var failed: [TranslationIssue]
    /// Approved (`translated`) translations that need a human (source changed, or the
    /// structure differs). Never overwritten; review them in Xcode.
    public var approvedSkipped: [TranslationIssue]
    public var warnings: [String]
    public var units: [TranslationUnit]?
    public var aborted: String?
}

/// A translation supplied directly (for example by a coding agent over MCP).
public struct ProvidedTranslation: Codable, Equatable, Sendable {
    public var catalog: String?
    public var key: String
    public var locale: String
    /// For plain strings.
    public var value: String?
    /// For plural keys: CLDR category → text.
    public var forms: [String: String]?
}

public final class TranslationEngine: @unchecked Sendable {
    public let project: Project
    public var progress: (@Sendable (String) -> Void)?

    public init(project: Project, progress: (@Sendable (String) -> Void)? = nil) {
        self.project = project
        self.progress = progress
    }

    // MARK: Planning

    struct Loaded {
        var catalogs: [String: StringCatalog]
        var order: [String]
        var fingerprints: FingerprintStore
        var locales: [String]
    }

    func load(_ options: TranslateOptions) throws -> Loaded {
        var catalogs: [String: StringCatalog] = [:]
        var order: [String] = []
        var allCatalogs: [StringCatalog] = []
        for url in project.catalogURLs {
            let catalog = try StringCatalog.load(url)
            allCatalogs.append(catalog)
            let path = project.relativePath(url)
            if let filter = options.catalogs, !filter.contains(path), !filter.contains(url.lastPathComponent) { continue }
            catalogs[path] = catalog
            order.append(path)
        }
        // Target locales come from the whole project, even when only some catalogs are processed.
        let allLocales = project.targetLocales(catalogs: allCatalogs)
        let locales = options.locales.map { requested in requested.filter { $0 != project.sourceLanguage } } ?? allLocales
        return Loaded(catalogs: catalogs, order: order, fingerprints: try FingerprintStore.load(root: project.root), locales: locales)
    }

    func plan(_ loaded: inout Loaded, options: TranslateOptions, adoptBaselines: Bool) -> (units: [TranslationUnit], staleApproved: [TranslationIssue], unsupported: [TranslationIssue]) {
        var units: [TranslationUnit] = []
        var staleApproved: [TranslationIssue] = []
        var unsupported: [TranslationIssue] = []
        let keyFilter = options.keys.map { Set($0.map(ByteKey.init)) }

        for path in loaded.order {
            guard let catalog = loaded.catalogs[path] else { continue }
            for (key, entry) in catalog.entries {
                if let keyFilter, !keyFilter.contains(ByteKey(key)) { continue }
                guard entry.shouldTranslate, !entry.isStale else { continue }
                let sourceNode = entry.sourceNode(key: key, sourceLanguage: catalog.sourceLanguage)
                guard sourceNode.leaves.contains(where: { !$0.unit.value.isEmpty }) else { continue }
                let fingerprint = FingerprintStore.sourceFingerprint(sourceNode)
                let shapes = Self.unitShapes(sourceNode, path: [])

                for locale in loaded.locales {
                    let target = entry.localization(locale)
                    let recorded = loaded.fingerprints.fingerprint(catalog: path, key: key, locale: locale)
                    let isStale = recorded != nil && recorded != fingerprint
                    var complete = true
                    var approvedNotes: Set<String> = []
                    let knownCategories = PluralRules.categories(for: locale, overrides: project.config.pluralCategories)
                    let categories = knownCategories ?? ["other"]

                    for shape in shapes {
                        let leaves = target?.leaves ?? []
                        let underShape = leaves.filter { Array($0.path.prefix(shape.path.count)) == shape.path }

                        if let forms = shape.forms {
                            // Never guess plural rules: unknown languages are reported, whatever the target holds.
                            if knownCategories == nil {
                                unsupported.append(TranslationIssue(catalog: path, key: key, locale: locale, reason: "plural categories for \(locale) are unknown; add them under pluralCategories in \(L10nConfig.fileName)"))
                                complete = false
                                continue
                            }
                            // A plain approved translation where the source is plural: leave it to a human.
                            if underShape.contains(where: { $0.path == shape.path && $0.unit.isApproved }) {
                                approvedNotes.insert("the approved translation has no plural variations; add them in Xcode")
                                complete = false
                                continue
                            }
                            let byCategory = Dictionary(Self.targetLeaves(target, shape: shape).map { ($0.path.last ?? "", $0) }, uniquingKeysWith: { first, _ in first })
                            var needed: [String] = []
                            var reason = "missing"
                            for category in categories {
                                guard let leaf = byCategory[category], !leaf.unit.isMissing else {
                                    needed.append(category)
                                    continue
                                }
                                if leaf.unit.isApproved {
                                    if isStale { approvedNotes.insert("source changed after this translation was approved; review it in Xcode, then run `l10n-agent accept`") }
                                    continue
                                }
                                let reference = forms[category] ?? forms["other"] ?? ""
                                if FormatParity.problem(source: reference, target: leaf.unit.value, allowsOmission: category != "other") != nil {
                                    needed.append(category)
                                    if reason == "missing", byCategory.count == categories.count { reason = "invalid" }
                                } else if isStale {
                                    needed.append(category)
                                    if reason == "missing", byCategory.count == categories.count { reason = "stale" }
                                }
                            }
                            guard !needed.isEmpty else { continue }
                            complete = false
                            units.append(TranslationUnit(
                                id: String(units.count + 1), catalog: path, key: key, locale: locale, path: shape.path,
                                source: nil, sourceForms: forms, categories: needed, comment: entry.comment, reason: reason
                            ))
                            continue
                        }

                        // Plain string unit. A language may vary it by plural/device on its own
                        // (Xcode "Vary by Plural" per language): never machine-translate those,
                        // and only flag them when incomplete or when the source changed.
                        if let target, let varied = Self.languageVariationsComplete(target, at: shape.path, categories: knownCategories) {
                            if !varied {
                                approvedNotes.insert("the translation varies by plural/device but some cases are empty; finish them in Xcode")
                                complete = false
                            } else if isStale {
                                approvedNotes.insert("source changed after this translation was approved; review it in Xcode, then run `l10n-agent accept`")
                                complete = false
                            }
                            continue
                        }
                        let leaf = underShape.first { $0.path == shape.path }
                        let reason: String
                        if leaf == nil || leaf!.unit.isMissing {
                            reason = "missing"
                        } else if leaf!.unit.isApproved {
                            if isStale {
                                approvedNotes.insert("source changed after this translation was approved; review it in Xcode, then run `l10n-agent accept`")
                                complete = false
                            }
                            continue
                        } else if Self.hasInvalidMachineTranslation([leaf!], source: sourceNode) {
                            reason = "invalid"
                        } else if isStale {
                            reason = "stale"
                        } else {
                            continue
                        }
                        complete = false
                        units.append(TranslationUnit(
                            id: String(units.count + 1), catalog: path, key: key, locale: locale, path: shape.path,
                            source: shape.source, sourceForms: nil, categories: nil, comment: entry.comment, reason: reason
                        ))
                    }
                    for note in approvedNotes.sorted() {
                        staleApproved.append(TranslationIssue(catalog: path, key: key, locale: locale, reason: note))
                    }
                    if adoptBaselines, complete, !isStale, recorded == nil, target != nil {
                        // Existing translations made before the tool tracked them: adopt the current source.
                        loaded.fingerprints.set(catalog: path, key: key, locale: locale, fingerprint: fingerprint)
                    }
                }
            }
        }
        return (units, staleApproved, unsupported)
    }

    struct UnitShape {
        var path: [String]
        var source: String?
        var forms: [String: String]?
    }

    static func unitShapes(_ node: LocalizationNode, path: [String]) -> [UnitShape] {
        let variations = node.variations
        if let plural = variations["plural"] {
            let forms = plural.compactMapValues { $0.stringUnit?.value }
            return forms.isEmpty ? [] : [UnitShape(path: path, source: nil, forms: forms)]
        }
        if let device = variations["device"] {
            return device.keys.sorted().flatMap { name in
                unitShapes(device[name]!, path: path + ["variations", "device", name])
            }
        }
        var shapes: [UnitShape] = []
        if let unit = node.stringUnit {
            shapes.append(UnitShape(path: path, source: unit.value, forms: nil))
        }
        for (name, substitution) in node.substitutions.sorted(by: { $0.key < $1.key }) {
            if let plural = substitution.variations["plural"] {
                let forms = plural.compactMapValues { $0.stringUnit?.value }
                if !forms.isEmpty {
                    shapes.append(UnitShape(path: path + ["substitutions", name], source: nil, forms: forms))
                }
            }
        }
        return shapes
    }

    /// A `needs_review` (machine) translation whose format specifiers do not match the
    /// source. Approved translations are left alone and only reported by lint.
    static func hasInvalidMachineTranslation(_ leaves: [LocalizationNode.Leaf], source: LocalizationNode) -> Bool {
        leaves.contains { leaf in
            guard !leaf.unit.isApproved, let match = FormatParity.sourceLeaf(for: leaf.path, in: source) else { return false }
            return FormatParity.problem(source: match.leaf.value, target: leaf.unit.value, allowsOmission: match.isPluralCase && leaf.path.last != "other") != nil
        }
    }

    static func targetLeaves(_ target: LocalizationNode?, shape: UnitShape) -> [LocalizationNode.Leaf] {
        guard let target else { return [] }
        let leaves = target.leaves
        if shape.forms != nil {
            let prefix = shape.path + ["variations", "plural"]
            return leaves.filter { $0.path.count == prefix.count + 1 && Array($0.path.prefix(prefix.count)) == prefix }
        }
        return leaves.filter { $0.path == shape.path }
    }

    /// A translation is complete when every leaf has a value and plural keys have all
    /// CLDR categories of the locale.
    /// Plural keys of languages with unknown categories (no CLDR entry, no override) are
    /// never considered complete.
    public static func isComplete(_ target: LocalizationNode?, source: LocalizationNode, locale: String, overrides: [String: [String]] = [:]) -> Bool {
        guard let target else { return false }
        let leaves = target.leaves
        if leaves.isEmpty || leaves.contains(where: \.unit.isMissing) { return false }
        let categories = PluralRules.categories(for: locale, overrides: overrides)
        return unitShapes(source, path: []).allSatisfy { shape in
            if shape.forms != nil {
                guard let categories else { return false }
                return hasAllCategories(targetLeaves(target, shape: shape), categories: categories)
            }
            // Plain shapes, including each device variation, must exist at their own path, or the
            // language varies the string itself (Xcode's per-language "Vary by Plural/Device").
            return leaves.contains { $0.path == shape.path }
                || languageVariationsComplete(target, at: shape.path, categories: categories) == true
        }
    }

    /// For a translation that adds its own variations where the source is plain: `nil` when
    /// there are none, otherwise whether every case is filled (plural: every CLDR category).
    static func languageVariationsComplete(_ target: LocalizationNode, at path: [String], categories: [String]?) -> Bool? {
        guard let object = path.isEmpty ? target.raw : target.value(at: path)?.objectValue else { return nil }
        let variations = LocalizationNode(raw: object).variations
        guard !variations.isEmpty else { return nil }
        for (kind, cases) in variations {
            if kind == "plural" {
                guard let categories, categories.allSatisfy({ cases[$0] != nil }) else { return false }
            }
            for node in cases.values {
                let leaves = node.leaves
                if leaves.isEmpty || leaves.contains(where: \.unit.isMissing) { return false }
            }
        }
        return true
    }

    static func hasAllCategories(_ leaves: [LocalizationNode.Leaf], categories: [String]) -> Bool {
        let present = Set(leaves.compactMap(\.path.last))
        return categories.allSatisfy(present.contains)
    }

    // MARK: Running

    public func run(_ options: TranslateOptions, model: ChatModel?) async throws -> TranslateReport {
        if options.dryRun {
            var loaded = try load(options)
            let planned = plan(&loaded, options: options, adoptBaselines: false)
            return TranslateReport(model: model?.name, dryRun: true, planned: planned.units.count, translated: 0, perLocale: [:], failed: planned.unsupported, approvedSkipped: planned.staleApproved, warnings: [], units: planned.units, aborted: nil)
        }
        guard let model else { throw L10nError.translator("No translation model configured") }
        return try await ProjectLock.withLock(root: project.root) {
            try await self.runLocked(options, model: model)
        }
    }

    private func runLocked(_ options: TranslateOptions, model: ChatModel) async throws -> TranslateReport {
        var loaded = try load(options)
        let planned = plan(&loaded, options: options, adoptBaselines: true)
        var report = TranslateReport(model: model.name, dryRun: false, planned: planned.units.count, translated: 0, perLocale: [:], failed: planned.unsupported, approvedSkipped: planned.staleApproved, warnings: [], units: nil, aborted: nil)
        try saveTouched(&loaded, catalogs: [])

        let batchSize = max(1, options.batchSize ?? project.config.translator.batchSize)
        let byLocale = Dictionary(grouping: planned.units, by: \.locale)
        // Units still outstanding per key and locale; a fingerprint is recorded once all succeed.
        var outstanding = Dictionary(grouping: planned.units, by: { GroupKey($0.catalog, $0.key, $0.locale) }).mapValues { Set($0.map(\.id)) }
        // Keys with approved translations that still need a human keep their old fingerprint.
        var failedGroups: Set<GroupKey> = Set((planned.staleApproved + planned.unsupported).map { GroupKey($0.catalog, $0.key, $0.locale) })
        var done = 0

        outer: for locale in byLocale.keys.sorted() {
            for batch in Self.batches(byLocale[locale]!, size: batchSize) {
                progress?("Translating \(LanguageNames.displayName(locale)) (\(locale)): \(done + 1)-\(done + batch.count) of \(planned.units.count)")
                let outcome: BatchOutcome
                do {
                    outcome = try await translate(batch, locale: locale, model: model)
                } catch {
                    report.aborted = "\(error)"
                    for unit in batch { report.failed.append(TranslationIssue(catalog: unit.catalog, key: unit.key, locale: unit.locale, reason: "not attempted: \(error)")) }
                    break outer
                }
                report.warnings += outcome.warnings
                var touched: Set<String> = []
                for (unit, problem) in outcome.failures {
                    report.failed.append(TranslationIssue(catalog: unit.catalog, key: unit.key, locale: unit.locale, reason: problem))
                    failedGroups.insert(GroupKey(unit.catalog, unit.key, unit.locale))
                }
                for (unit, result) in outcome.results {
                    write(result, for: unit, into: &loaded)
                    touched.insert(unit.catalog)
                    report.translated += 1
                    report.perLocale[locale, default: 0] += 1
                    let group = GroupKey(unit.catalog, unit.key, unit.locale)
                    outstanding[group]?.remove(unit.id)
                    if outstanding[group]?.isEmpty == true, !failedGroups.contains(group),
                       let catalog = loaded.catalogs[unit.catalog], let entry = catalog.entry(unit.key) {
                        loaded.fingerprints.set(catalog: unit.catalog, key: unit.key, locale: unit.locale, fingerprint: FingerprintStore.sourceFingerprint(entry.sourceNode(key: unit.key, sourceLanguage: catalog.sourceLanguage)))
                    }
                }
                try saveTouched(&loaded, catalogs: touched)
                done += batch.count
            }
        }
        return report
    }

    /// Writes touched catalogs and the fingerprint store as one unit: if any write fails,
    /// everything written in this call is restored, so translations never land without
    /// their fingerprints (which would make the next run retranslate them).
    func saveTouched(_ loaded: inout Loaded, catalogs: Set<String>) throws {
        for (path, catalog) in loaded.catalogs {
            loaded.fingerprints.prune(catalog: path) { key, locale in catalog.entry(key)?.localization(locale) != nil }
        }
        var transaction = FileTransaction()
        do {
            for path in catalogs.sorted() {
                guard let catalog = loaded.catalogs[path] else { continue }
                try transaction.write(catalog.serialized(), to: catalog.url)
            }
            try transaction.write(loaded.fingerprints.serialized(), to: loaded.fingerprints.url)
        } catch {
            transaction.rollBack()
            throw error
        }
    }

    static func batches(_ units: [TranslationUnit], size: Int) -> [[TranslationUnit]] {
        var batches: [[TranslationUnit]] = []
        var current: [TranslationUnit] = []
        var characters = 0
        for unit in units {
            let length = (unit.source?.count ?? 0) + (unit.sourceForms?.values.reduce(0) { $0 + $1.count } ?? 0) + (unit.comment?.count ?? 0)
            if !current.isEmpty, current.count >= size || characters + length > 6000 {
                batches.append(current)
                current = []
                characters = 0
            }
            current.append(unit)
            characters += length
        }
        if !current.isEmpty { batches.append(current) }
        return batches
    }

    /// Catalog + byte-exact key + locale.
    struct GroupKey: Hashable {
        let catalog: String
        let key: ByteKey
        let locale: String

        init(_ catalog: String, _ key: String, _ locale: String) {
            self.catalog = catalog
            self.key = ByteKey(key)
            self.locale = locale
        }
    }

    // MARK: Model round trips

    enum UnitResult: Equatable {
        case text(String)
        case forms([String: String])
    }

    struct BatchOutcome {
        var results: [(TranslationUnit, UnitResult)] = []
        var failures: [(TranslationUnit, String)] = []
        var warnings: [String] = []
    }

    func translate(_ batch: [TranslationUnit], locale: String, model: ChatModel) async throws -> BatchOutcome {
        var outcome = BatchOutcome()
        var pending = batch
        var feedback: [String: String] = [:]
        let maxAttempts = project.config.translator.maxRetries + 1

        for attempt in 1...maxAttempts {
            guard !pending.isEmpty else { break }
            let isLastAttempt = attempt == maxAttempts
            // The first attempt sends the whole batch; retries send one item per request so
            // a confused model cannot mix up items again.
            let groups = attempt == 1 || pending.count == 1 ? [pending] : pending.map { [$0] }
            var stillPending: [TranslationUnit] = []
            for group in groups {
                let response = try await model.complete(system: systemPrompt(locale: locale), user: userPrompt(group, feedback: feedback))
                if ProcessInfo.processInfo.environment["L10N_AGENT_DEBUG"] != nil {
                    progress?("model reply (attempt \(attempt), \(group.count) item(s)):\n\(response)")
                }
                let parsed = Self.parseResponse(response, expecting: group)
                var accepted: [(TranslationUnit, UnitResult)] = []
                for (index, unit) in group.enumerated() {
                    guard let raw = parsed[String(index + 1)] else {
                        feedback[unit.id] = parsed.isEmpty ? "The reply was not valid JSON." : "This id was missing from the reply."
                        stillPending.append(unit)
                        continue
                    }
                    switch validate(raw, for: unit) {
                    case .success(let result):
                        if let glossaryProblem = glossaryProblem(result, unit: unit) {
                            if isLastAttempt {
                                accepted.append((unit, result))
                                outcome.warnings.append("\(unit.key) [\(unit.locale)]: \(glossaryProblem)")
                            } else {
                                feedback[unit.id] = glossaryProblem
                                stillPending.append(unit)
                            }
                        } else {
                            accepted.append((unit, result))
                        }
                    case .failure(let problem):
                        feedback[unit.id] = problem.message
                        stillPending.append(unit)
                    }
                }
                // Different source texts answered with the same text usually means the model
                // shifted answers between items. Retry those individually.
                if group.count > 1, !isLastAttempt {
                    let suspicious = Self.mixedUpUnits(accepted)
                    for (unit, _) in accepted where suspicious.contains(unit.id) {
                        feedback[unit.id] = "The answer duplicated another item with different source text. Translate only this item's own text."
                        stillPending.append(unit)
                    }
                    accepted.removeAll { suspicious.contains($0.0.id) }
                }
                outcome.results += accepted
            }
            pending = stillPending
        }
        for unit in pending {
            outcome.failures.append((unit, feedback[unit.id] ?? "no valid translation"))
        }
        return outcome
    }

    /// IDs of plain units whose translation equals another unit's translation although
    /// their sources differ.
    static func mixedUpUnits(_ results: [(TranslationUnit, UnitResult)]) -> Set<String> {
        var byTranslation: [String: [(id: String, source: String)]] = [:]
        for (unit, result) in results {
            guard case .text(let text) = result, let source = unit.source else { continue }
            byTranslation[text, default: []].append((unit.id, source))
        }
        var suspicious: Set<String> = []
        for group in byTranslation.values where Set(group.map(\.source)).count > 1 {
            suspicious.formUnion(group.map(\.id))
        }
        return suspicious
    }

    struct Problem: Error { var message: String }

    func validate(_ raw: UnitResult, for unit: TranslationUnit) -> Result<UnitResult, Problem> {
        switch (raw, unit.sourceForms) {
        case (.text(let text), nil):
            guard let source = unit.source else { return .failure(Problem(message: "internal: missing source")) }
            let restored: String
            do {
                restored = try Self.restore(text, source: source)
            } catch {
                return .failure(Problem(message: "\(error)"))
            }
            if let problem = FormatParity.problem(source: source, target: restored) {
                return .failure(Problem(message: "Placeholder problem: \(problem). Keep every ⟦…⟧ token exactly once."))
            }
            return .success(.text(restored))
        case (.forms(let forms), let sourceForms?):
            let categories = unit.categories ?? ["one", "other"]
            var restoredForms: [String: String] = [:]
            for category in categories {
                // Each form is restored and checked against its own source form; categories
                // the source lacks (e.g. Polish "few") use the source "other".
                let reference = sourceForms[category] ?? sourceForms["other"] ?? sourceForms.values.first ?? ""
                guard let text = forms[category] else {
                    return .failure(Problem(message: "Missing plural form \"\(category)\". Return forms for exactly: \(categories.joined(separator: ", "))."))
                }
                do {
                    restoredForms[category] = try Self.restore(text, source: reference)
                } catch {
                    return .failure(Problem(message: "Form \(category): \(error)"))
                }
                let restored = restoredForms[category]!
                // "other" covers arbitrary counts and must keep every argument; other
                // categories may drop the count ("One file") but must not hard-code it.
                if let problem = FormatParity.problem(source: reference, target: restored, allowsOmission: category != "other") {
                    return .failure(Problem(message: "Form \(category): \(problem). Keep the ⟦…⟧ tokens."))
                }
                let omitsArgument = FormatSpecifier.argumentSignature(of: restored).count < FormatSpecifier.argumentSignature(of: reference).count
                if omitsArgument, text.contains(where: { $0.isASCII && $0.isNumber }), !reference.contains(where: { $0.isASCII && $0.isNumber }) {
                    return .failure(Problem(message: "Form \(category): use the ⟦…⟧ token for the count instead of a literal number."))
                }
            }
            return .success(.forms(restoredForms))
        case (.text, .some):
            return .failure(Problem(message: "This item needs \"forms\" for: \((unit.categories ?? []).joined(separator: ", "))."))
        case (.forms, nil):
            return .failure(Problem(message: "This item needs a single \"text\"."))
        }
    }

    static func restore(_ text: String, source: String) throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Problem(message: "Empty translation.") }
        // Keep intentional leading/trailing whitespace from the source.
        let leading = String(source.prefix { $0.isWhitespace })
        let trailing = String(source.reversed().prefix { $0.isWhitespace }.reversed())
        do {
            return leading + (try MaskedText(source: source).unmask(trimmed)) + trailing
        } catch let error as MaskedText.UnmaskError {
            throw Problem(message: error.description)
        }
    }

    /// Each translated text must use the required term when its own source text uses the
    /// glossary term. Plural forms compare with the same source category, else `other`.
    func glossaryProblem(_ result: UnitResult, unit: TranslationUnit) -> String? {
        let pairs: [(source: String, target: String, label: String?)]
        switch result {
        case .text(let text):
            pairs = [(unit.source ?? "", text, nil)]
        case .forms(let forms):
            pairs = forms.sorted(by: { $0.key < $1.key }).map { category, text in
                (unit.sourceForms?[category] ?? unit.sourceForms?["other"] ?? "", text, category)
            }
        }
        for (term, translations) in project.config.glossary.sorted(by: { $0.key < $1.key }) {
            guard let required = translations[unit.locale] else { continue }
            for pair in pairs where pair.source.range(of: term, options: .caseInsensitive) != nil
                && pair.target.range(of: required, options: .caseInsensitive) == nil {
                let form = pair.label.map { " in form \"\($0)\"" } ?? ""
                return "Glossary: translate \"\(term)\" as \"\(required)\"\(form)."
            }
        }
        return nil
    }

    // MARK: Prompts

    func systemPrompt(locale: String) -> String {
        let source = project.sourceLanguage
        let targetName = LanguageNames.displayName(locale)
        var lines = [
            "You are a professional software localizer translating the user interface of an Apple platform app from \(LanguageNames.displayName(source)) (\(source)) to \(targetName) (\(locale)).",
            "Rules:",
            "- Translate \"text\", or every entry of \"forms\", of each item. Use \"key\" and \"comment\" only as context; never translate them.",
            "- Tokens such as ⟦1⟧, ⟦2⟧, ⟦@name⟧ and ⟦%⟧ are placeholders. Copy each token exactly as written. You may move tokens to fit \(targetName) grammar, but never translate, drop, duplicate or invent tokens.",
            "- Items with \"categories\" are plural strings: return \"forms\" with exactly those CLDR plural categories for \(targetName). A form may leave out the count token only where \(targetName) naturally does.",
            "- Keep brand names, product names, URLs and code-like text unchanged. Keep the source's tone, punctuation style and brevity; UI space is limited.",
            "- Use the terminology Apple uses in \(targetName) for iOS and macOS (for example Settings, Cancel, Done, Edit, Delete).",
            "- If an item has \"feedback\", your previous answer was rejected for that reason; fix it.",
        ]
        let glossary = project.config.glossary.sorted(by: { $0.key < $1.key }).compactMap { term, translations in
            translations[locale].map { "- \(term) => \($0)" }
        }
        if !glossary.isEmpty {
            lines.append("Mandatory glossary:")
            lines += glossary
        }
        lines.append(#"Reply with only a JSON object: {"translations":[{"id":"1","text":"..."},{"id":"2","forms":{"one":"...","other":"..."}}]} containing every id exactly once. No markdown, no explanations."#)
        return lines.joined(separator: "\n")
    }

    /// Items are numbered 1…n per request; small models copy ids from the prompt example
    /// and lose track of long or non-sequential ids.
    func userPrompt(_ units: [TranslationUnit], feedback: [String: String]) -> String {
        let items: [[String: Any]] = units.enumerated().map { index, unit in
            var item: [String: Any] = ["id": String(index + 1), "key": unit.key]
            if let forms = unit.sourceForms {
                item["forms"] = forms.mapValues { MaskedText(source: $0).text }
                item["categories"] = unit.categories ?? []
            } else if let source = unit.source {
                item["text"] = MaskedText(source: source).text
            }
            if let comment = unit.comment, !comment.isEmpty { item["comment"] = comment }
            if let message = feedback[unit.id] { item["feedback"] = message }
            return item
        }
        let data = (try? JSONSerialization.data(withJSONObject: ["items": items], options: [.sortedKeys, .withoutEscapingSlashes, .prettyPrinted])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// Parses a model reply into results keyed by the request's local item id ("1"…"n").
    /// With a single expected item, any single answer (or a bare-text reply) is accepted.
    static func parseResponse(_ response: String, expecting units: [TranslationUnit] = []) -> [String: UnitResult] {
        var text = response
        while let start = text.range(of: "<think>"), let end = text.range(of: "</think>", range: start.upperBound..<text.endIndex) {
            text.removeSubrange(start.lowerBound..<end.upperBound)
        }
        var results: [String: UnitResult] = [:]
        var unlabeled: [UnitResult] = []
        if let first = text.firstIndex(of: "{"), let last = text.lastIndex(of: "}"), first < last,
           let value = try? JSONParser.parse(String(text[first...last])) {
            let list: [JSONValue]
            if case .array(let array)? = value["translations"] {
                list = array
            } else if case .array(let array)? = value["items"] {
                list = array
            } else {
                list = [value]
            }
            for element in list {
                guard let object = element.objectValue else { continue }
                let result: UnitResult
                if let text = object["text"]?.stringValue {
                    result = .text(text)
                } else if let forms = object["forms"]?.objectValue {
                    var dictionary: [String: String] = [:]
                    for member in forms.members {
                        if let value = member.value.stringValue { dictionary[member.key] = value }
                    }
                    result = .forms(dictionary)
                } else {
                    continue
                }
                switch object["id"] {
                case .string(let id)?: results[id] = result
                case .number(let id)?: results[id] = result
                default: unlabeled.append(result)
                }
            }
        }

        if units.count == 1, results["1"] == nil {
            let answers = Array(results.values) + unlabeled
            if answers.count == 1 {
                results["1"] = answers[0]
            } else if answers.isEmpty, units[0].sourceForms == nil {
                let bare = Self.stripCodeFence(text).trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"“”")))
                if !bare.isEmpty, !bare.hasPrefix("{"), !bare.contains("\n") {
                    results["1"] = .text(bare)
                }
            }
        }
        for (index, unit) in units.enumerated() {
            let id = String(index + 1)
            if unit.sourceForms == nil {
                // A plain item answered with a single plural-style form is still usable.
                if case .forms(let forms)? = results[id], let only = forms["other"] ?? (forms.count == 1 ? forms.values.first : nil) {
                    results[id] = .text(only)
                }
            } else if unit.categories?.count == 1, let category = unit.categories?.first, case .text(let text)? = results[id] {
                // A plural item that needs one category (e.g. Japanese "other") answered with text.
                results[id] = .forms([category: text])
            }
        }
        return results
    }

    static func stripCodeFence(_ text: String) -> String {
        var lines = text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
        if lines.first?.hasPrefix("```") == true { lines.removeFirst() }
        if lines.last?.hasPrefix("```") == true { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    // MARK: Writing

    /// Writes a validated result as `needs_review`. Approved (`translated`) units are never
    /// replaced or removed, even if the plan asked for it.
    func write(_ result: UnitResult, for unit: TranslationUnit, into loaded: inout Loaded) {
        guard var catalog = loaded.catalogs[unit.catalog], var entry = catalog.entry(unit.key) else { return }
        var target = entry.localization(unit.locale) ?? LocalizationNode(raw: JSONObject())
        let state = StringUnit.State.needsReview
        let approvedPaths = Set(target.leaves.filter(\.unit.isApproved).map(\.path))
        switch result {
        case .text(let text):
            guard !approvedPaths.contains(unit.path) else { return }
            target.setUnit(StringUnit(state: state, value: text), at: unit.path)
        case .forms(let forms):
            // Substitutions keep their argNum/formatSpecifier from the source.
            if unit.path.contains("substitutions"),
               let sourceSubstitution = entry.sourceNode(key: unit.key, sourceLanguage: catalog.sourceLanguage).value(at: unit.path)?.objectValue {
                for member in sourceSubstitution.members where member.key != "variations" {
                    target.setValue(member.value, at: unit.path + [member.key])
                }
            }
            if !unit.path.contains("substitutions"), !approvedPaths.contains(unit.path) {
                target.removeStringUnit(at: unit.path)
            }
            for (category, text) in forms where !approvedPaths.contains(unit.path + ["variations", "plural", category]) {
                target.setUnit(StringUnit(state: state, value: text), at: unit.path + ["variations", "plural", category])
            }
        }
        entry.setLocalization(unit.locale, target)
        catalog.setEntry(unit.key, entry)
        loaded.catalogs[unit.catalog] = catalog
    }

    // MARK: Provided translations

    /// Validates and writes translations supplied by a caller (state `needs_review`).
    public func applyProvided(_ provided: [ProvidedTranslation]) throws -> TranslateReport {
        try ProjectLock.withLock(root: project.root) {
            var loaded = try load(TranslateOptions())
            var report = TranslateReport(model: "provided", dryRun: false, planned: provided.count, translated: 0, perLocale: [:], failed: [], approvedSkipped: [], warnings: [], units: nil, aborted: nil)
            var touched: Set<String> = []
            for item in provided {
                let matches = loaded.order.filter { loaded.catalogs[$0]?.contains(item.key) == true }
                if item.catalog == nil, matches.count > 1 {
                    report.failed.append(TranslationIssue(catalog: "", key: item.key, locale: item.locale, reason: "the key exists in several catalogs (\(matches.joined(separator: ", "))); set catalog"))
                    continue
                }
                let path = item.catalog.map { project.relativePath((try? PathUtil.resolveInside($0, root: project.root)) ?? project.root.appendingPathComponent($0)) } ?? matches.first
                guard let path, let catalog = loaded.catalogs[path], let entry = catalog.entry(item.key) else {
                    report.failed.append(TranslationIssue(catalog: item.catalog ?? "", key: item.key, locale: item.locale, reason: "key not found in any catalog"))
                    continue
                }
                guard item.locale != catalog.sourceLanguage, loaded.locales.contains(item.locale) else {
                    report.failed.append(TranslationIssue(catalog: path, key: item.key, locale: item.locale, reason: "\(item.locale) is not a target locale (\(loaded.locales.joined(separator: ", ")))"))
                    continue
                }
                guard entry.shouldTranslate, !entry.isStale else {
                    report.failed.append(TranslationIssue(catalog: path, key: item.key, locale: item.locale, reason: "the key is marked as not translatable or unused"))
                    continue
                }
                let approvedLeaves = entry.localization(item.locale)?.leaves.filter(\.unit.isApproved) ?? []
                if item.forms == nil, !approvedLeaves.isEmpty {
                    report.failed.append(TranslationIssue(catalog: path, key: item.key, locale: item.locale, reason: "an approved translation exists; change it in Xcode instead"))
                    continue
                }
                // Plural forms: approved categories stay untouched; the caller fills the rest.
                let approvedCategories = Set(approvedLeaves.compactMap { $0.path.count >= 3 && $0.path[$0.path.count - 3] == "variations" ? $0.path.last : nil })
                if item.forms != nil, approvedLeaves.contains(where: { $0.path.isEmpty }) {
                    report.failed.append(TranslationIssue(catalog: path, key: item.key, locale: item.locale, reason: "an approved plain translation exists; add plural variations in Xcode"))
                    continue
                }
                let sourceNode = entry.sourceNode(key: item.key, sourceLanguage: catalog.sourceLanguage)
                let shapes = Self.unitShapes(sourceNode, path: [])
                guard shapes.count == 1, let shape = shapes.first, shape.path.isEmpty else {
                    report.failed.append(TranslationIssue(catalog: path, key: item.key, locale: item.locale, reason: "keys with device variations or substitutions must be edited in Xcode"))
                    continue
                }
                let categories = PluralRules.categories(for: item.locale, overrides: project.config.pluralCategories)
                if shape.forms != nil, categories == nil {
                    report.failed.append(TranslationIssue(catalog: path, key: item.key, locale: item.locale, reason: "plural categories for \(item.locale) are unknown; add them under pluralCategories in \(L10nConfig.fileName)"))
                    continue
                }
                let needed = categories?.filter { !approvedCategories.contains($0) }
                if shape.forms != nil, needed?.isEmpty == true {
                    report.failed.append(TranslationIssue(catalog: path, key: item.key, locale: item.locale, reason: "every plural category is already approved"))
                    continue
                }
                let unit = TranslationUnit(id: "1", catalog: path, key: item.key, locale: item.locale, path: [], source: shape.source, sourceForms: shape.forms, categories: shape.forms == nil ? nil : needed, comment: entry.comment, reason: "provided")
                let raw: UnitResult
                if let forms = item.forms {
                    raw = .forms(forms.filter { !approvedCategories.contains($0.key) }.mapValues { MaskedText(source: $0).text })
                } else if let value = item.value {
                    raw = .text(MaskedText(source: value).text)
                } else {
                    report.failed.append(TranslationIssue(catalog: path, key: item.key, locale: item.locale, reason: "provide value or forms"))
                    continue
                }
                switch validate(raw, for: unit) {
                case .success(let result):
                    write(result, for: unit, into: &loaded)
                    // Approved forms next to the provided ones were not reviewed against the
                    // current source: keep the old fingerprint so their staleness stays visible.
                    if approvedLeaves.isEmpty {
                        loaded.fingerprints.set(catalog: path, key: item.key, locale: item.locale, fingerprint: FingerprintStore.sourceFingerprint(sourceNode))
                    }
                    if let problem = glossaryProblem(result, unit: unit) { report.warnings.append("\(item.key) [\(item.locale)]: \(problem)") }
                    report.translated += 1
                    report.perLocale[item.locale, default: 0] += 1
                    touched.insert(path)
                case .failure(let problem):
                    report.failed.append(TranslationIssue(catalog: path, key: item.key, locale: item.locale, reason: problem.message))
                }
            }
            try saveTouched(&loaded, catalogs: touched)
            return report
        }
    }

    // MARK: Accept

    /// Marks current translations as matching the current source (after a human reviewed them).
    public func accept(keys: [String]?, locales: [String]?) throws -> Int {
        try ProjectLock.withLock(root: project.root) {
            try acceptLocked(keys: keys, locales: locales)
        }
    }

    /// `accept` for callers that already hold the project lock.
    func acceptLocked(keys: [String]?, locales: [String]?) throws -> Int {
        do {
            var loaded = try load(TranslateOptions(locales: locales))
            var count = 0
            let keyFilter = keys.map { Set($0.map(ByteKey.init)) }
            for path in loaded.order {
                guard let catalog = loaded.catalogs[path] else { continue }
                for (key, entry) in catalog.entries {
                    if let keyFilter, !keyFilter.contains(ByteKey(key)) { continue }
                    let fingerprint = FingerprintStore.sourceFingerprint(entry.sourceNode(key: key, sourceLanguage: catalog.sourceLanguage))
                    for locale in loaded.locales where entry.localization(locale) != nil {
                        if loaded.fingerprints.fingerprint(catalog: path, key: key, locale: locale) != fingerprint {
                            loaded.fingerprints.set(catalog: path, key: key, locale: locale, fingerprint: fingerprint)
                            count += 1
                        }
                    }
                }
            }
            try loaded.fingerprints.save()
            return count
        }
    }
}

extension LocalizationNode {
    /// Removes a plain `stringUnit` at `path` (used when a translation gains plural variations).
    mutating func removeStringUnit(at path: [String]) {
        guard var node = value(at: path)?.objectValue.map(LocalizationNode.init(raw:)) ?? (path.isEmpty ? self : nil) else { return }
        guard node.stringUnit != nil else { return }
        node.stringUnit = nil
        if path.isEmpty {
            self = node
        } else {
            setValue(.object(node.raw), at: path)
        }
    }
}
