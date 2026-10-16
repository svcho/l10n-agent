import ArgumentParser
import Foundation
import L10nCore
import L10nMCP

let version = "0.4.0"

struct GlobalOptions: ParsableArguments {
    @Option(name: .long, help: "Project root (folder containing your .xcodeproj or Package.swift).")
    var path: String = FileManager.default.currentDirectoryPath

    func project() throws -> Project {
        try Project.discover(root: URL(fileURLWithPath: path))
    }
}

extension OutputFormat: ExpressibleByArgument {}

enum ExitCodes {
    static let findings: Int32 = 1
    static let usage: Int32 = 2
    static let translator: Int32 = 3
}

func printError(_ error: Error) {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
}

func execute(_ body: () async throws -> Int32) async throws {
    do {
        let code = try await body()
        if code != 0 { throw ExitCode(code) }
    } catch let error as L10nError {
        printError(error)
        throw ExitCode(ExitCodes.usage)
    }
}

@main
struct L10nAgent: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "l10n-agent",
        abstract: "Find, fix and translate localization issues in Xcode projects.",
        discussion: """
        Typical loop:
          l10n-agent lint                 # what is not localized or not translated
          l10n-agent fix                  # preview code + catalog fixes
          l10n-agent fix --apply          # apply them
          l10n-agent translate            # fill translations with a local LLM (needs_review)
        """,
        version: version,
        subcommands: [Lint.self, Fix.self, Translate.self, SetTranslation.self, Status.self, Accept.self, Doctor.self, Init.self, Migrate.self, ListRules.self, MCP.self]
    )
}

struct Lint: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Report unlocalized code and catalog problems.")

    @OptionGroup var global: GlobalOptions
    @Option(help: "Output format: text, xcode, json, sarif.") var format: OutputFormat = .text
    @Option(parsing: .upToNextOption, help: "Only run these rules (IDs or names).") var rules: [String] = []
    @Option(parsing: .upToNextOption, help: "Only scan these Swift files or folders.") var files: [String] = []
    @Flag(help: "Skip Swift code; check catalogs only.") var catalogsOnly = false
    @Flag(help: "Skip catalogs; check Swift code only.") var codeOnly = false
    @Option(help: "Exit non-zero when a finding has at least this severity: error, warning (default; includes missing and stale translations and unlocalized text), info, off (never fail).") var failOn: Severity = .warning

    func run() async throws {
        try await execute {
            let project = try global.project()
            let report = try Linter(project: project).run(LintOptions(
                rules: rules.isEmpty ? nil : Set(rules),
                files: files.isEmpty ? nil : files,
                code: !catalogsOnly,
                catalogs: !codeOnly
            ))
            let output = Reporter.render(report, format: format, root: project.root)
            if !output.isEmpty { print(output) }
            return report.exitCode(failOn: failOn) == 0 ? 0 : ExitCodes.findings
        }
    }
}

struct Fix: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Plan or apply fixes: add semantic keys to the catalog and rewrite code to use them.",
        discussion: "Without --apply only a preview is printed. Items whose placeholder types were guessed need --include-review (or edit the plan JSON and set status to ready)."
    )

    @OptionGroup var global: GlobalOptions
    @Option(parsing: .upToNextOption, help: "Rules to fix (default: L10N001 L10N002 L10N003).") var rules: [String] = []
    @Option(parsing: .upToNextOption, help: "Only fix these Swift files or folders.") var files: [String] = []
    @Option(parsing: .upToNextOption, help: "Only fix these finding IDs (from lint --format json).") var ids: [String] = []
    @Flag(help: "Write the changes.") var apply = false
    @Flag(help: "Also apply items marked needsReview.") var includeReview = false
    @Flag(help: "Ask the local LLM for key names and translator comments.") var llmKeys = false
    @Option(help: "Write the plan as JSON to this file.") var planOut: String?
    @Option(help: "Apply a previously saved (and possibly edited) plan.") var plan: String?
    @Option(help: "Output format: text or json.") var format: OutputFormat = .text

    func run() async throws {
        try await execute {
            let project = try global.project()
            let fixer = Fixer(project: project)
            var fixPlan: FixPlan
            if let planPath = plan {
                let data = try Data(contentsOf: URL(fileURLWithPath: planPath))
                fixPlan = try JSONDecoder().decode(FixPlan.self, from: data)
                if !apply {
                    // Show what apply would write from the edited keys, comments and specifiers.
                    fixPlan = try fixer.refresh(fixPlan)
                }
            } else {
                fixPlan = try fixer.plan(rules: rules.isEmpty ? nil : Set(rules), files: files.isEmpty ? nil : files, findingIDs: ids.isEmpty ? nil : Set(ids))
                if llmKeys, !fixPlan.items.isEmpty {
                    let model = try await ChatModelFactory.make(project.config.translator)
                    FileHandle.standardError.write(Data("Asking \(model.name) for key names...\n".utf8))
                    fixPlan = try await LLMKeyNamer(project: project, model: model).improve(fixPlan)
                }
            }
            if let planOut {
                try AtomicFile.write(JSONOutput.encode(fixPlan) + "\n", to: URL(fileURLWithPath: planOut))
            }
            guard apply else {
                print(format == .json ? JSONOutput.encode(fixPlan) : Fixer.preview(fixPlan))
                if !fixPlan.items.isEmpty, format != .json {
                    print("\nRun again with --apply to write these changes.")
                }
                return 0
            }
            let result = try fixer.apply(fixPlan, includeReview: includeReview)
            if format == .json {
                print(JSONOutput.encode(result))
            } else {
                print("Applied \(result.applied.count) fix(es); added \(result.keysAdded.count) key(s).")
                for file in result.filesChanged { print("  changed \(file)") }
                for catalog in result.catalogsChanged { print("  updated \(catalog)") }
                for (id, reason) in result.skipped.sorted(by: { $0.key < $1.key }) { print("  skipped \(id): \(reason)") }
                for note in result.notes { print("note: \(note)") }
            }
            return 0
        }
    }
}

struct Translate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Translate missing and stale strings with a local LLM.",
        discussion: "Results are written with state needs_review. Approved (translated) entries are never overwritten."
    )

    @OptionGroup var global: GlobalOptions
    @Option(parsing: .upToNextOption, help: "Only these locales.") var locale: [String] = []
    @Option(parsing: .upToNextOption, help: "Only these keys.") var key: [String] = []
    @Option(parsing: .upToNextOption, help: "Only these catalogs (path or file name).") var catalog: [String] = []
    @Option(help: "Override translator.model.") var model: String?
    @Option(help: "Strings per request.") var batchSize: Int?
    @Flag(help: "Show what would be translated without calling the model.") var dryRun = false
    @Option(help: "Output format: text or json.") var format: OutputFormat = .text

    func run() async throws {
        try await execute {
            let project = try global.project()
            let options = TranslateOptions(
                locales: locale.isEmpty ? nil : locale,
                keys: key.isEmpty ? nil : key,
                catalogs: catalog.isEmpty ? nil : catalog,
                dryRun: dryRun,
                batchSize: batchSize
            )
            let chatModel = dryRun ? nil : try await ChatModelFactory.make(project.config.translator, modelOverride: model)
            let engine = TranslationEngine(project: project) { message in
                FileHandle.standardError.write(Data("\(message)\n".utf8))
            }
            var report = try await engine.run(options, model: chatModel)
            // Tell now, not on the real run, when the translator would be refused.
            if dryRun, report.planned > 0, let refusal = await TranslationEngine.refusal(project.config.translator, modelOverride: model) {
                report.warnings.append(refusal)
            }
            if format == .json {
                print(JSONOutput.encode(report))
            } else {
                print(TranslateText.render(report))
            }
            return report.failed.isEmpty && report.aborted == nil ? 0 : ExitCodes.translator
        }
    }
}

enum TranslateText {
    static func render(_ report: TranslateReport) -> String {
        var lines: [String] = []
        if report.dryRun {
            lines.append("\(report.planned) string(s) would be translated:")
            for unit in report.units ?? [] {
                let text = unit.source ?? unit.sourceForms.map { "plural: " + $0.sorted(by: { $0.key < $1.key }).map { "\($0.key)=\($0.value)" }.joined(separator: " | ") } ?? ""
                lines.append("  [\(unit.locale)] \(unit.key) (\(unit.reason)): \(text)")
            }
        } else {
            lines.append("Translated \(report.translated) of \(report.planned) with \(report.model ?? "model") (state: needs_review).")
            for (locale, count) in report.perLocale.sorted(by: { $0.key < $1.key }) {
                lines.append("  \(locale): \(count)")
            }
        }
        for issue in report.failed { lines.append("failed \(issue.key) [\(issue.locale)]: \(issue.reason)") }
        for issue in report.approvedSkipped { lines.append("stale  \(issue.key) [\(issue.locale)]: \(issue.reason)") }
        for warning in report.warnings { lines.append("warning: \(warning)") }
        if let aborted = report.aborted { lines.append("aborted: \(aborted)") }
        return lines.joined(separator: "\n")
    }
}

struct SetTranslation: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set-translation",
        abstract: "Write translations you made yourself (validated, state needs_review).",
        discussion: """
        Examples:
          l10n-agent set-translation --key settings.title --locale de --value "Einstellungen"
          l10n-agent set-translation --key inbox.count --locale de --form one="%lld Nachricht" --form other="%lld Nachrichten"
          l10n-agent set-translation --file translations.json   # [{"key", "locale", "value" | "forms", "catalog"?}]
        Approved (translated) entries are never overwritten.
        """
    )
    @OptionGroup var global: GlobalOptions
    @Option(help: "Key to translate.") var key: String?
    @Option(help: "Target locale.") var locale: String?
    @Option(help: "Translation with the same format specifiers as the source.") var value: String?
    @Option(parsing: .singleValue, help: "A plural form as category=text; repeat for each category.") var form: [String] = []
    @Option(help: "Catalog path, when the key exists in several catalogs.") var catalog: String?
    @Option(help: "JSON file with a list of translations.") var file: String?
    @Option(help: "Output format: text or json.") var format: OutputFormat = .text

    func run() async throws {
        try await execute {
            var provided: [ProvidedTranslation] = []
            if let file {
                let data = try Data(contentsOf: URL(fileURLWithPath: file))
                do {
                    provided = try JSONDecoder().decode([ProvidedTranslation].self, from: data)
                } catch {
                    throw L10nError.config("\(file) must be a JSON list of {key, locale, value | forms, catalog?}: \(error)")
                }
            }
            if let key {
                guard let locale else { throw L10nError.config("--locale is required with --key") }
                provided.append(try ProvidedTranslation.fromOptions(key: key, locale: locale, value: value, forms: form, catalog: catalog))
            }
            guard !provided.isEmpty else { throw L10nError.config("pass --key/--locale/--value or --file") }
            let report = try TranslationEngine(project: try global.project()).applyProvided(provided)
            print(format == .json ? JSONOutput.encode(report) : TranslateText.render(report))
            return report.failed.isEmpty ? 0 : ExitCodes.findings
        }
    }
}

struct Status: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show translation coverage per catalog and locale.")
    @OptionGroup var global: GlobalOptions
    @Option(help: "Output format: text or json.") var format: OutputFormat = .text
    @Option(help: "Exit non-zero when any catalog/locale is below this percentage (approved + needs review), e.g. 100.") var failUnder: Int?
    @Flag(help: "With --fail-under, count only approved translations.") var approvedOnly = false

    func run() async throws {
        try await execute {
            let report = try StatusCommand.run(project: try global.project())
            print(format == .json ? JSONOutput.encode(report) : StatusCommand.text(report))
            guard let failUnder else { return 0 }
            let below = StatusCommand.below(report, percent: failUnder, approvedOnly: approvedOnly)
            for line in below { FileHandle.standardError.write(Data("below \(failUnder)%: \(line)\n".utf8)) }
            return below.isEmpty ? 0 : ExitCodes.findings
        }
    }
}

struct Accept: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Mark translations as up to date with the current source text.",
        discussion: "Use after reviewing translations whose source changed (L10N103). Approving the translation itself happens in Xcode's String Catalog editor."
    )
    @OptionGroup var global: GlobalOptions
    @Option(parsing: .upToNextOption, help: "Only these keys.") var key: [String] = []
    @Option(parsing: .upToNextOption, help: "Only these locales.") var locale: [String] = []

    func run() async throws {
        try await execute {
            let count = try TranslationEngine(project: try global.project()).accept(keys: key.isEmpty ? nil : key, locales: locale.isEmpty ? nil : locale)
            print("Updated \(count) fingerprint(s).")
            return 0
        }
    }
}

struct Doctor: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Check Xcode, catalogs, locales and the local translator.")
    @OptionGroup var global: GlobalOptions
    @Option(help: "Output format: text or json.") var format: OutputFormat = .text

    func run() async throws {
        try await execute {
            let report = await DoctorCommand.run(project: try global.project())
            print(format == .json ? JSONOutput.encode(report) : DoctorCommand.text(report))
            return report.ok ? 0 : ExitCodes.findings
        }
    }
}

struct Init: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Create .l10n-agent.yml and record fingerprints for existing translations.")
    @OptionGroup var global: GlobalOptions
    @Option(help: "Model to configure.") var model: String?
    @Flag(help: "Overwrite an existing config.") var force = false
    @Flag(help: "Write translator.allowRemote: true for a remote endpoint or :cloud model (runs also need L10N_AGENT_ALLOW_REMOTE=1).") var allowRemote = false

    func run() async throws {
        try await execute {
            let result = try await InitCommand.run(root: URL(fileURLWithPath: global.path), model: model, force: force, allowRemote: allowRemote)
            print(result.createdConfig ? "Wrote \(result.configPath)" : "Kept \(result.configPath)")
            print("Recorded \(result.baselined) translation fingerprint(s).")
            for note in result.notes { print("note: \(note)") }
            return 0
        }
    }
}

struct Migrate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Convert legacy .lproj/*.strings and *.stringsdict files into String Catalogs.",
        discussion: """
        Each <Table>.strings group becomes <Table>.xcstrings next to the .lproj folders. Values and \
        the comment above each entry are kept, existing translations are marked translated, plural \
        .stringsdict rules become plural variations or substitutions, and fingerprints are recorded. \
        Without --apply only a preview is printed. Storyboard/XIB strings are left to Xcode.
        """
    )
    @OptionGroup var global: GlobalOptions
    @Flag(help: "Write the catalogs.") var apply = false
    @Flag(help: "With --apply, delete the migrated .strings/.stringsdict files (and empty .lproj folders).") var removeLegacy = false
    @Option(help: "Output format: text or json.") var format: OutputFormat = .text

    func run() async throws {
        try await execute {
            guard apply || !removeLegacy else { throw L10nError.config("--remove-legacy needs --apply") }
            let result = try MigrateCommand.run(project: try global.project(), apply: apply, removeLegacy: removeLegacy)
            if format == .json {
                print(JSONOutput.encode(result))
                return result.failed.isEmpty ? 0 : ExitCodes.findings
            }
            for table in result.tables {
                print("\(apply ? (table.created ? "created" : "updated") : (table.created ? "would create" : "would update")) \(table.catalog): \(table.keys) key(s), \(table.locales.joined(separator: ", "))")
                for source in table.sources { print("  from \(source)") }
                for conflict in table.conflicts { print("  kept existing catalog value for \(conflict)") }
            }
            for (file, reason) in result.skipped.sorted(by: { $0.key < $1.key }) { print("skipped \(file): \(reason)") }
            for (file, reason) in result.failed.sorted(by: { $0.key < $1.key }) { print("failed \(file): \(reason)") }
            for file in result.removed { print("removed \(file)") }
            for note in result.notes { print("note: \(note)") }
            if !apply, !result.tables.isEmpty { print("\nRun again with --apply to write the catalogs (add --remove-legacy to delete the old files).") }
            return result.failed.isEmpty ? 0 : ExitCodes.findings
        }
    }
}

struct ListRules: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "rules", abstract: "List lint rules.")

    func run() throws {
        for rule in Rules.all {
            print("\(rule.id)  \(rule.name.padding(toLength: 20, withPad: " ", startingAt: 0)) \(rule.defaultSeverity.rawValue.padding(toLength: 8, withPad: " ", startingAt: 0)) \(rule.summary)")
        }
    }
}

struct MCP: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mcp",
        abstract: "Run a Model Context Protocol server over stdio for coding agents."
    )
    @OptionGroup var global: GlobalOptions

    func run() async throws {
        try await L10nMCPServer(root: URL(fileURLWithPath: global.path), version: version).run()
    }
}

extension Severity: ExpressibleByArgument {}
