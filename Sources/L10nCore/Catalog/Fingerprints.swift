import Foundation

/// Records which source text each translation was made from, so source edits can be
/// detected. Xcode's own tooling does not mark translations when a manual key's source
/// value changes, so this small file is the only extra state the tool keeps.
///
/// Stored at `.l10n-agent/fingerprints.json`; commit it with the catalogs.
public struct FingerprintStore: Sendable {
    public let url: URL
    /// catalog path (relative to root) → key → locale → source fingerprint
    public private(set) var entries: [String: [String: [String: String]]]

    public static func path(root: URL) -> URL {
        root.appendingPathComponent(".l10n-agent/fingerprints.json")
    }

    public static func load(root: URL) throws -> FingerprintStore {
        let url = path(root: root)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return FingerprintStore(url: url, entries: [:])
        }
        let value = try JSONParser.parse(Data(contentsOf: url))
        var entries: [String: [String: [String: String]]] = [:]
        for catalog in value["catalogs"]?.objectValue?.members ?? [] {
            for key in catalog.value.objectValue?.members ?? [] {
                for locale in key.value.objectValue?.members ?? [] {
                    if let hash = locale.value.stringValue {
                        entries[catalog.key, default: [:]][key.key, default: [:]][locale.key] = hash
                    }
                }
            }
        }
        return FingerprintStore(url: url, entries: entries)
    }

    public func fingerprint(catalog: String, key: String, locale: String) -> String? {
        entries[catalog]?[key]?[locale]
    }

    public mutating func set(catalog: String, key: String, locale: String, fingerprint: String) {
        entries[catalog, default: [:]][key, default: [:]][locale] = fingerprint
    }

    public mutating func remove(catalog: String, key: String, locale: String? = nil) {
        if let locale {
            entries[catalog]?[key]?[locale] = nil
            if entries[catalog]?[key]?.isEmpty == true { entries[catalog]?[key] = nil }
        } else {
            entries[catalog]?[key] = nil
        }
    }

    /// Drops fingerprints for keys or locales that no longer exist.
    public mutating func prune(catalog: String, existing: (String, String) -> Bool) {
        guard let keys = entries[catalog] else { return }
        for (key, locales) in keys {
            for locale in locales.keys where !existing(key, locale) {
                remove(catalog: catalog, key: key, locale: locale)
            }
        }
        if entries[catalog]?.isEmpty == true { entries[catalog] = nil }
    }

    public func save() throws {
        var catalogs = JSONObject()
        for (catalog, keys) in entries {
            var keyObject = JSONObject()
            for (key, locales) in keys {
                keyObject[key] = .object(JSONObject(locales.map { JSONObject.Member(key: $0.key, value: .string($0.value)) }))
            }
            catalogs[catalog] = .object(keyObject)
        }
        let root = JSONValue.object(JSONObject(["catalogs": .object(catalogs), "version": .number("1")]))
        try AtomicFile.write(XcodeJSONWriter.string(root) + "\n", to: url)
    }

    /// Fingerprint of a key's source-language content (all variation values, not the comment).
    public static func sourceFingerprint(_ node: LocalizationNode) -> String {
        let material = node.leaves.map { "\($0.path.joined(separator: "/"))=\($0.unit.value)" }.joined(separator: "\u{1E}")
        return Hashing.shortHash(material)
    }
}
