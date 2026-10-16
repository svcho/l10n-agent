import Foundation

/// One String Catalog produced (or extended) from legacy `.lproj` tables.
public struct MigratedTable: Codable, Equatable, Sendable {
    /// Catalog path relative to the project root.
    public var catalog: String
    /// The `.strings` / `.stringsdict` files it was built from.
    public var sources: [String]
    public var keys: Int
    public var locales: [String]
    /// `true` when the catalog did not exist before.
    public var created: Bool
    /// Values that already existed in the catalog with different text; the catalog's value is kept.
    public var conflicts: [String]
}

public struct MigrateResult: Codable, Equatable, Sendable {
    public var applied: Bool
    public var tables: [MigratedTable]
    /// File → why it was left alone on purpose (storyboard strings, a Base duplicate).
    public var skipped: [String: String]
    /// File → why its table could not be migrated (a parse error). Nothing of that table is written.
    public var failed: [String: String]
    /// Legacy files deleted with `removeLegacy`. Files with conflicting values are kept.
    public var removed: [String]
    public var notes: [String]
}

/// Converts legacy `<locale>.lproj/<Table>.strings` and `.stringsdict` files into
/// `<Table>.xcstrings` next to the `.lproj` folders, the way Xcode's "Migrate to String
/// Catalog" does, but headless. Every value is kept, existing translations become
/// `translated`, plural `.stringsdict` rules become variations or substitutions, and each
/// file's parse is cross-checked against `PropertyListSerialization`.
public enum MigrateCommand {
    public static func run(project: Project, apply: Bool, removeLegacy: Bool = false) throws -> MigrateResult {
        // Reads, writes and deletes happen under one lock, like every other mutating command.
        guard apply else { return try perform(project: project, apply: false, removeLegacy: false) }
        return try ProjectLock.withLock(root: project.root) {
            try perform(project: project, apply: true, removeLegacy: removeLegacy)
        }
    }

    private static func perform(project: Project, apply: Bool, removeLegacy: Bool) throws -> MigrateResult {
        var result = MigrateResult(applied: apply, tables: [], skipped: [:], failed: [:], removed: [], notes: [])
        let source = project.sourceLanguage
        let groups = discoverTables(project: project)
        guard !groups.isEmpty else {
            result.notes.append("No .lproj/*.strings or *.stringsdict files found.")
            return result
        }

        var catalogs: [String: StringCatalog] = [:]
        var fingerprints = try FingerprintStore.load(root: project.root)
        var migratedFiles: [URL] = []
        var conflictingFiles: Set<URL> = []

        for group in groups {
            let catalogURL = group.folder.appendingPathComponent("\(group.table).xcstrings").standardizedFileURL
            let catalogPath = project.relativePath(catalogURL)
            if group.isInterfaceBuilder {
                for file in group.files { result.skipped[project.relativePath(file.url)] = "Interface Builder strings for \(group.table).storyboard/.xib; localize those in Xcode" }
                continue
            }
            let sourceLocale = group.files.contains { $0.locale == source } ? source : (group.files.contains { $0.locale == "Base" } ? "Base" : nil)
            guard let sourceLocale else {
                for file in group.files { result.skipped[project.relativePath(file.url)] = "no \(source).lproj or Base.lproj version of \(group.table) to use as the source" }
                continue
            }

            // Parse every file of the table; a file that does not parse stops only its own table.
            var parsed: [(file: LegacyFile, entries: [LegacyEntry])] = []
            var failure: String?
            for file in group.files {
                do {
                    parsed.append((file, try file.kind == .strings ? StringsFile.parse(Data(contentsOf: file.url)) : StringsDictFile.parse(Data(contentsOf: file.url))))
                } catch {
                    failure = "\(project.relativePath(file.url)): \(error)"
                    break
                }
            }
            if let failure {
                for file in group.files { result.failed[project.relativePath(file.url)] = failure }
                continue
            }

            // An existing catalog keeps every value it already has; legacy values only fill gaps.
            let exists = FileManager.default.fileExists(atPath: catalogURL.path)
            let original = try catalogs[catalogPath] ?? (exists ? StringCatalog.load(catalogURL, fallbackSourceLanguage: source) : nil)
            var catalog = original ?? StringCatalog.empty(url: catalogURL, sourceLanguage: source)
            var table = MigratedTable(catalog: catalogPath, sources: [], keys: 0, locales: [], created: !exists, conflicts: [])
            var keys: Set<ByteKey> = []
            // key → locales this migration wrote, and the legacy source each translation was made from.
            var written: [ByteKey: Set<String>] = [:]
            var legacySource: [ByteKey: LocalizationNode] = [:]

            // .strings first, then .stringsdict: a plural rule overrides a plain value, as in Foundation.
            let ordered = parsed.sorted { ($0.file.kind == .strings ? 0 : 1, $0.file.locale) < ($1.file.kind == .strings ? 0 : 1, $1.file.locale) }
            for (file, entries) in ordered {
                if file.locale == "Base", sourceLocale != "Base" {
                    result.skipped[project.relativePath(file.url)] = "Base.lproj duplicates \(source).lproj; \(source) is used"
                    continue
                }
                let locale = file.locale == "Base" ? source : file.locale
                if !table.locales.contains(locale) { table.locales.append(locale) }
                table.sources.append(project.relativePath(file.url))
                for legacy in entries {
                    keys.insert(ByteKey(legacy.key))
                    var entry = catalog.entry(legacy.key) ?? CatalogEntry()
                    if catalog.entry(legacy.key) == nil, KeyPolicy.looksSemantic(legacy.key) {
                        // Semantic keys become manual (Xcode never marks them stale); English-text
                        // keys stay extracted so Xcode keeps managing them from code.
                        entry.extractionState = "manual"
                    }
                    if entry.comment == nil, let comment = legacy.comment, locale == source {
                        entry.comment = comment
                    }
                    if locale == source { legacySource[ByteKey(legacy.key)] = legacy.node }
                    if let kept = original?.entry(legacy.key)?.localization(locale) {
                        if kept.raw != legacy.node.raw {
                            table.conflicts.append("\(legacy.key) [\(locale)]")
                            conflictingFiles.insert(file.url)
                        }
                    } else {
                        entry.setLocalization(locale, legacy.node)
                        written[ByteKey(legacy.key), default: []].insert(locale)
                    }
                    catalog.setEntry(legacy.key, entry)
                }
                migratedFiles.append(file.url)
            }
            table.sources.sort()
            // Keys that only exist in other locales still need a source value.
            for key in keys {
                guard var entry = catalog.entry(key.string), entry.localization(source) == nil else { continue }
                entry.setLocalization(source, LocalizationNode(unit: StringUnit(state: StringUnit.State.translated, value: key.string)))
                catalog.setEntry(key.string, entry)
                result.notes.append("\(catalogPath): \"\(key.string)\" had no \(source) value; the key is used as source text")
            }
            table.keys = keys.count
            table.locales.sort()

            try verify(parsed: parsed, catalog: catalog, source: source, sourceLocale: sourceLocale, conflicts: Set(table.conflicts))

            // Record what each migrated translation was made from: its legacy source text. When
            // the catalog kept a different source, the translation then shows as stale (L10N103).
            // Translations that were already in the catalog keep their own records.
            for (key, locales) in written {
                guard let entry = catalog.entry(key.string) else { continue }
                let made = legacySource[key] ?? entry.sourceNode(key: key.string, sourceLanguage: source)
                let fingerprint = FingerprintStore.sourceFingerprint(made)
                for locale in locales where locale != source && fingerprints.fingerprint(catalog: catalogPath, key: key.string, locale: locale) == nil {
                    fingerprints.set(catalog: catalogPath, key: key.string, locale: locale, fingerprint: fingerprint)
                }
            }
            catalogs[catalogPath] = catalog
            result.tables.append(table)

            if project.usesSymbols(for: catalogURL) {
                let manual = catalog.entries.filter { $0.entry.isManual }.map(\.key)
                for collision in SymbolNaming.collisions(among: manual) {
                    result.notes.append("\(catalogPath): keys \(collision.joined(separator: ", ")) generate the same Swift symbol; rename one before building with STRING_CATALOG_GENERATE_SYMBOLS")
                }
            }
        }

        for projectFile in project.xcode.projectFiles {
            guard let text = try? String(contentsOf: projectFile.appendingPathComponent("project.pbxproj"), encoding: .utf8) else { continue }
            for table in Set(result.tables.map { URL(fileURLWithPath: $0.catalog).deletingPathExtension().lastPathComponent }) {
                if text.contains("\(table).strings") || text.contains("\(table).stringsdict") {
                    result.notes.append("\(project.relativePath(projectFile)) references \(table).strings: in Xcode, remove that file reference and add \(table).xcstrings to the same targets (synchronized folders pick it up automatically).")
                }
            }
        }

        guard apply else { return result }
        var transaction = FileTransaction()
        do {
            for (_, catalog) in catalogs.sorted(by: { $0.key < $1.key }) {
                try transaction.write(catalog.serialized(), to: catalog.url)
            }
            try transaction.write(fingerprints.serialized(), to: fingerprints.url)
        } catch {
            transaction.rollBack()
            throw error
        }
        if removeLegacy {
            for url in migratedFiles {
                // Its conflicting values exist nowhere else; keep the file for a manual merge.
                if conflictingFiles.contains(url) {
                    result.notes.append("kept \(project.relativePath(url)): some of its values differ from the existing catalog")
                    continue
                }
                try FileManager.default.removeItem(at: url)
                result.removed.append(project.relativePath(url))
                let folder = url.deletingLastPathComponent()
                if (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.filter({ $0 != ".DS_Store" }).isEmpty == true {
                    try? FileManager.default.removeItem(at: folder)
                }
            }
            result.removed.sort()
        }
        return result
    }

    /// Every parsed value must be in the catalog unchanged, except where an existing
    /// catalog value won a conflict or a plural rule replaced a plain value.
    static func verify(parsed: [(file: LegacyFile, entries: [LegacyEntry])], catalog: StringCatalog, source: String, sourceLocale: String, conflicts: Set<String>) throws {
        let pluralKeys = Set(parsed.filter { $0.file.kind == .stringsdict }.flatMap { file in file.entries.map { "\($0.key) [\(file.file.locale == "Base" ? source : file.file.locale)]" } })
        for (file, entries) in parsed {
            if file.locale == "Base", sourceLocale != "Base" { continue }
            let locale = file.locale == "Base" ? source : file.locale
            for legacy in entries {
                let label = "\(legacy.key) [\(locale)]"
                if conflicts.contains(label) || (file.kind == .strings && pluralKeys.contains(label)) { continue }
                guard let node = catalog.entry(legacy.key)?.localization(locale), node.raw == legacy.node.raw else {
                    throw L10nError.config("migration check failed for \(label) from \(file.url.lastPathComponent); nothing was written")
                }
            }
        }
    }

    // MARK: Discovery

    struct LegacyFile {
        enum Kind { case strings, stringsdict }
        var url: URL
        var locale: String
        var kind: Kind
    }

    struct TableGroup {
        var folder: URL
        var table: String
        var files: [LegacyFile]
        var isInterfaceBuilder: Bool
    }

    static func discoverTables(project: Project) -> [TableGroup] {
        let excludes = project.config.exclude.map(Glob.init)
        let resolvedRoot = project.root.resolvingSymlinksInPath().path
        var groups: [String: TableGroup] = [:]
        let enumerator = FileManager.default.enumerator(at: project.root, includingPropertiesForKeys: [.isDirectoryKey], options: [])
        while let url = enumerator?.nextObject() as? URL {
            let name = url.lastPathComponent
            let relative = project.relativePath(url)
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDirectory else { continue }
            if Project.skippedDirectories.contains(name) || name.hasPrefix(".") || ["xcodeproj", "xcworkspace", "xcassets", "bundle", "app", "framework"].contains(url.pathExtension)
                || excludes.contains(where: { $0.matches(relative) || $0.matches(relative + "/") }) {
                enumerator?.skipDescendants()
                continue
            }
            guard url.pathExtension == "lproj" else { continue }
            enumerator?.skipDescendants()
            let locale = url.deletingPathExtension().lastPathComponent
            let folder = url.deletingLastPathComponent().standardizedFileURL
            let contents = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
            for file in contents {
                // Symlinked files must resolve inside the project; nothing outside it is read or deleted.
                guard file.resolvingSymlinksInPath().path.hasPrefix(resolvedRoot + "/") else { continue }
                let kind: LegacyFile.Kind
                switch file.pathExtension {
                case "strings": kind = .strings
                case "stringsdict": kind = .stringsdict
                default: continue
                }
                let table = file.deletingPathExtension().lastPathComponent
                let id = folder.path + "\u{1F}" + table
                var group = groups[id] ?? TableGroup(folder: folder, table: table, files: [], isInterfaceBuilder: false)
                group.files.append(LegacyFile(url: file.standardizedFileURL, locale: locale, kind: kind))
                groups[id] = group
            }
        }
        // `de.lproj/Main.strings` next to `Base.lproj/Main.storyboard` belongs to the storyboard.
        for (id, group) in groups {
            let lprojs = (try? FileManager.default.contentsOfDirectory(at: group.folder, includingPropertiesForKeys: nil))?.filter { $0.pathExtension == "lproj" } ?? []
            let isInterfaceBuilder = lprojs.contains { lproj in
                ["storyboard", "xib"].contains { FileManager.default.fileExists(atPath: lproj.appendingPathComponent("\(group.table).\($0)").path) }
            }
            groups[id]?.isInterfaceBuilder = isInterfaceBuilder
            groups[id]?.files.sort { ($0.locale, $0.url.path) < ($1.locale, $1.url.path) }
        }
        return groups.values.sorted { ($0.folder.path, $0.table) < ($1.folder.path, $1.table) }
    }
}

/// A key with its value as a catalog localization node and the comment written above it.
struct LegacyEntry: Equatable {
    var key: String
    var node: LocalizationNode
    var comment: String?
}

/// Parser for the old-style property list format of `.strings` files, keeping order and
/// the comment directly above each entry.
enum StringsFile {
    struct ParseError: Error, CustomStringConvertible {
        var description: String
    }

    static func decode(_ data: Data) throws -> String {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            guard let text = String(data: data, encoding: .utf16) else { throw ParseError(description: "invalid UTF-16") }
            return text
        }
        // UTF-16 without a byte order mark (old genstrings output): ASCII text then has a NUL
        // in every other byte, which UTF-8 text never does.
        let bytes = [UInt8](data)
        if bytes.count >= 2, bytes.contains(0) {
            let oddZeros = stride(from: 1, to: bytes.count, by: 2).filter { bytes[$0] == 0 }.count
            let evenZeros = stride(from: 0, to: bytes.count, by: 2).filter { bytes[$0] == 0 }.count
            let encoding: String.Encoding = oddZeros >= evenZeros ? .utf16LittleEndian : .utf16BigEndian
            guard let text = String(data: data, encoding: encoding) else { throw ParseError(description: "invalid UTF-16") }
            return text
        }
        let body = data.starts(with: [0xEF, 0xBB, 0xBF]) ? data.dropFirst(3) : data[...]
        if let text = String(data: Data(body), encoding: .utf8) { return text }
        throw ParseError(description: "the file is neither UTF-8 nor UTF-16")
    }

    static func parse(_ data: Data) throws -> [LegacyEntry] {
        let text = try decode(data)
        let scalars = Array(text.unicodeScalars)
        var index = 0
        var entries: [LegacyEntry] = []
        var pendingComment: String?
        var newlinesSinceComment = 0

        func fail(_ message: String) -> ParseError {
            let line = scalars[0..<min(index, scalars.count)].filter { $0 == "\n" }.count + 1
            return ParseError(description: "\(message) at line \(line)")
        }
        func skipTrivia() throws {
            while index < scalars.count {
                let scalar = scalars[index]
                if scalar == "\n" {
                    newlinesSinceComment += 1
                    index += 1
                } else if scalar.properties.isWhitespace {
                    index += 1
                } else if scalar == "/", index + 1 < scalars.count, scalars[index + 1] == "*" {
                    let start = index + 2
                    index = start
                    while index + 1 < scalars.count, !(scalars[index] == "*" && scalars[index + 1] == "/") { index += 1 }
                    guard index + 1 < scalars.count else { throw fail("unterminated comment") }
                    pendingComment = String(String.UnicodeScalarView(scalars[start..<index]))
                    newlinesSinceComment = 0
                    index += 2
                } else if scalar == "/", index + 1 < scalars.count, scalars[index + 1] == "/" {
                    let start = index + 2
                    index = start
                    while index < scalars.count, scalars[index] != "\n" { index += 1 }
                    pendingComment = String(String.UnicodeScalarView(scalars[start..<index]))
                    newlinesSinceComment = 0
                } else {
                    return
                }
            }
        }
        func isUnquoted(_ scalar: Unicode.Scalar) -> Bool {
            CharacterSet.alphanumerics.contains(scalar) || "_$+/:.-".unicodeScalars.contains(scalar)
        }
        func readString() throws -> String {
            guard index < scalars.count else { throw fail("expected a string") }
            if scalars[index] != "\"" {
                let start = index
                while index < scalars.count, isUnquoted(scalars[index]) { index += 1 }
                guard index > start else { throw fail("unexpected character \"\(scalars[index])\"") }
                return String(String.UnicodeScalarView(scalars[start..<index]))
            }
            index += 1
            var result = String.UnicodeScalarView()
            while index < scalars.count {
                let scalar = scalars[index]
                if scalar == "\"" {
                    index += 1
                    return String(result)
                }
                if scalar == "\\" {
                    index += 1
                    guard index < scalars.count else { throw fail("unterminated escape") }
                    let escape = scalars[index]
                    index += 1
                    switch escape {
                    case "n": result.append("\n")
                    case "t": result.append("\t")
                    case "r": result.append("\r")
                    case "a": result.append("\u{07}")
                    case "b": result.append("\u{08}")
                    case "f": result.append("\u{0C}")
                    case "v": result.append("\u{0B}")
                    case "U", "u":
                        var hex = ""
                        while hex.count < 4, index < scalars.count, scalars[index].properties.isASCIIHexDigit {
                            hex.unicodeScalars.append(scalars[index])
                            index += 1
                        }
                        guard var value = UInt32(hex, radix: 16) else { throw fail("invalid \\U escape") }
                        // A UTF-16 surrogate pair written as two escapes.
                        if (0xD800...0xDBFF).contains(value), index + 5 < scalars.count, scalars[index] == "\\",
                           scalars[index + 1] == "U" || scalars[index + 1] == "u",
                           let low = UInt32(String(String.UnicodeScalarView(scalars[(index + 2)..<(index + 6)])), radix: 16), (0xDC00...0xDFFF).contains(low) {
                            value = 0x10000 + ((value - 0xD800) << 10) + (low - 0xDC00)
                            index += 6
                        }
                        guard let decoded = Unicode.Scalar(value) else { throw fail("invalid \\U escape") }
                        result.append(decoded)
                    case "0"..."7":
                        var octal = String(escape)
                        while octal.count < 3, index < scalars.count, ("0"..."7").contains(scalars[index]) {
                            octal.unicodeScalars.append(scalars[index])
                            index += 1
                        }
                        guard let value = UInt32(octal, radix: 8), let decoded = Unicode.Scalar(value) else { throw fail("invalid octal escape") }
                        result.append(decoded)
                    default:
                        result.append(escape)
                    }
                    continue
                }
                result.append(scalar)
                index += 1
            }
            throw fail("unterminated string")
        }

        var values: [String: String] = [:]
        while true {
            try skipTrivia()
            guard index < scalars.count else { break }
            // The comment belongs to this entry only when no blank line separates them.
            let comment = newlinesSinceComment <= 1 ? pendingComment.flatMap(cleanComment) : nil
            pendingComment = nil
            let key = try readString()
            try skipTrivia()
            var value = key
            if index < scalars.count, scalars[index] == "=" {
                index += 1
                try skipTrivia()
                value = try readString()
                try skipTrivia()
            }
            guard index < scalars.count, scalars[index] == ";" else { throw fail("expected \";\" after \"\(key)\"") }
            index += 1
            values[key] = value
            let entry = LegacyEntry(key: key, node: LocalizationNode(unit: StringUnit(state: StringUnit.State.translated, value: value)), comment: comment)
            // A repeated key: the last value wins, as in Foundation.
            if let existing = entries.firstIndex(where: { $0.key.utf8.elementsEqual(key.utf8) }) {
                entries[existing] = LegacyEntry(key: key, node: entry.node, comment: entry.comment ?? entries[existing].comment)
            } else {
                entries.append(entry)
            }
        }

        // Cross-check with Foundation's own parser (on the decoded text, so encodings Foundation
        // does not detect itself, such as UTF-16 without a byte order mark, are compared too).
        if !entries.isEmpty {
            guard let reference = try? PropertyListSerialization.propertyList(from: Data(text.utf8), format: nil) as? [String: String] else {
                throw ParseError(description: "Foundation cannot read this file as a strings table")
            }
            guard reference == values else {
                let differing = Set(reference.keys).symmetricDifference(values.keys).sorted().prefix(3)
                throw ParseError(description: "parsed values differ from Foundation's reading\(differing.isEmpty ? "" : " (\(differing.joined(separator: ", ")))")")
            }
        }
        return entries
    }

    /// Drops the comment markers' padding and genstrings' placeholder comment.
    static func cleanComment(_ raw: String) -> String? {
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces).drop { $0 == "*" }.trimmingCharacters(in: .whitespaces)
        }
        let text = lines.filter { !$0.isEmpty }.joined(separator: " ")
        if text.isEmpty || text == "No comment provided by engineer." { return nil }
        return text
    }
}

/// `.stringsdict` plural rules → catalog plural variations or substitutions.
enum StringsDictFile {
    static func parse(_ data: Data) throws -> [LegacyEntry] {
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw StringsFile.ParseError(description: "not a dictionary")
        }
        var entries: [LegacyEntry] = []
        for key in plist.keys.sorted(by: { $0.utf8.lexicographicallyPrecedes($1.utf8) }) {
            guard let rule = plist[key] as? [String: Any], let format = rule["NSStringLocalizedFormatKey"] as? String else {
                throw StringsFile.ParseError(description: "\(key) has no NSStringLocalizedFormatKey")
            }
            entries.append(LegacyEntry(key: key, node: try node(format: format, rule: rule, key: key), comment: nil))
        }
        return entries
    }

    static let categories = ["zero", "one", "two", "few", "many", "other"]

    static func node(format: String, rule: [String: Any], key: String) throws -> LocalizationNode {
        let translated = StringUnit.State.translated
        // Variables in order of their %#@name@ (or %n$#@name@) tokens, with the argument each consumes.
        let pattern = /%(?:([0-9]+)\$)?#@([A-Za-z0-9_]+)@/
        var variables: [(name: String, argNum: Int)] = []
        var normalized = format
        var sequential = 0
        var cursor = format.startIndex
        // Count plain arguments between variables so argNum matches the call's argument order.
        for match in format.matches(of: pattern) {
            let between = String(format[cursor..<match.range.lowerBound])
            sequential += FormatSpecifier.tokens(in: between).filter { if case .argument = $0.kind { return true } else { return false } }.count
            let argNum: Int
            if let explicit = match.1.flatMap({ Int($0) }) {
                argNum = explicit
            } else {
                sequential += 1
                argNum = sequential
            }
            variables.append((String(match.2), argNum))
            cursor = match.range.upperBound
        }
        normalized = format.replacing(pattern) { "%#@\($0.2)@" }
        guard !variables.isEmpty else {
            throw StringsFile.ParseError(description: "\(key) has no %#@variable@ in its format")
        }

        func plural(_ name: String) throws -> (valueType: String, cases: [String: String]) {
            guard let spec = rule[name] as? [String: Any] else {
                throw StringsFile.ParseError(description: "\(key) uses %#@\(name)@ but defines no \(name) rule")
            }
            guard spec["NSStringFormatSpecTypeKey"] as? String == "NSStringPluralRuleType" else {
                throw StringsFile.ParseError(description: "\(key): \(spec["NSStringFormatSpecTypeKey"] ?? "?") rules are not supported; migrate it in Xcode")
            }
            let valueType = spec["NSStringFormatValueTypeKey"] as? String ?? "d"
            var cases: [String: String] = [:]
            for category in categories {
                if let value = spec[category] as? String { cases[category] = value }
            }
            guard cases["other"] != nil else {
                throw StringsFile.ParseError(description: "\(key): rule \(name) has no \"other\" case")
            }
            return (valueType, cases)
        }

        var node = LocalizationNode(raw: JSONObject())
        if variables.count == 1, normalized == "%#@\(variables[0].name)@" {
            // The whole string varies: plural variations directly on the localization.
            let (_, cases) = try plural(variables[0].name)
            for (category, value) in cases {
                node.setUnit(StringUnit(state: translated, value: value), at: ["variations", "plural", category])
            }
            return node
        }
        node.stringUnit = StringUnit(state: translated, value: normalized)
        for variable in variables {
            let (valueType, cases) = try plural(variable.name)
            node.setValue(.number(String(variable.argNum)), at: ["substitutions", variable.name, "argNum"])
            node.setValue(.string(valueType), at: ["substitutions", variable.name, "formatSpecifier"])
            for (category, value) in cases {
                // Inside a substitution the counted number is written %arg.
                var text = value
                for token in FormatSpecifier.tokens(in: value).reversed() {
                    guard case .argument = token.kind else { continue }
                    let bare = token.isPositional ? token.text.replacing(/^%[0-9]+\$/, with: "%") : token.text
                    if bare == "%" + valueType { text.replaceSubrange(token.range, with: "%arg") }
                }
                node.setUnit(StringUnit(state: translated, value: text), at: ["substitutions", variable.name, "variations", "plural", category])
            }
        }
        return node
    }
}
