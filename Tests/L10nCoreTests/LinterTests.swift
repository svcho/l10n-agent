import Foundation
import Testing
@testable import L10nCore

@Suite("Linter")
struct LinterTests {
    @Test func sampleAppFindings() throws {
        let project = try Project.discover(root: try TestSupport.copyFixture("SampleApp"))
        #expect(project.xcode.knownRegions == ["en", "Base", "de", "ja", "pl"])
        #expect(project.xcode.generatesSymbols)
        #expect(project.usesSymbols)
        #expect(project.targetLocales(catalogs: try project.loadCatalogs()) == ["de", "ja", "pl"])

        let report = try Linter(project: project).run()
        func findings(_ rule: RuleInfo) -> [Diagnostic] { report.diagnostics.filter { $0.rule == rule.id } }

        // Code
        #expect(findings(Rules.unlocalized).count == 10)
        #expect(findings(Rules.textAsKey).count == 12)
        #expect(findings(Rules.concatenation).count == 1)
        #expect(findings(Rules.pluralCandidate).count == 1)
        #expect(findings(Rules.missingKey).isEmpty, "onboarding.title exists")
        #expect(!report.diagnostics.contains { $0.message.contains("Logged out") }, "inline ignore")
        #expect(!report.diagnostics.contains { $0.message.contains("Debug menu") }, "#if DEBUG")
        #expect(!report.diagnostics.contains { $0.message.contains("Preview Name") })

        // Catalog
        let format = findings(Rules.formatMismatch)
        #expect(format.count == 1)
        #expect(format.first?.locales == ["ja"])
        #expect(findings(Rules.missingTranslation).first { $0.key == "inbox.unread" }?.locales == ["de", "ja", "pl"])
        #expect(findings(Rules.needsReview).map(\.key) == ["files.shared"])
        #expect(findings(Rules.unusedKey).map(\.key) == ["files.shared", "inbox.unread", "old.unused", "settings.darkMode", "settings.dark_mode"], "stale, plus manual keys no Swift file references")
        #expect(Set(findings(Rules.symbolCollision).compactMap(\.key)) == ["settings.darkMode", "settings.dark_mode"])
        #expect(findings(Rules.keyStyle).map(\.key) == ["settings.dark_mode"])
        #expect(report.summary.errors == 3)
        #expect(findings(Rules.formatMismatch).first?.line == 14)
    }

    @Test func ruleConfigurationAndSuppression() throws {
        let root = try TestSupport.makeProject([
            ".l10n-agent.yml": "rules: { L10N001: error, missing-comment: off }\nsemanticKeys: false\nlocales: [de]\n",
            "App/Localizable.xcstrings": TestSupport.catalogJSON(["Hello": [:]]),
            "App/View.swift": """
            import UIKit
            func a() {
                label.text = "Shown text"
                // l10n-agent:ignore L10N001
                label.text = "Ignored text"
                label.text = "Also ignored" // l10n-agent:ignore
                label.title = "Other rule only" // l10n-agent:ignore L10N003
                Text("Key text")
            }
            """,
        ])
        let report = try Linter(project: try Project.discover(root: root)).run()
        let code = report.diagnostics.filter { $0.file.hasSuffix(".swift") }
        #expect(code.map(\.message).contains { $0.contains("Shown text") })
        #expect(code.map(\.message).contains { $0.contains("Other rule only") })
        #expect(!code.map(\.message).contains { $0.contains("Ignored text") || $0.contains("Also ignored") })
        #expect(!code.contains { $0.rule == Rules.textAsKey.id }, "semanticKeys: false disables L10N002")
        #expect(code.allSatisfy { $0.severity == .error })
        #expect(!report.diagnostics.contains { $0.rule == Rules.missingComment.id })
        #expect(report.diagnostics.first { $0.rule == Rules.missingTranslation.id }?.locales == ["de"])
    }

    @Test func staleTranslationsFromFingerprints() throws {
        let root = try TestSupport.makeProject([
            ".l10n-agent.yml": "locales: [de]\n",
            "Localizable.xcstrings": TestSupport.catalogJSON([
                "home.title": TestSupport.manual("Home", translations: ["de": TestSupport.unit("Start")]),
            ]),
        ])
        var project = try Project.discover(root: root)
        #expect(try TranslationEngine(project: project).accept(keys: nil, locales: nil) == 1)
        #expect(try Linter(project: project).run().diagnostics.allSatisfy { $0.rule != Rules.staleTranslation.id })

        // Edit the source text: the German translation is now stale.
        var catalog = try StringCatalog.load(root.appendingPathComponent("Localizable.xcstrings"))
        var entry = catalog.entry("home.title")!
        entry.setLocalization("en", LocalizationNode(unit: StringUnit(state: "translated", value: "Home screen")))
        catalog.setEntry("home.title", entry)
        try catalog.write()
        project = try Project.discover(root: root)
        let stale = try Linter(project: project).run().diagnostics.filter { $0.rule == Rules.staleTranslation.id }
        #expect(stale.map(\.locales) == [["de"]])

        // Editing only the comment does not make translations stale.
        _ = try TranslationEngine(project: project).accept(keys: nil, locales: nil)
        entry = try StringCatalog.load(root.appendingPathComponent("Localizable.xcstrings")).entry("home.title")!
        entry.comment = "Changed comment"
        catalog = try StringCatalog.load(root.appendingPathComponent("Localizable.xcstrings"))
        catalog.setEntry("home.title", entry)
        try catalog.write()
        #expect(try Linter(project: try Project.discover(root: root)).run().diagnostics.allSatisfy { $0.rule != Rules.staleTranslation.id })
    }

    @Test func reportersRender() throws {
        let project = try Project.discover(root: try TestSupport.copyFixture("SampleApp"))
        let report = try Linter(project: project).run(LintOptions(rules: ["L10N104"]))
        let xcode = Reporter.render(report, format: .xcode, root: project.root)
        #expect(xcode.contains("Localizable.xcstrings:14:5: error: Translation ja of \"files.shared\""))
        #expect(xcode.hasSuffix("[L10N104]"))
        let sarif = try JSONParser.parse(Reporter.render(report, format: .sarif, root: project.root))
        #expect(sarif["version"]?.stringValue == "2.1.0")
        let json = try JSONDecoder().decode(LintReport.self, from: Data(Reporter.render(report, format: .json, root: project.root).utf8))
        #expect(json == report)
    }

    @Test func configRejectsUnknownKeys() throws {
        let root = try TestSupport.makeProject([".l10n-agent.yml": "locale: [de]\n"])
        #expect(throws: L10nError.self) { try Project.discover(root: root) }
    }

    @Test func keyPolicy() {
        let policy = KeyPolicy(style: .dottedCamel, scopes: ["settings", "common"])
        #expect(policy.violations(for: "settings.darkMode.toggle").isEmpty)
        #expect(!policy.violations(for: "settings.dark_mode").isEmpty)
        #expect(!policy.violations(for: "profile.title").isEmpty)
        #expect(!policy.violations(for: "settings").isEmpty)
        #expect(!policy.violations(for: "settings.a.b.c.d").isEmpty)
        #expect(!KeyPolicy(style: .dottedLower).violations(for: "a.darkMode").isEmpty)
        #expect(KeyPolicy(style: .dottedSnake).violations(for: "a.dark_mode").isEmpty)
    }
}
