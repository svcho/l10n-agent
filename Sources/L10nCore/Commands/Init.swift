import Foundation

public struct InitResult: Codable, Equatable, Sendable {
    public var configPath: String
    public var createdConfig: Bool
    public var baselined: Int
    public var notes: [String]
}

public enum InitCommand {
    /// Writes `.l10n-agent.yml` with detected settings and records fingerprints for the
    /// existing translations so later source edits are detected.
    public static func run(root: URL, model: String? = nil, force: Bool = false) async throws -> InitResult {
        let project = try Project.discover(root: root)
        let configURL = project.root.appendingPathComponent(L10nConfig.fileName)
        var notes: [String] = []
        var created = false

        if !FileManager.default.fileExists(atPath: configURL.path) || force {
            let catalogs = (try? project.loadCatalogs()) ?? []
            let locales = project.targetLocales(catalogs: catalogs)
            var detectedModel = model
            if detectedModel == nil, let baseURL = URL(string: project.config.translator.baseURL), HTTP.isLocal(baseURL),
               let installed = try? await OllamaChatModel.installedModels(baseURL: baseURL) {
                detectedModel = installed.first { !$0.isRemote }?.name
            }
            let catalog = project.defaultCatalogURL(for: nil).map(project.relativePath)
            let lock = try ProjectLock.acquire(root: project.root)
            defer { lock.release() }
            try AtomicFile.write(configTemplate(
                sourceLanguage: project.sourceLanguage,
                locales: locales,
                catalog: catalog,
                model: detectedModel
            ), to: configURL)
            created = true
            if locales.isEmpty {
                notes.append("No target locales detected. Add languages in Xcode (Project > Info > Localizations) or list them under `locales:`.")
            }
            if detectedModel == nil {
                notes.append("No local Ollama model found. Install one (e.g. `ollama pull qwen3`) and set translator.model.")
            }
        } else {
            notes.append("\(L10nConfig.fileName) already exists; left unchanged (use --force to overwrite).")
        }

        let stateDirectory = project.root.appendingPathComponent(".l10n-agent")
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        let ignore = stateDirectory.appendingPathComponent(".gitignore")
        if !FileManager.default.fileExists(atPath: ignore.path) {
            try AtomicFile.write("lock\n", to: ignore)
        }

        let refreshed = try Project.discover(root: root)
        let baselined = try TranslationEngine(project: refreshed).accept(keys: nil, locales: nil)
        notes.append("Add a Run Script build phase to see findings in Xcode: l10n-agent lint --format xcode --path \"$SRCROOT\" || true")
        return InitResult(configPath: refreshed.relativePath(configURL), createdConfig: created, baselined: baselined, notes: notes)
    }

    static func configTemplate(sourceLanguage: String, locales: [String], catalog: String?, model: String?) -> String {
        func yamlList(_ values: [String]) -> String {
            values.isEmpty ? "[]" : "[" + values.map { "\"\($0)\"" }.joined(separator: ", ") + "]"
        }
        return """
        # l10n-agent configuration. All keys are optional.
        sourceLanguage: \(sourceLanguage)
        # Languages to translate into. Defaults to the Xcode project's knownRegions.
        locales: \(yamlList(locales))
        \(catalog.map { "# Catalog that receives new keys from `fix`.\ncatalog: \"\($0)\"" } ?? "# catalog: App/Localizable.xcstrings")
        # auto: generated symbols when STRING_CATALOG_GENERATE_SYMBOLS = YES, else String(localized:) literals.
        codeStyle: auto
        # Report English-text keys such as Text("Welcome") and propose semantic keys.
        semanticKeys: true
        keys:
          style: dotted.camel        # dotted.camel | dotted.lower | dotted.snake
          minDepth: 2
          maxDepth: 4
          scopes: []                 # allowed first segments, e.g. [onboarding, settings, common]
          forbiddenPrefixes: ["tmp.", "debug.", "test."]
        exclude: ["**/Tests/**", "**/Preview Content/**"]
        rules: {}                    # e.g. { L10N105: off, L10N101: error }
        glossary: {}                 # e.g. { "Acme Cloud": { de: "Acme Cloud", ja: "Acme Cloud" } }
        translator:
          provider: ollama           # ollama | openai (LM Studio, llama.cpp, vLLM)
          baseURL: http://localhost:11434
          \(model.map { "model: \"\($0)\"" } ?? "# model: qwen3")
          batchSize: 20
          allowRemote: false         # remote endpoints also need L10N_AGENT_ALLOW_REMOTE=1

        """
    }
}
