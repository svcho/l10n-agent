import Foundation

public struct NewKey: Codable, Equatable, Sendable {
    public var key: String
    /// Source-language value with format specifiers (`%@`, `%lld`).
    public var value: String
    public var comment: String?
    /// Catalog path relative to the project root; defaults to the project's default catalog.
    public var catalog: String?

    public init(key: String, value: String, comment: String? = nil, catalog: String? = nil) {
        self.key = key
        self.value = value
        self.comment = comment
        self.catalog = catalog
    }
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
                } else if let url = project.defaultCatalogURL(for: nil) {
                    catalogPath = project.relativePath(url)
                } else {
                    catalogPath = "Localizable.xcstrings"
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
                if project.usesSymbols {
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
                entry.setLocalization(catalog.sourceLanguage, LocalizationNode(unit: StringUnit(state: StringUnit.State.translated, value: item.value)))
                catalog.setEntry(item.key, entry)
                catalogs[catalogPath] = catalog
                result.added.append(item.key)
            }
            for catalog in catalogs.values {
                try catalog.write()
            }
            return result
        }
    }
}
