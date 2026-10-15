import Foundation
import L10nCore
import MCP

/// MCP server exposing l10n-agent to coding agents over stdio.
///
/// Every tool works inside the project root the server was started with. Mutating tools
/// take the project lock and never overwrite approved translations.
public struct L10nMCPServer: Sendable {
    public let root: URL
    public let version: String
    /// Mutating tools run one at a time; clients may send calls concurrently.
    private let mutations = AsyncLock()
    static let mutatingTools: Set<String> = ["l10n_apply_fixes", "l10n_translate", "l10n_set_translations", "l10n_add_keys", "l10n_accept"]

    public init(root: URL, version: String) {
        self.root = root.standardizedFileURL
        self.version = version
    }

    static let instructions = """
    l10n-agent manages localization of an Xcode project whose source of truth is its String Catalogs (.xcstrings).
    Workflow: l10n_lint → l10n_plan_fixes → (optionally edit keys/comments/specifiers in the plan) → l10n_apply_fixes → l10n_translate (local LLM) or l10n_set_translations (your own translations) → l10n_lint again.
    Translations written by tools get state needs_review; humans approve them in Xcode. Approved translations are never overwritten.
    """

    public func run() async throws {
        let server = makeServer()
        await register(on: server)
        try await server.start(transport: StdioTransport())
        await server.waitUntilCompleted()
    }

    public func makeServer() -> Server {
        Server(
            name: "l10n-agent",
            version: version,
            instructions: Self.instructions,
            capabilities: .init(tools: .init(listChanged: false))
        )
    }

    public func register(on server: Server) async {
        let tools = Self.tools
        await server.withMethodHandler(ListTools.self) { _ in
            .init(tools: tools)
        }
        await server.withMethodHandler(CallTool.self) { params in
            await self.call(name: params.name, arguments: params.arguments ?? [:])
        }
    }

    // MARK: Tool definitions

    static func schema(_ properties: [String: Value], required: [String] = []) -> Value {
        var object: [String: Value] = ["type": "object", "properties": .object(properties), "additionalProperties": false]
        if !required.isEmpty { object["required"] = .array(required.map(Value.string)) }
        return .object(object)
    }

    static let stringArray: Value = ["type": "array", "items": ["type": "string"]]

    static let tools: [Tool] = [
        Tool(
            name: "l10n_lint",
            description: "Find unlocalized UI strings in Swift code and problems in String Catalogs (missing/stale/needs-review translations, format specifier mismatches, key style, symbol collisions). Returns findings with stable ids, file, line, rule and whether they are fixable.",
            inputSchema: schema([
                "paths": .object(["type": "array", "items": ["type": "string"], "description": "Swift files or folders to scan (relative to the project root). Default: all."]),
                "rules": .object(["type": "array", "items": ["type": "string"], "description": "Rule IDs or names, e.g. L10N001. Default: all enabled."]),
                "scope": .object(["type": "string", "enum": ["all", "code", "catalogs"], "description": "What to check. Default: all."]),
            ]),
            annotations: .init(readOnlyHint: true, idempotentHint: true, openWorldHint: false)
        ),
        Tool(
            name: "l10n_status",
            description: "Translation coverage per catalog and locale: approved, needs review, missing, stale.",
            inputSchema: schema([:]),
            annotations: .init(readOnlyHint: true, idempotentHint: true, openWorldHint: false)
        ),
        Tool(
            name: "l10n_plan_fixes",
            description: "Plan fixes for code findings (L10N001 unlocalized, L10N002 text-as-key, L10N003 concatenation): proposes a semantic key, translator comment and the code replacement for each site. Nothing is written. You may edit key, comment, placeholders[].specifier and status (ready/needsReview/skipped) before passing the plan to l10n_apply_fixes.",
            inputSchema: schema([
                "paths": stringArray,
                "rules": stringArray,
                "finding_ids": .object(["type": "array", "items": ["type": "string"], "description": "Only these finding ids from l10n_lint."]),
                "llm_keys": .object(["type": "boolean", "description": "Ask the configured local LLM to name keys and write comments. Default false (you can name keys yourself)."]),
            ]),
            annotations: .init(readOnlyHint: true, openWorldHint: false)
        ),
        Tool(
            name: "l10n_apply_fixes",
            description: "Apply a plan from l10n_plan_fixes: adds manual keys (with comments) to the catalog and rewrites the Swift code to use them. Refuses if files changed since planning. Items with status needsReview are applied only with include_review.",
            inputSchema: schema([
                "plan": .object(["type": "object", "description": "The plan object returned by l10n_plan_fixes (optionally edited)."]),
                "include_review": .object(["type": "boolean", "description": "Also apply needsReview items."]),
            ], required: ["plan"]),
            annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false)
        ),
        Tool(
            name: "l10n_translate",
            description: "Translate missing and stale strings with the configured local LLM (Ollama/LM Studio). Writes state needs_review; never touches approved translations. Use dry_run to see the work list first. Can take minutes.",
            inputSchema: schema([
                "locales": stringArray,
                "keys": stringArray,
                "dry_run": .object(["type": "boolean"]),
            ]),
            annotations: .init(readOnlyHint: false, destructiveHint: false, openWorldHint: false)
        ),
        Tool(
            name: "l10n_set_translations",
            description: "Write translations you produced yourself. Each item: key, locale, and value (with the same format specifiers as the source, e.g. %@, %lld, %1$@) or forms (CLDR plural category → text) for plural keys. Validated for specifier parity; written as needs_review. Set catalog when the key exists in more than one catalog.",
            inputSchema: schema([
                "translations": .object([
                    "type": "array",
                    "items": schema([
                        "key": ["type": "string"],
                        "locale": ["type": "string"],
                        "value": ["type": "string"],
                        "forms": ["type": "object", "additionalProperties": ["type": "string"]],
                        "catalog": ["type": "string"],
                    ], required: ["key", "locale"]),
                ]),
            ], required: ["translations"]),
            annotations: .init(readOnlyHint: false, destructiveHint: false, openWorldHint: false)
        ),
        Tool(
            name: "l10n_add_keys",
            description: "Add manual keys to a String Catalog before writing code that uses them. Returns the generated Swift symbol for each key when symbol generation is enabled (use Text(.symbol) / String(localized: .symbol)).",
            inputSchema: schema([
                "keys": .object([
                    "type": "array",
                    "items": schema([
                        "key": ["type": "string"],
                        "value": ["type": "string", "description": "Source text with format specifiers, e.g. \"Hello %@\"."],
                        "comment": ["type": "string"],
                        "catalog": ["type": "string"],
                    ], required: ["key", "value"]),
                ]),
            ], required: ["keys"]),
            annotations: .init(readOnlyHint: false, destructiveHint: false, openWorldHint: false)
        ),
        Tool(
            name: "l10n_accept",
            description: "Mark translations as up to date with the current source text (clears L10N103 stale findings) after they were reviewed.",
            inputSchema: schema(["keys": stringArray, "locales": stringArray]),
            annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false)
        ),
    ]

    // MARK: Dispatch

    struct LintInput: Decodable { var paths: [String]?; var rules: [String]?; var scope: String? }
    struct PlanInput: Decodable { var paths: [String]?; var rules: [String]?; var finding_ids: [String]?; var llm_keys: Bool? }
    struct ApplyInput: Decodable { var plan: FixPlan; var include_review: Bool? }
    struct TranslateInput: Decodable { var locales: [String]?; var keys: [String]?; var dry_run: Bool? }
    struct SetTranslationsInput: Decodable { var translations: [ProvidedTranslation] }
    struct AddKeysInput: Decodable { var keys: [NewKey] }
    struct AcceptInput: Decodable { var keys: [String]?; var locales: [String]? }

    func call(name: String, arguments: [String: Value]) async -> CallTool.Result {
        guard Self.mutatingTools.contains(name) else {
            return await perform(name: name, arguments: arguments)
        }
        await mutations.lock()
        let result = await perform(name: name, arguments: arguments)
        await mutations.unlock()
        return result
    }

    func perform(name: String, arguments: [String: Value]) async -> CallTool.Result {
        do {
            let project = try Project.discover(root: root)
            switch name {
            case "l10n_lint":
                let input = try decode(LintInput.self, arguments)
                let scope = input.scope ?? "all"
                try input.paths?.forEach { _ = try PathUtil.resolveInside($0, root: root) }
                let report = try Linter(project: project).run(LintOptions(
                    rules: input.rules.map(Set.init),
                    files: input.paths,
                    code: scope != "catalogs",
                    catalogs: scope != "code"
                ))
                return success(report)
            case "l10n_status":
                return success(try StatusCommand.run(project: project))
            case "l10n_plan_fixes":
                let input = try decode(PlanInput.self, arguments)
                try input.paths?.forEach { _ = try PathUtil.resolveInside($0, root: root) }
                var plan = try Fixer(project: project).plan(rules: input.rules.map(Set.init), files: input.paths, findingIDs: input.finding_ids.map(Set.init))
                if input.llm_keys == true, !plan.items.isEmpty {
                    plan = try await LLMKeyNamer(project: project, model: try await ChatModelFactory.make(project.config.translator)).improve(plan)
                }
                return success(plan)
            case "l10n_apply_fixes":
                let input = try decode(ApplyInput.self, arguments)
                for item in input.plan.items {
                    _ = try PathUtil.resolveInside(item.file, root: root)
                    _ = try PathUtil.resolveInside(item.catalog, root: root)
                }
                return success(try Fixer(project: project).apply(input.plan, includeReview: input.include_review ?? false))
            case "l10n_translate":
                let input = try decode(TranslateInput.self, arguments)
                let dryRun = input.dry_run ?? false
                let model = dryRun ? nil : try await ChatModelFactory.make(project.config.translator)
                let report = try await TranslationEngine(project: project).run(TranslateOptions(locales: input.locales, keys: input.keys, dryRun: dryRun), model: model)
                return success(report)
            case "l10n_set_translations":
                let input = try decode(SetTranslationsInput.self, arguments)
                return success(try TranslationEngine(project: project).applyProvided(input.translations))
            case "l10n_add_keys":
                let input = try decode(AddKeysInput.self, arguments)
                return success(try AddKeysCommand.run(project: project, keys: input.keys))
            case "l10n_accept":
                let input = try decode(AcceptInput.self, arguments)
                let count = try TranslationEngine(project: project).accept(keys: input.keys, locales: input.locales)
                return .init(content: [.text(text: "{\"updated\": \(count)}", annotations: nil, _meta: nil)], isError: false)
            default:
                return failure("Unknown tool \(name)")
            }
        } catch {
            return failure("\(error)")
        }
    }

    func decode<T: Decodable>(_ type: T.Type, _ arguments: [String: Value]) throws -> T {
        let data = try JSONEncoder().encode(Value.object(arguments))
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw L10nError.invalidArgument("Invalid arguments: \(error)")
        }
    }

    func success<T: Encodable>(_ value: T) -> CallTool.Result {
        .init(content: [.text(text: JSONOutput.encode(value), annotations: nil, _meta: nil)], isError: false)
    }

    func failure(_ message: String) -> CallTool.Result {
        .init(content: [.text(text: message, annotations: nil, _meta: nil)], isError: true)
    }
}

/// FIFO async mutex (actor methods alone are reentrant across awaits).
actor AsyncLock {
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func lock() async {
        if !locked {
            locked = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func unlock() {
        if waiters.isEmpty {
            locked = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}
