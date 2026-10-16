import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A chat-completion backend. Implementations must stay on the local machine unless
/// the user opts into remote endpoints.
public protocol ChatModel: Sendable {
    /// Human-readable model identifier recorded in reports.
    var name: String { get }
    func complete(system: String, user: String) async throws -> String
}

/// Test double: answers from a closure.
public struct ScriptedChatModel: ChatModel {
    public let name: String
    private let handler: @Sendable (String, String) async throws -> String

    public init(name: String = "scripted", handler: @escaping @Sendable (_ system: String, _ user: String) async throws -> String) {
        self.name = name
        self.handler = handler
    }

    public func complete(system: String, user: String) async throws -> String {
        try await handler(system, user)
    }
}

public enum HTTP {
    static func postJSON(_ url: URL, body: [String: Any], timeout: TimeInterval) async throws -> (Int, Any?, String) {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if url.path.hasPrefix("/v1/"), let key = ProcessInfo.processInfo.environment["L10N_AGENT_API_KEY"], !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session(timeout).data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let text = String(data: data, encoding: .utf8) ?? ""
        return (status, try? JSONSerialization.jsonObject(with: data), text)
    }

    static func getJSON(_ url: URL, timeout: TimeInterval) async throws -> Any? {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        if url.path.hasPrefix("/v1/"), let key = ProcessInfo.processInfo.environment["L10N_AGENT_API_KEY"], !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await session(timeout).data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private static func session(_ timeout: TimeInterval) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        return URLSession(configuration: configuration)
    }

    public static func isLocal(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]" || host.hasSuffix(".localhost")
    }
}

/// Ollama native API (`/api/chat`). Disables thinking and parses JSON from plain text,
/// because many local models (for example MLX builds) reject structured output.
public struct OllamaChatModel: ChatModel {
    public let name: String
    let baseURL: URL
    let temperature: Double
    let timeout: TimeInterval

    public init(baseURL: URL, model: String, temperature: Double, timeout: TimeInterval) {
        self.baseURL = baseURL
        self.name = model
        self.temperature = temperature
        self.timeout = timeout
    }

    public struct InstalledModel: Sendable, Equatable {
        public var name: String
        public var isRemote: Bool
    }

    public static func installedModels(baseURL: URL, timeout: TimeInterval = 5) async throws -> [InstalledModel] {
        guard let json = try await HTTP.getJSON(baseURL.appendingPathComponent("api/tags"), timeout: timeout) as? [String: Any],
              let models = json["models"] as? [[String: Any]]
        else { throw L10nError.translator("Ollama is not reachable at \(baseURL.absoluteString). Start it with `ollama serve`.") }
        return models.compactMap { model in
            guard let name = model["name"] as? String else { return nil }
            let remote = model["remote_host"] != nil || isCloudName(name)
            return InstalledModel(name: name, isRemote: remote)
        }
    }

    /// Ollama names cloud models `name:cloud` or `name-cloud`.
    public static func isCloudName(_ name: String) -> Bool {
        name.hasSuffix(":cloud") || name.hasSuffix("-cloud")
    }

    public func complete(system: String, user: String) async throws -> String {
        var body: [String: Any] = [
            "model": name,
            "stream": false,
            "think": false,
            "options": ["temperature": temperature],
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ]
        var (status, json, text) = try await HTTP.postJSON(baseURL.appendingPathComponent("api/chat"), body: body, timeout: timeout)
        if status == 400, text.lowercased().contains("think") {
            body["think"] = nil
            (status, json, text) = try await HTTP.postJSON(baseURL.appendingPathComponent("api/chat"), body: body, timeout: timeout)
        }
        guard (200..<300).contains(status) else {
            throw L10nError.translator("Ollama returned HTTP \(status): \(text.prefix(300))")
        }
        guard let object = json as? [String: Any], let message = object["message"] as? [String: Any],
              let content = message["content"] as? String
        else { throw L10nError.translator("Ollama returned an unexpected response") }
        return content
    }
}

/// Any OpenAI-compatible server (LM Studio, llama.cpp server, vLLM): `/v1/chat/completions`.
public struct OpenAICompatibleChatModel: ChatModel {
    public let name: String
    let baseURL: URL
    let temperature: Double
    let timeout: TimeInterval

    public init(baseURL: URL, model: String, temperature: Double, timeout: TimeInterval) {
        self.baseURL = baseURL
        self.name = model
        self.temperature = temperature
        self.timeout = timeout
    }

    public static func availableModels(baseURL: URL, timeout: TimeInterval = 5) async throws -> [String] {
        guard let json = try await HTTP.getJSON(baseURL.appendingPathComponent("v1/models"), timeout: timeout) as? [String: Any],
              let models = json["data"] as? [[String: Any]]
        else { throw L10nError.translator("No OpenAI-compatible server is reachable at \(baseURL.absoluteString).") }
        return models.compactMap { $0["id"] as? String }
    }

    public func complete(system: String, user: String) async throws -> String {
        let body: [String: Any] = [
            "model": name,
            "temperature": temperature,
            "stream": false,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ]
        let (status, json, text) = try await HTTP.postJSON(baseURL.appendingPathComponent("v1/chat/completions"), body: body, timeout: timeout)
        guard (200..<300).contains(status) else {
            throw L10nError.translator("Server returned HTTP \(status): \(text.prefix(300))")
        }
        guard let object = json as? [String: Any], let choices = object["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any], let content = message["content"] as? String
        else { throw L10nError.translator("Server returned an unexpected response") }
        return content
    }
}

public enum ChatModelFactory {
    /// Whether strings sent to this translator leave the machine: a non-localhost endpoint
    /// or an Ollama cloud model.
    public static func isRemote(_ config: TranslatorConfig, model: String) async -> Bool {
        guard let baseURL = URL(string: config.baseURL), HTTP.isLocal(baseURL) else { return true }
        if OllamaChatModel.isCloudName(model) { return true }
        guard config.provider == .ollama, let installed = try? await OllamaChatModel.installedModels(baseURL: baseURL) else { return false }
        return installed.first { $0.name == model }?.isRemote ?? false
    }

    /// Builds the configured backend, refusing remote endpoints and cloud models unless allowed.
    public static func make(_ config: TranslatorConfig, modelOverride: String? = nil) async throws -> ChatModel {
        guard let baseURL = URL(string: config.baseURL), baseURL.scheme != nil else {
            throw L10nError.config("translator.baseURL is not a valid URL: \(config.baseURL)")
        }
        // A cloned repository's config alone must not be able to send strings (or the
        // user's API key) off the machine: remote use also needs a user-level opt-in.
        let remoteAllowed = config.allowRemote && ProcessInfo.processInfo.environment["L10N_AGENT_ALLOW_REMOTE"] == "1"
        if !remoteAllowed, !HTTP.isLocal(baseURL) {
            throw L10nError.config("translator.baseURL \(config.baseURL) is not on this machine. To send strings to it, set translator.allowRemote: true and export L10N_AGENT_ALLOW_REMOTE=1.")
        }
        let requested = modelOverride ?? config.model
        switch config.provider {
        case .ollama:
            let installed = try await OllamaChatModel.installedModels(baseURL: baseURL)
            let model: String
            if let requested {
                if let match = installed.first(where: { $0.name == requested || $0.name == requested + ":latest" }) {
                    if match.isRemote, !remoteAllowed {
                        throw L10nError.config("Ollama model \(match.name) runs in the cloud. Choose a local model, or set translator.allowRemote: true and export L10N_AGENT_ALLOW_REMOTE=1.")
                    }
                    model = match.name
                } else {
                    throw L10nError.config("Ollama model \(requested) is not installed. Run `ollama pull \(requested)`.")
                }
            } else {
                guard let local = installed.first(where: { !$0.isRemote }) else {
                    throw L10nError.config("No local Ollama model is installed. Run `ollama pull <model>` and set translator.model.")
                }
                model = local.name
            }
            return OllamaChatModel(baseURL: baseURL, model: model, temperature: config.temperature, timeout: config.timeoutSeconds)
        case .openai:
            let model: String
            if let requested {
                model = requested
            } else {
                guard let first = try await OpenAICompatibleChatModel.availableModels(baseURL: baseURL).first else {
                    throw L10nError.config("The server at \(config.baseURL) lists no models; set translator.model.")
                }
                model = first
            }
            return OpenAICompatibleChatModel(baseURL: baseURL, model: model, temperature: config.temperature, timeout: config.timeoutSeconds)
        }
    }
}
