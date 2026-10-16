import Foundation
import SwiftParser
import SwiftSyntax

public struct KeyChangeResult: Codable, Equatable, Sendable {
    public var removed: [String]
    /// old key → new key
    public var renamed: [String: String]
    /// key → why nothing was changed for it
    public var rejected: [String: String]
    public var catalogsChanged: [String]
    public var filesChanged: [String]
    public var notes: [String]

    init() {
        removed = []
        renamed = [:]
        rejected = [:]
        catalogsChanged = []
        filesChanged = []
        notes = []
    }
}

/// Removes and renames catalog keys together with their fingerprints and, for renames,
/// the code that references them. Only the catalogs that change are written.
public enum KeysCommand {
    /// Tables the build uses directly (Info.plist keys, App Shortcuts); Swift never references them.
    static let buildTables: Set<String> = ["InfoPlist", "AppShortcuts"]

    /// Removes whole keys (all their translations). Without `force` only what L10N106 reports
    /// can go: manual keys no Swift file of the catalog's target references, or keys Xcode
    /// marked stale. Extracted keys and build-owned tables (`InfoPlist`) need `force`.
    public static func remove(project: Project, keys: [String], catalog: String? = nil, force: Bool = false) throws -> KeyChangeResult {
        try ProjectLock.withLock(root: project.root) {
            var result = KeyChangeResult()
            let linter = Linter(project: project)
            var catalogs = CatalogSet(project: project)
            var references: [String: ProjectIndex.References] = [:]
            var fingerprints = try FingerprintStore.load(root: project.root)
            for key in keys {
                let path: String
                switch catalogs.resolve(key, explicit: catalog) {
                case .failure(let reason):
                    result.rejected[key] = reason
                    continue
                case .success(let found):
                    path = found
                }
                guard var target = catalogs.loaded[path], let entry = target.entry(key) else { continue }
                if !force {
                    if buildTables.contains(target.tableName) {
                        result.rejected[key] = "\(target.tableName) keys are used by the build, not by Swift code; pass --force to remove anyway"
                        continue
                    }
                    if !entry.isManual, !entry.isStale {
                        result.rejected[key] = "Xcode extracts this key from code (it is not manual); remove the code instead, or pass --force"
                        continue
                    }
                    let refs = references[path] ?? linter.references(for: target)
                    references[path] = refs
                    if entry.isManual, linter.isReferenced(key, in: refs) {
                        result.rejected[key] = "still referenced by Swift code of this target; remove the code first, or pass --force"
                        continue
                    }
                }
                target.setEntry(key, nil)
                catalogs.update(path, target)
                fingerprints.remove(catalog: path, key: key)
                result.removed.append(key)
            }
            try commit(catalogs: catalogs, fingerprints: fingerprints, sources: [:], project: project, result: &result)
            return result
        }
    }

    /// Renames a key: the entry (with every translation and review state) and its
    /// fingerprints move to the new key. Code that looks the key up is rewritten with
    /// `updateCode`; without it the rename is refused while code still uses the old key,
    /// so code never points at a key that no longer exists.
    public static func rename(project: Project, from old: String, to new: String, catalog: String? = nil, updateCode: Bool = false) throws -> KeyChangeResult {
        try ProjectLock.withLock(root: project.root) {
            var result = KeyChangeResult()
            func reject(_ reason: String) -> KeyChangeResult {
                result.rejected[old] = reason
                return result
            }
            var catalogs = CatalogSet(project: project)
            let path: String
            switch catalogs.resolve(old, explicit: catalog) {
            case .failure(let reason): return reject(reason)
            case .success(let found): path = found
            }
            guard var target = catalogs.loaded[path], var entry = target.entry(old) else { return result }
            if target.contains(new) { return reject("\"\(new)\" already exists in \(path)") }
            let violations = project.config.keys.violations(for: new)
            if !violations.isEmpty { return reject("\"\(new)\" \(violations.joined(separator: "; "))") }
            let usesSymbols = project.usesSymbols(for: target.url)
            if usesSymbols {
                if SymbolNaming.symbol(for: new) == .reserved { return reject("\"\(new)\" cannot generate a Swift symbol") }
                let symbol = SymbolNaming.bareName(for: new)
                if let clash = target.entries.first(where: { $0.entry.isManual && !$0.key.utf8.elementsEqual(old.utf8) && SymbolNaming.bareName(for: $0.key) == symbol }) {
                    return reject("\"\(new)\" generates the same symbol as \"\(clash.key)\"")
                }
            }

            // Find every lookup of the key in the files of the catalog's target, in memory.
            let linter = Linter(project: project)
            let scanner = linter.scanner
            let newSymbol = SymbolNaming.bareName(for: new) ?? new
            let newLiteral = String(Fixer.swiftLiteral([.text(new)]).dropFirst().dropLast())
            var sources: [String: SourceText] = [:]
            var found = 0
            var manual: [String] = []
            var lookupRanges: [String: Set<ByteRange>] = [:]   // file → literal ranges that are lookups
            for file in project.swiftFiles where project.catalogURLs(forTable: target.tableName, file: file).map(\.standardizedFileURL).contains(target.url.standardizedFileURL) {
                let source = try SourceText.read(file)
                let relative = project.relativePath(file)
                var edits: [(range: Range<Int>, text: String)] = []
                // Tests and generated files count too: they would break on a missing key.
                for site in scanner.scan(source: source.text, path: relative, includeSkipped: true)
                where (site.kind == .localizedKey || site.kind == .localizedText) && (site.table ?? "Localizable") == target.tableName
                    && site.key.map({ $0.utf8.elementsEqual(old.utf8) }) == true {
                    found += 1
                    if let range = site.literalContentRange {
                        lookupRanges[relative, default: []].insert(range)
                        edits.append((range.start..<range.end, newLiteral))
                    } else {
                        manual.append("\(relative):\(site.line)")
                    }
                }
                if usesSymbols {
                    for range in symbolReferences(to: old, table: target.tableName, in: source.text) {
                        found += 1
                        edits.append((range, newSymbol))
                    }
                }
                guard updateCode, !edits.isEmpty else { continue }
                var bytes = Array(source.text.utf8)
                for edit in edits.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
                    bytes.replaceSubrange(edit.range, with: Array(edit.text.utf8))
                }
                let updated = String(decoding: bytes, as: UTF8.self)
                guard Fixer.syntaxErrorCount(updated) <= Fixer.syntaxErrorCount(source.text) else {
                    return reject("rewriting \(relative) would break its syntax; nothing was changed")
                }
                sources[relative] = SourceText(text: updated, hasBOM: source.hasBOM)
            }
            if found > 0, !updateCode {
                return reject("\(found) reference(s) in code use \"\(old)\"; pass --update-code to rewrite them too")
            }
            if !manual.isEmpty {
                return reject("raw, multiline or interpolated literals use \"\(old)\" (\(manual.joined(separator: ", "))); change them by hand first")
            }
            // Uses that are not lookups (a key held as data, `"color.name.blue"`, or built at
            // runtime, `"color.name.\(x)"`) keep the old key alive for L10N106 and `keys remove`.
            // Renaming would strand them and let a later remove delete the translations.
            let plain = plainUses(of: old, files: linter.referenceFiles(for: target), lookups: lookupRanges, project: project)
            if !plain.isEmpty {
                return reject("\"\(old)\" is also used as a plain or built string (\(plain.prefix(5).joined(separator: ", "))\(plain.count > 5 ? ", …" : "")); rename those by hand first, then run keys rename")
            }
            if let prefix = project.config.keys.dynamicPrefixes.first(where: { old.hasPrefix($0) }) {
                return reject("\"\(old)\" is under keys.dynamicPrefixes (\(prefix)); code builds it at runtime, so rename it by hand")
            }

            // An extracted key without a source value uses the key itself as its text; keep it.
            if entry.localization(target.sourceLanguage) == nil {
                entry.setLocalization(target.sourceLanguage, LocalizationNode(unit: StringUnit(state: StringUnit.State.translated, value: old)))
            }
            if !entry.isManual { entry.extractionState = "manual" }
            target.setEntry(old, nil)
            target.setEntry(new, entry)
            catalogs.update(path, target)
            var fingerprints = try FingerprintStore.load(root: project.root)
            for locale in entry.localizationLocales {
                if let recorded = fingerprints.fingerprint(catalog: path, key: old, locale: locale) {
                    fingerprints.set(catalog: path, key: new, locale: locale, fingerprint: recorded)
                }
            }
            fingerprints.remove(catalog: path, key: old)
            result.renamed[old] = new
            try commit(catalogs: catalogs, fingerprints: fingerprints, sources: sources, project: project, result: &result)
            return result
        }
    }

    /// Catalogs loaded on demand; malformed catalogs that are not involved do not matter,
    /// and only changed catalogs are written.
    struct CatalogSet {
        let project: Project
        var loaded: [String: StringCatalog] = [:]
        var changed: Set<String> = []

        init(project: Project) { self.project = project }

        enum Lookup {
            case success(String)
            case failure(String)
        }

        mutating func resolve(_ key: String, explicit: String?) -> Lookup {
            if let explicit {
                guard let url = try? PathUtil.resolveInside(explicit, root: project.root),
                      project.catalogURLs.map(project.relativePath).contains(project.relativePath(url))
                else { return .failure("\(explicit) is not a catalog of this project") }
                let path = project.relativePath(url)
                guard let catalog = load(path, url) else { return .failure("\(path) cannot be read (L10N100)") }
                return catalog.contains(key) ? .success(path) : .failure("not found in \(path)")
            }
            var matches: [String] = []
            for url in project.catalogURLs {
                let path = project.relativePath(url)
                if load(path, url)?.contains(key) == true { matches.append(path) }
            }
            switch matches.count {
            case 0: return .failure("not found in any readable catalog")
            case 1: return .success(matches[0])
            default: return .failure("found in several catalogs (\(matches.joined(separator: ", "))); set catalog")
            }
        }

        private mutating func load(_ path: String, _ url: URL) -> StringCatalog? {
            if let catalog = loaded[path] { return catalog }
            guard let catalog = try? StringCatalog.load(url) else { return nil }
            loaded[path] = catalog
            return catalog
        }

        mutating func update(_ path: String, _ catalog: StringCatalog) {
            loaded[path] = catalog
            changed.insert(path)
        }
    }

    /// Byte ranges of the key's generated symbol where it is used as one: `.symbol` (or
    /// `.Table.symbol` for other tables) passed to a localization API or initializing a
    /// `LocalizedStringResource`. `.font(.title)` is not a reference to a key `title`.
    static func symbolReferences(to key: String, table: String, in source: String) -> [Range<Int>] {
        guard let symbol = SymbolNaming.bareName(for: key) else { return [] }
        let namespace = table == "Localizable" ? nil : SymbolNaming.tableNamespace(table)
        final class Visitor: SyntaxVisitor {
            let symbol: String
            let namespace: String?
            var found: [Range<Int>] = []
            init(symbol: String, namespace: String?) {
                self.symbol = symbol
                self.namespace = namespace
                super.init(viewMode: .sourceAccurate)
            }
            override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
                guard node.declName.baseName.text.utf8.elementsEqual(symbol.utf8) else { return .visitChildren }
                if let namespace {
                    guard let base = node.base?.as(MemberAccessExprSyntax.self), base.base == nil,
                          base.declName.baseName.text == namespace else { return .visitChildren }
                } else if node.base != nil {
                    return .visitChildren
                }
                if KeysCommand.isLocalizationContext(Syntax(node)) {
                    let token = node.declName.baseName
                    found.append(token.positionAfterSkippingLeadingTrivia.utf8Offset..<token.endPositionBeforeTrailingTrivia.utf8Offset)
                }
                return .visitChildren
            }
        }
        let visitor = Visitor(symbol: symbol, namespace: namespace)
        visitor.walk(Parser.parse(source: source))
        return visitor.found
    }

    /// `file:line` of string literals equal to `key` that are not localization lookups, and of
    /// interpolated literals whose leading text is a prefix of `key` (keys built at runtime).
    static func plainUses(of key: String, files: [URL], lookups: [String: Set<ByteRange>], project: Project) -> [String] {
        final class Visitor: SyntaxVisitor {
            let key: String
            let lookups: Set<ByteRange>
            var lines: [Int] = []
            let converter: SourceLocationConverter
            init(key: String, lookups: Set<ByteRange>, converter: SourceLocationConverter) {
                self.key = key
                self.lookups = lookups
                self.converter = converter
                super.init(viewMode: .sourceAccurate)
            }
            override func visit(_ node: StringLiteralExprSyntax) -> SyntaxVisitorContinueKind {
                var prefix = ""
                var interpolated = false
                for segment in node.segments {
                    switch segment {
                    case .stringSegment(let text): if !interpolated { prefix += text.content.text }
                    case .expressionSegment: interpolated = true
                    }
                    if interpolated { break }
                }
                let line = converter.location(for: node.positionAfterSkippingLeadingTrivia).line
                if interpolated {
                    if prefix.count >= 3, key.hasPrefix(prefix) { lines.append(line) }
                } else if node.representedLiteralValue?.utf8.elementsEqual(key.utf8) == true {
                    let range = SwiftScanner.contentRange(of: node)
                    if range.map({ !lookups.contains($0) }) ?? true { lines.append(line) }
                }
                return .skipChildren
            }
        }
        var result: [String] = []
        for file in files {
            guard let source = try? String(contentsOf: file, encoding: .utf8), source.contains(String(key.prefix(3))) else { continue }
            let relative = project.relativePath(file)
            let tree = Parser.parse(source: source)
            let visitor = Visitor(key: key, lookups: lookups[relative] ?? [], converter: SourceLocationConverter(fileName: relative, tree: tree))
            visitor.walk(tree)
            result += visitor.lines.map { "\(relative):\($0)" }
        }
        return result
    }

    /// APIs that take a generated localization symbol.
    static let symbolAPIs: Set<String> = Set(APITables.swiftUIKeyAPIs.keys).union(["Text", "LocalizedStringResource", "AttributedString", "LocalizedStringKey"])

    static func isLocalizationContext(_ node: Syntax) -> Bool {
        var expression = node
        // `.contentHello(name)`: the call is the argument.
        if let call = expression.parent?.as(FunctionCallExprSyntax.self), call.calledExpression.id == expression.id {
            expression = Syntax(call)
        }
        if let argument = expression.parent?.as(LabeledExprSyntax.self),
           let call = argument.parent?.parent?.as(FunctionCallExprSyntax.self) {
            if argument.label?.text == "localized" { return true }
            let callee: String?
            if let reference = call.calledExpression.as(DeclReferenceExprSyntax.self) {
                callee = reference.baseName.text
            } else if let member = call.calledExpression.as(MemberAccessExprSyntax.self) {
                callee = member.declName.baseName.text
            } else {
                callee = nil
            }
            return callee.map(symbolAPIs.contains) ?? false
        }
        if let initializer = expression.parent?.as(InitializerClauseSyntax.self),
           let binding = initializer.parent?.as(PatternBindingSyntax.self) {
            return binding.typeAnnotation?.type.trimmedDescription == "LocalizedStringResource"
        }
        return false
    }

    private static func commit(catalogs: CatalogSet, fingerprints: FingerprintStore, sources: [String: SourceText], project: Project, result: inout KeyChangeResult) throws {
        guard !result.removed.isEmpty || !result.renamed.isEmpty else { return }
        // Catalogs and fingerprints before code; any failed write restores everything.
        var transaction = FileTransaction()
        do {
            for path in catalogs.changed.sorted() {
                guard let catalog = catalogs.loaded[path] else { continue }
                if try transaction.write(catalog.serialized(), to: catalog.url) { result.catalogsChanged.append(path) }
            }
            try transaction.write(fingerprints.serialized(), to: fingerprints.url)
            for (file, source) in sources.sorted(by: { $0.key < $1.key }) {
                try transaction.write(source.data, to: try PathUtil.resolveInside(file, root: project.root))
                result.filesChanged.append(file)
            }
        } catch {
            transaction.rollBack()
            throw error
        }
    }
}
