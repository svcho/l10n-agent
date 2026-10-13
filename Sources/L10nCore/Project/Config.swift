import Foundation
import Yams

public enum Severity: String, Codable, Sendable, Comparable, CaseIterable {
    case off
    case info
    case warning
    case error

    private var rank: Int {
        switch self {
        case .off: return 0
        case .info: return 1
        case .warning: return 2
        case .error: return 3
        }
    }

    public static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rank < rhs.rank }
}

public enum CodeStyle: String, Codable, Sendable {
    /// Use generated symbols when the Xcode project enables them, otherwise literals.
    case auto
    /// `Text(.welcomeTitle)`, `String(localized: .welcomeTitle)`.
    case symbols
    /// `String(localized: "welcome.title", defaultValue: "Welcome", comment: "…")`.
    case literal
}

public enum KeyStyle: String, Codable, Sendable, CaseIterable {
    /// `settings.darkMode.title`
    case dottedCamel = "dotted.camel"
    /// `settings.darkmode.title`
    case dottedLower = "dotted.lower"
    /// `settings.dark_mode.title`
    case dottedSnake = "dotted.snake"

    var segmentPattern: String {
        switch self {
        case .dottedCamel: return "[a-z][a-zA-Z0-9]*"
        case .dottedLower: return "[a-z][a-z0-9]*"
        case .dottedSnake: return "[a-z][a-z0-9_]*"
        }
    }
}

public struct KeyPolicy: Codable, Sendable, Equatable {
    public var style: KeyStyle
    public var minDepth: Int
    public var maxDepth: Int
    public var scopes: [String]
    public var forbiddenPrefixes: [String]

    public init(style: KeyStyle = .dottedCamel, minDepth: Int = 2, maxDepth: Int = 4, scopes: [String] = [], forbiddenPrefixes: [String] = ["tmp.", "debug.", "test."]) {
        self.style = style
        self.minDepth = minDepth
        self.maxDepth = maxDepth
        self.scopes = scopes
        self.forbiddenPrefixes = forbiddenPrefixes
    }

    public init(from decoder: Decoder) throws {
        let defaults = KeyPolicy()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        style = try container.decodeIfPresent(KeyStyle.self, forKey: .style) ?? defaults.style
        minDepth = try container.decodeIfPresent(Int.self, forKey: .minDepth) ?? defaults.minDepth
        maxDepth = try container.decodeIfPresent(Int.self, forKey: .maxDepth) ?? defaults.maxDepth
        scopes = try container.decodeIfPresent([String].self, forKey: .scopes) ?? defaults.scopes
        forbiddenPrefixes = try container.decodeIfPresent([String].self, forKey: .forbiddenPrefixes) ?? defaults.forbiddenPrefixes
    }

    /// Returns a list of human-readable violations; empty when the key is valid.
    public func violations(for key: String) -> [String] {
        var problems: [String] = []
        let segments = key.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        let regex = try! NSRegularExpression(pattern: "^\(style.segmentPattern)$")
        if segments.contains(where: { segment in
            regex.firstMatch(in: segment, range: NSRange(segment.startIndex..., in: segment)) == nil
        }) {
            problems.append("segments must match \(style.rawValue) (\(style.segmentPattern))")
        }
        if segments.count < minDepth { problems.append("needs at least \(minDepth) segments") }
        if segments.count > maxDepth { problems.append("has more than \(maxDepth) segments") }
        if !scopes.isEmpty, let first = segments.first, !scopes.contains(first) {
            problems.append("first segment must be one of: \(scopes.joined(separator: ", "))")
        }
        if let prefix = forbiddenPrefixes.first(where: { key.hasPrefix($0) }) {
            problems.append("uses forbidden prefix \(prefix)")
        }
        return problems
    }

    /// A key looks semantic (rather than English text used as a key) when it has no
    /// whitespace and at least one dot.
    public static func looksSemantic(_ key: String) -> Bool {
        key.contains(".") && !key.contains(where: \.isWhitespace) && !key.isEmpty
    }
}

public struct TranslatorConfig: Codable, Sendable, Equatable {
    public enum Provider: String, Codable, Sendable {
        /// Ollama native API (`/api/chat`).
        case ollama
        /// Any OpenAI-compatible server such as LM Studio or llama.cpp (`/v1/chat/completions`).
        case openai
    }

    public var provider: Provider
    public var baseURL: String
    public var model: String?
    public var batchSize: Int
    public var maxRetries: Int
    public var timeoutSeconds: Double
    public var temperature: Double
    /// Allow non-localhost endpoints and Ollama `:cloud` models. Off by default so
    /// source strings never leave the machine by accident.
    public var allowRemote: Bool

    public init(provider: Provider = .ollama, baseURL: String? = nil, model: String? = nil, batchSize: Int = 20, maxRetries: Int = 2, timeoutSeconds: Double = 600, temperature: Double = 0.2, allowRemote: Bool = false) {
        self.provider = provider
        self.baseURL = baseURL ?? (provider == .ollama ? "http://localhost:11434" : "http://localhost:1234")
        self.model = model
        self.batchSize = batchSize
        self.maxRetries = maxRetries
        self.timeoutSeconds = timeoutSeconds
        self.temperature = temperature
        self.allowRemote = allowRemote
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let provider = try container.decodeIfPresent(Provider.self, forKey: .provider) ?? .ollama
        self.init(
            provider: provider,
            baseURL: try container.decodeIfPresent(String.self, forKey: .baseURL),
            model: try container.decodeIfPresent(String.self, forKey: .model),
            batchSize: try container.decodeIfPresent(Int.self, forKey: .batchSize) ?? 20,
            maxRetries: try container.decodeIfPresent(Int.self, forKey: .maxRetries) ?? 2,
            timeoutSeconds: try container.decodeIfPresent(Double.self, forKey: .timeoutSeconds) ?? 600,
            temperature: try container.decodeIfPresent(Double.self, forKey: .temperature) ?? 0.2,
            allowRemote: try container.decodeIfPresent(Bool.self, forKey: .allowRemote) ?? false
        )
    }
}

public struct UserFacingAPIs: Codable, Sendable, Equatable {
    /// Extra functions or initializers whose arguments are user-facing text,
    /// e.g. `{ name: "PrimaryButton", labels: ["_", "title"] }`.
    public struct Function: Codable, Sendable, Equatable {
        public var name: String
        public var labels: [String]
    }

    public var functions: [Function]
    /// Extra property names whose assigned string is user-facing, e.g. `headline`.
    public var properties: [String]

    public init(functions: [Function] = [], properties: [String] = []) {
        self.functions = functions
        self.properties = properties
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        functions = try container.decodeIfPresent([Function].self, forKey: .functions) ?? []
        properties = try container.decodeIfPresent([String].self, forKey: .properties) ?? []
    }
}

public struct L10nConfig: Codable, Sendable, Equatable {
    public static let fileName = ".l10n-agent.yml"

    public var sourceLanguage: String?
    public var locales: [String]?
    public var catalog: String?
    public var include: [String]
    public var exclude: [String]
    public var codeStyle: CodeStyle
    /// Report English-text keys (`Text("Welcome")`) and propose semantic keys.
    public var semanticKeys: Bool
    public var keys: KeyPolicy
    public var rules: [String: Severity]
    /// term → locale → required translation. Use the term itself to keep it untranslated.
    public var glossary: [String: [String: String]]
    public var translator: TranslatorConfig
    public var userFacing: UserFacingAPIs

    public init() {
        sourceLanguage = nil
        locales = nil
        catalog = nil
        include = []
        exclude = []
        codeStyle = .auto
        semanticKeys = true
        keys = KeyPolicy()
        rules = [:]
        glossary = [:]
        translator = TranslatorConfig()
        userFacing = UserFacingAPIs()
    }

    public init(from decoder: Decoder) throws {
        let defaults = L10nConfig()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let unknown = try decoder.container(keyedBy: AnyKey.self).allKeys.map(\.stringValue)
            .filter { CodingKeys(stringValue: $0) == nil }
        if !unknown.isEmpty {
            throw L10nError.config("Unknown key(s) in \(Self.fileName): \(unknown.sorted().joined(separator: ", "))")
        }
        sourceLanguage = try container.decodeIfPresent(String.self, forKey: .sourceLanguage)
        locales = try container.decodeIfPresent([String].self, forKey: .locales)
        catalog = try container.decodeIfPresent(String.self, forKey: .catalog)
        include = try container.decodeIfPresent([String].self, forKey: .include) ?? defaults.include
        exclude = try container.decodeIfPresent([String].self, forKey: .exclude) ?? defaults.exclude
        codeStyle = try container.decodeIfPresent(CodeStyle.self, forKey: .codeStyle) ?? defaults.codeStyle
        semanticKeys = try container.decodeIfPresent(Bool.self, forKey: .semanticKeys) ?? defaults.semanticKeys
        keys = try container.decodeIfPresent(KeyPolicy.self, forKey: .keys) ?? defaults.keys
        rules = try container.decodeIfPresent([String: Severity].self, forKey: .rules) ?? defaults.rules
        glossary = try container.decodeIfPresent([String: [String: String]].self, forKey: .glossary) ?? defaults.glossary
        translator = try container.decodeIfPresent(TranslatorConfig.self, forKey: .translator) ?? defaults.translator
        userFacing = try container.decodeIfPresent(UserFacingAPIs.self, forKey: .userFacing) ?? defaults.userFacing
    }

    private struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    public static func load(root: URL) throws -> L10nConfig {
        let url = root.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return L10nConfig() }
        let text = try String(contentsOf: url, encoding: .utf8)
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return L10nConfig() }
        do {
            return try YAMLDecoder().decode(L10nConfig.self, from: text)
        } catch let error as L10nError {
            throw error
        } catch {
            throw L10nError.config("\(fileName): \(error)")
        }
    }
}
