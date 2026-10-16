import Foundation

public struct NewKey: Codable, Equatable, Sendable {
    public var key: String
    /// Source-language value with format specifiers (`%@`, `%lld`).
    public var value: String
    public var comment: String?
    /// Catalog path relative to the project root; defaults to the project's default catalog.
    public var catalog: String?
    /// `false` marks the key "Don't translate". Keys that are not semantic (`%lld`, `•`)
    /// are added the way Xcode extracts them, with no source value or key-style check.
    public var shouldTranslate: Bool?

    public init(key: String, value: String, comment: String? = nil, catalog: String? = nil, shouldTranslate: Bool? = nil) {
        self.key = key
        self.value = value
        self.comment = comment
        self.catalog = catalog
        self.shouldTranslate = shouldTranslate
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decode(String.self, forKey: .key)
        shouldTranslate = try container.decodeIfPresent(Bool.self, forKey: .shouldTranslate)
        // A don't-translate literal (`%lld`) is its own value; semantic keys still need one.
        if shouldTranslate == false, !KeyPolicy.looksSemantic(key) {
            value = try container.decodeIfPresent(String.self, forKey: .value) ?? key
        } else {
            value = try container.decode(String.self, forKey: .value)
        }
        comment = try container.decodeIfPresent(String.self, forKey: .comment)
        catalog = try container.decodeIfPresent(String.self, forKey: .catalog)
    }

    /// A don't-translate entry for a literal Xcode extracts as is (`Text("\(count)")` → `%lld`).
    var isExtractedLiteral: Bool { shouldTranslate == false && !KeyPolicy.looksSemantic(key) }
}

public struct AddKeysResult: Codable, Equatable, Sendable {
    public var added: [String]
    public var unchanged: [String]
    public var rejected: [String: String]
    /// Symbol to use in code for each added key when generated symbols are enabled.
    public var symbols: [String: String]
}

public enum AddKeysCommand {
    /// Adds manual keys to catalogs after validating key style and symbol collisions.
    public static func run(project: Project, keys: [NewKey]) throws -> AddKeysResult {
        try ProjectLock.withLock(root: project.root) {
            var result = AddKeysResult(added: [], unchanged: [], rejected: [:], symbols: [:])
            var catalogs: [String: StringCatalog] = [:]
            for item in keys {
                let catalogPath: String
                if let explicit = item.catalog {
                    catalogPath = project.relativePath(try PathUtil.resolveInside(explicit, root: project.root))
                } else if let configured = project.config.catalog {
                    catalogPath = configured
                } else if let url = InitCommand.unambiguousCatalog(project) {
                    catalogPath = project.relativePath(url)
                } else if project.catalogURLs.isEmpty {
                    catalogPath = "Localizable.xcstrings"
                } else {
                    let candidates = project.catalogURLs.map(project.relativePath).joined(separator: ", ")
                    result.rejected[item.key] = "several catalogs could hold this key (\(candidates)); set catalog"
                    continue
                }
                guard catalogPath.hasSuffix(".xcstrings") else {
                    result.rejected[item.key] = "catalog must be an .xcstrings file"
                    continue
                }
                var catalog: StringCatalog
                if let loaded = catalogs[catalogPath] {
                    catalog = loaded
                } else {
                    let url = try PathUtil.resolveInside(catalogPath, root: project.root)
                    catalog = FileManager.default.fileExists(atPath: url.path) ? try StringCatalog.load(url) : StringCatalog.empty(url: url, sourceLanguage: project.sourceLanguage)
                }

                if item.isExtractedLiteral {
                    if let existing = catalog.entry(item.key), !existing.shouldTranslate {
                        result.unchanged.append(item.key)
                        continue
                    }
                    // New, or an extracted entry that is now marked "Don't translate".
                    var entry = catalog.entry(item.key) ?? CatalogEntry()
                    entry.shouldTranslate = false
                    if let comment = item.comment { entry.comment = comment }
                    catalog.setEntry(item.key, entry)
                    catalogs[catalogPath] = catalog
                    result.added.append(item.key)
                    continue
                }
                let violations = project.config.keys.violations(for: item.key)
                if !violations.isEmpty {
                    result.rejected[item.key] = violations.joined(separator: "; ")
                    continue
                }
                if let existing = catalog.entry(item.key) {
                    if existing.localization(catalog.sourceLanguage)?.stringUnit?.value == item.value {
                        result.unchanged.append(item.key)
                    } else {
                        result.rejected[item.key] = "key exists with different text"
                    }
                    continue
                }
                if project.usesSymbols(for: catalog.url) {
                    guard let reference = SymbolNaming.reference(for: item.key, table: catalog.tableName) else {
                        result.rejected[item.key] = "too close to a Swift keyword to generate a symbol"
                        continue
                    }
                    let bare = SymbolNaming.bareName(for: item.key)
                    if let clash = catalog.entries.first(where: { $0.entry.isManual && SymbolNaming.bareName(for: $0.key) == bare }) {
                        result.rejected[item.key] = "generates the same symbol as \"\(clash.key)\""
                        continue
                    }
                    result.symbols[item.key] = reference
                    if catalog.version == "1.0" { catalog.version = "1.1" }
                }
                var entry = CatalogEntry()
                entry.extractionState = "manual"
                entry.comment = item.comment
                if item.shouldTranslate == false { entry.shouldTranslate = false }
                entry.setLocalization(catalog.sourceLanguage, LocalizationNode(unit: StringUnit(state: StringUnit.State.translated, value: item.value)))
                catalog.setEntry(item.key, entry)
                catalogs[catalogPath] = catalog
                result.added.append(item.key)
            }
            // All catalogs or none, so a failed write never leaves keys half-added.
            var transaction = FileTransaction()
            do {
                for catalog in catalogs.values.sorted(by: { $0.url.path < $1.url.path }) {
                    try transaction.write(catalog.serialized(), to: catalog.url)
                }
            } catch {
                transaction.rollBack()
                throw error
            }
            return result
        }
    }
}
