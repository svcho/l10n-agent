import Foundation

/// A String Catalog (`.xcstrings`) backed by an order-preserving JSON tree.
/// Only the fields this tool edits are touched; everything else round-trips unchanged.
public struct StringCatalog: Sendable {
    public let url: URL
    public var root: JSONObject

    public init(url: URL, root: JSONObject) {
        self.url = url
        self.root = root
    }

    public static func load(_ url: URL, fallbackSourceLanguage: String = "en") throws -> StringCatalog {
        let data = try Data(contentsOf: url)
        if data.isEmpty || data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) {
            return StringCatalog.empty(url: url, sourceLanguage: fallbackSourceLanguage)
        }
        let value: JSONValue
        do {
            value = try JSONParser.parse(data)
        } catch let error as JSONParseError {
            throw L10nError.catalogParse(path: url.path, message: error.description)
        }
        guard case .object(let root) = value else {
            throw L10nError.catalogParse(path: url.path, message: "Top-level value must be an object")
        }
        if let strings = root["strings"], strings.objectValue == nil {
            throw L10nError.catalogParse(path: url.path, message: "\"strings\" must be an object")
        }
        return StringCatalog(url: url, root: root)
    }

    public static func empty(url: URL, sourceLanguage: String, version: String = "1.1") -> StringCatalog {
        StringCatalog(url: url, root: JSONObject([
            "sourceLanguage": .string(sourceLanguage),
            "strings": .object(JSONObject()),
            "version": .string(version),
        ]))
    }

    /// Table name used by `String(localized:table:)`; the file name without extension.
    public var tableName: String { url.deletingPathExtension().lastPathComponent }

    public var sourceLanguage: String {
        get { root["sourceLanguage"]?.stringValue ?? "en" }
        set { root["sourceLanguage"] = .string(newValue) }
    }

    public var version: String {
        get { root["version"]?.stringValue ?? "1.0" }
        set { root["version"] = .string(newValue) }
    }

    private var strings: JSONObject {
        get { root["strings"]?.objectValue ?? JSONObject() }
        set { root["strings"] = .object(newValue) }
    }

    /// Keys in Xcode's on-disk order.
    public var keys: [String] {
        strings.keys.sorted(by: XcodeJSONWriter.codePointLess)
    }

    public func contains(_ key: String) -> Bool {
        strings.contains(key)
    }

    public func entry(_ key: String) -> CatalogEntry? {
        strings[key]?.objectValue.map(CatalogEntry.init(raw:))
    }

    public mutating func setEntry(_ key: String, _ entry: CatalogEntry?) {
        var strings = self.strings
        strings[key] = entry.map { .object($0.raw) }
        self.strings = strings
    }

    public var entries: [(key: String, entry: CatalogEntry)] {
        keys.compactMap { key in entry(key).map { (key, $0) } }
    }

    /// All locales that appear anywhere in the catalog.
    public var locales: Set<String> {
        var result: Set<String> = [sourceLanguage]
        for (_, entry) in entries {
            result.formUnion(entry.localizationLocales)
        }
        return result
    }

    public func serialized() -> Data {
        XcodeJSONWriter.data(.object(root))
    }

    public func write() throws {
        try AtomicFile.write(serialized(), to: url)
    }
}

public struct CatalogEntry: Equatable, Sendable {
    public var raw: JSONObject

    public init(raw: JSONObject = JSONObject()) {
        self.raw = raw
    }

    public var comment: String? {
        get { raw["comment"]?.stringValue }
        set { raw["comment"] = newValue.map(JSONValue.string) }
    }

    public var extractionState: String? {
        get { raw["extractionState"]?.stringValue }
        set { raw["extractionState"] = newValue.map(JSONValue.string) }
    }

    public var isManual: Bool { extractionState == "manual" }
    public var isStale: Bool { extractionState == "stale" }

    public var shouldTranslate: Bool {
        get { raw["shouldTranslate"]?.boolValue ?? true }
        set { raw["shouldTranslate"] = newValue ? nil : .bool(false) }
    }

    private var localizations: JSONObject {
        get { raw["localizations"]?.objectValue ?? JSONObject() }
        set { raw["localizations"] = newValue.isEmpty ? nil : .object(newValue) }
    }

    public var localizationLocales: [String] {
        localizations.keys.sorted(by: XcodeJSONWriter.codePointLess)
    }

    public func localization(_ locale: String) -> LocalizationNode? {
        localizations[locale]?.objectValue.map(LocalizationNode.init(raw:))
    }

    public mutating func setLocalization(_ locale: String, _ node: LocalizationNode?) {
        var localizations = self.localizations
        localizations[locale] = node.map { .object($0.raw) }
        self.localizations = localizations
    }

    /// The source-language value. Auto-extracted keys without a source localization
    /// use the key itself as their source text.
    public func sourceNode(key: String, sourceLanguage: String) -> LocalizationNode {
        localization(sourceLanguage) ?? LocalizationNode(unit: StringUnit(state: "translated", value: key))
    }
}

public struct StringUnit: Equatable, Sendable, Codable {
    public var state: String
    public var value: String

    public init(state: String, value: String) {
        self.state = state
        self.value = value
    }

    public enum State {
        public static let translated = "translated"
        public static let needsReview = "needs_review"
        public static let new = "new"
        public static let stale = "stale"
    }

    /// Approved by a human. The tool never overwrites these.
    public var isApproved: Bool { state == State.translated }
    public var isMissing: Bool { state == State.new || value.isEmpty }
}

/// A localization or variation case: an object holding `stringUnit`, `variations`
/// and/or `substitutions`.
public struct LocalizationNode: Equatable, Sendable {
    public var raw: JSONObject

    public init(raw: JSONObject) {
        self.raw = raw
    }

    public init(unit: StringUnit) {
        self.raw = JSONObject()
        self.stringUnit = unit
    }

    public var stringUnit: StringUnit? {
        get {
            guard let unit = raw["stringUnit"]?.objectValue else { return nil }
            return StringUnit(
                state: unit["state"]?.stringValue ?? StringUnit.State.new,
                value: unit["value"]?.stringValue ?? ""
            )
        }
        set {
            guard let newValue else {
                raw["stringUnit"] = nil
                return
            }
            var unit = raw["stringUnit"]?.objectValue ?? JSONObject()
            unit["state"] = .string(newValue.state)
            unit["value"] = .string(newValue.value)
            raw["stringUnit"] = .object(unit)
        }
    }

    /// `variations` grouped by kind (`plural`, `device`, …) then by case.
    public var variations: [String: [String: LocalizationNode]] {
        guard let variations = raw["variations"]?.objectValue else { return [:] }
        var result: [String: [String: LocalizationNode]] = [:]
        for kind in variations.members {
            guard let cases = kind.value.objectValue else { continue }
            var caseNodes: [String: LocalizationNode] = [:]
            for member in cases.members {
                if let object = member.value.objectValue {
                    caseNodes[member.key] = LocalizationNode(raw: object)
                }
            }
            result[kind.key] = caseNodes
        }
        return result
    }

    public var substitutions: [String: Substitution] {
        guard let substitutions = raw["substitutions"]?.objectValue else { return [:] }
        var result: [String: Substitution] = [:]
        for member in substitutions.members {
            if let object = member.value.objectValue {
                result[member.key] = Substitution(raw: object)
            }
        }
        return result
    }

    /// Every string unit reachable from this node with its JSON path relative to the node.
    public var leaves: [Leaf] {
        var result: [Leaf] = []
        collectLeaves(path: [], into: &result)
        return result
    }

    public struct Leaf: Equatable, Sendable {
        public var path: [String]
        public var unit: StringUnit

        /// A readable form such as `plural.one` or `device.iphone/plural.other`.
        public var label: String {
            guard !path.isEmpty else { return "" }
            var parts: [String] = []
            var index = 0
            while index < path.count {
                if path[index] == "variations", index + 2 < path.count {
                    parts.append("\(path[index + 1]).\(path[index + 2])")
                    index += 3
                } else if path[index] == "substitutions", index + 1 < path.count {
                    parts.append("%#@\(path[index + 1])@")
                    index += 2
                } else {
                    parts.append(path[index])
                    index += 1
                }
            }
            return parts.joined(separator: "/")
        }
    }

    private func collectLeaves(path: [String], into result: inout [Leaf]) {
        if let unit = stringUnit {
            result.append(Leaf(path: path, unit: unit))
        }
        for (kind, cases) in variations.sorted(by: { $0.key < $1.key }) {
            for (caseName, node) in cases.sorted(by: { $0.key < $1.key }) {
                node.collectLeaves(path: path + ["variations", kind, caseName], into: &result)
            }
        }
        for (name, substitution) in substitutions.sorted(by: { $0.key < $1.key }) {
            for (kind, cases) in substitution.variations.sorted(by: { $0.key < $1.key }) {
                for (caseName, node) in cases.sorted(by: { $0.key < $1.key }) {
                    node.collectLeaves(path: path + ["substitutions", name, "variations", kind, caseName], into: &result)
                }
            }
        }
    }

    public func value(at path: [String]) -> JSONValue? {
        var current: JSONValue = .object(raw)
        for component in path {
            guard let next = current[component] else { return nil }
            current = next
        }
        return current
    }

    /// Sets a string unit at a leaf path, creating intermediate objects.
    public mutating func setUnit(_ unit: StringUnit, at path: [String]) {
        var node = LocalizationNode(raw: Self.object(at: path, in: raw) ?? JSONObject())
        node.stringUnit = unit
        raw = Self.setting(.object(node.raw), at: path, in: raw)
    }

    /// Copies a non-string-unit field (for example a substitution's `argNum` and
    /// `formatSpecifier`) from another node so translated substitutions stay valid.
    public mutating func setValue(_ value: JSONValue, at path: [String]) {
        raw = Self.setting(value, at: path, in: raw)
    }

    private static func object(at path: [String], in object: JSONObject) -> JSONObject? {
        var current = object
        for component in path {
            guard let next = current[component]?.objectValue else { return nil }
            current = next
        }
        return current
    }

    private static func setting(_ value: JSONValue, at path: [String], in object: JSONObject) -> JSONObject {
        guard let first = path.first else {
            return value.objectValue ?? object
        }
        var copy = object
        if path.count == 1 {
            copy[first] = value
        } else {
            let child = copy[first]?.objectValue ?? JSONObject()
            copy[first] = .object(setting(value, at: Array(path.dropFirst()), in: child))
        }
        return copy
    }
}

public struct Substitution: Equatable, Sendable {
    public var raw: JSONObject

    public var argNum: Int? { raw["argNum"]?.intValue }
    public var formatSpecifier: String? { raw["formatSpecifier"]?.stringValue }

    public var variations: [String: [String: LocalizationNode]] {
        LocalizationNode(raw: raw).variations
    }
}
