import Foundation

/// Records which source text each translation was made from, so source edits can be
/// detected. Xcode's own tooling does not mark translations when a manual key's source
/// value changes, so this small file is the only extra state the tool keeps.
///
/// Stored at `.l10n-agent/fingerprints.json`; commit it with the catalogs.
public struct FingerprintStore: Sendable {
    public let url: URL
    /// catalog path (relative to root) → key (byte-exact) → locale → source fingerprint
    public private(set) var entries: [String: [ByteKey: [String: String]]]

    public static func path(root: URL) -> URL {
        root.appendingPathComponent(".l10n-agent/fingerprints.json")
    }

    public static func load(root: URL) throws -> FingerprintStore {
        let url = path(root: root)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return FingerprintStore(url: url, entries: [:])
        }
        // Anything but the exact schema stops the command: silently treating a damaged file
        // as empty would let the next write erase the stale-translation history.
        func malformed(_ detail: String) -> L10nError {
            .config("\(url.path) is malformed (\(detail)); restore it from git, or delete it to start over")
        }
        let value: JSONValue
        do {
            value = try JSONParser.parse(Data(contentsOf: url))
        } catch {
            throw malformed("\(error)")
        }
        guard let root = value.objectValue else { throw malformed("expected an object") }
        guard root["version"] == .number("1") else { throw malformed("unsupported version") }
        guard let catalogs = root["catalogs"]?.objectValue else { throw malformed("missing \"catalogs\" object") }
        var entries: [String: [ByteKey: [String: String]]] = [:]
        for catalog in catalogs.members {
            guard let keys = catalog.value.objectValue else { throw malformed("catalog \(catalog.key) is not an object") }
            for key in keys.members {
                guard let locales = key.value.objectValue else { throw malformed("key \(key.key) is not an object") }
                for locale in locales.members {
                    guard let hash = locale.value.stringValue else { throw malformed("fingerprint for \(key.key)/\(locale.key) is not a string") }
                    entries[catalog.key, default: [:]][ByteKey(key.key), default: [:]][locale.key] = hash
                }
            }
        }
        return FingerprintStore(url: url, entries: entries)
    }

    public func fingerprint(catalog: String, key: String, locale: String) -> String? {
        entries[catalog]?[ByteKey(key)]?[locale]
    }

    public mutating func set(catalog: String, key: String, locale: String, fingerprint: String) {
        entries[catalog, default: [:]][ByteKey(key), default: [:]][locale] = fingerprint
    }

    public mutating func remove(catalog: String, key: String, locale: String? = nil) {
        if let locale {
            entries[catalog]?[ByteKey(key)]?[locale] = nil
            if entries[catalog]?[ByteKey(key)]?.isEmpty == true { entries[catalog]?[ByteKey(key)] = nil }
        } else {
            entries[catalog]?[ByteKey(key)] = nil
        }
    }

    /// Drops fingerprints for keys or locales that no longer exist.
    public mutating func prune(catalog: String, existing: (String, String) -> Bool) {
        guard let keys = entries[catalog] else { return }
        for (key, locales) in keys {
            for locale in locales.keys where !existing(key.string, locale) {
                remove(catalog: catalog, key: key.string, locale: locale)
            }
        }
        if entries[catalog]?.isEmpty == true { entries[catalog] = nil }
    }

    public func save() throws {
        var catalogs = JSONObject()
        for (catalog, keys) in entries {
            var keyObject = JSONObject()
            for (key, locales) in keys {
                keyObject[key.string] = .object(JSONObject(locales.map { JSONObject.Member(key: $0.key, value: .string($0.value)) }))
            }
            catalogs[catalog] = .object(keyObject)
        }
        let root = JSONValue.object(JSONObject(["catalogs": .object(catalogs), "version": .number("1")]))
        try AtomicFile.write(XcodeJSONWriter.string(root) + "\n", to: url)
    }

    /// Fingerprint of a key's source-language content (all variation values, not the comment).
    /// Includes substitution metadata (`argNum`, `formatSpecifier`) when present, so changing
    /// which argument a `%#@name@` plural uses also marks translations stale.
    public static func sourceFingerprint(_ node: LocalizationNode) -> String {
        var parts = node.leaves.map { "\($0.path.joined(separator: "/"))=\($0.unit.value)" }
        for (name, substitution) in node.substitutions.sorted(by: { $0.key < $1.key }) {
            parts.append("substitution/\(name)=\(substitution.argNum.map(String.init) ?? "")/\(substitution.formatSpecifier ?? "")")
        }
        return Hashing.shortHash(parts.joined(separator: "\u{1E}"))
    }
}
