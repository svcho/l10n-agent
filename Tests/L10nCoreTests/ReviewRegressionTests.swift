import Foundation
import Testing
@testable import L10nCore

/// Regression tests for findings of the independent review of the Swift rewrite.
@Suite("Review regressions")
struct ReviewRegressionTests {
    // MARK: Approved translations are never overwritten (H1)

    func pluralSource() -> [String: Any] {
        ["extractionState": "manual", "comment": "c", "localizations": ["en": ["variations": ["plural": ["one": TestSupport.unit("%lld file"), "other": TestSupport.unit("%lld files")]]]]]
    }

    func translator() -> ScriptedChatModel {
        EchoTranslator(transform: { _, text in "T " + text }, formsTransform: { _, categories, _ in
            Dictionary(uniqueKeysWithValues: categories.map { ($0, "⟦1⟧ \($0)") })
        }).model()
    }

    @Test func approvedPlainTranslationOfPluralSourceIsLeftAlone() async throws {
        var source = pluralSource()
        var localizations = source["localizations"] as! [String: Any]
        localizations["de"] = TestSupport.unit("%lld Dateien")
        source["localizations"] = localizations
        let root = try TestSupport.makeProject([".l10n-agent.yml": "locales: [de]\n", "L.xcstrings": TestSupport.catalogJSON(["files": source])])
        let report = try await TranslationEngine(project: try Project.discover(root: root)).run(TranslateOptions(), model: translator())
        #expect(report.planned == 0)
        #expect(report.approvedSkipped.first?.reason.contains("no plural variations") == true)
        let de = try StringCatalog.load(root.appendingPathComponent("L.xcstrings")).entry("files")?.localization("de")
        #expect(de?.stringUnit == StringUnit(state: "translated", value: "%lld Dateien"))
    }

    @Test func onlyMissingPluralCategoriesAreTranslated() async throws {
        var source = pluralSource()
        var localizations = source["localizations"] as! [String: Any]
        localizations["fr"] = ["variations": ["plural": ["one": TestSupport.unit("%lld fichier"), "other": TestSupport.unit("%lld fichiers")]]]
        source["localizations"] = localizations
        let root = try TestSupport.makeProject([".l10n-agent.yml": "locales: [fr]\n", "L.xcstrings": TestSupport.catalogJSON(["files": source])])
        let report = try await TranslationEngine(project: try Project.discover(root: root)).run(TranslateOptions(), model: translator())
        #expect(report.translated == 1)
        let fr = try #require(try StringCatalog.load(root.appendingPathComponent("L.xcstrings")).entry("files")?.localization("fr"))
        let byCategory = Dictionary(uniqueKeysWithValues: fr.leaves.map { ($0.path.last!, $0.unit) })
        #expect(byCategory["one"] == StringUnit(state: "translated", value: "%lld fichier"))
        #expect(byCategory["other"] == StringUnit(state: "translated", value: "%lld fichiers"))
        #expect(byCategory["many"] == StringUnit(state: "needs_review", value: "%lld many"))
    }

    @Test func brokenMachineCategoryIsRepairedNextToApprovedOne() async throws {
        var source = pluralSource()
        var localizations = source["localizations"] as! [String: Any]
        localizations["pl"] = ["variations": ["plural": [
            "one": TestSupport.unit("%lld plik"),
            "few": TestSupport.unit("%lld pliki", state: "needs_review"),
            "many": TestSupport.unit("%lld plików", state: "needs_review"),
            "other": TestSupport.unit("%@ pliku", state: "needs_review"),
        ]]]
        source["localizations"] = localizations
        let root = try TestSupport.makeProject([".l10n-agent.yml": "locales: [pl]\n", "L.xcstrings": TestSupport.catalogJSON(["files": source])])
        let planned = try await TranslationEngine(project: try Project.discover(root: root)).run(TranslateOptions(dryRun: true), model: nil)
        #expect(planned.units?.first?.categories == ["other"])
        _ = try await TranslationEngine(project: try Project.discover(root: root)).run(TranslateOptions(), model: translator())
        let pl = try #require(try StringCatalog.load(root.appendingPathComponent("L.xcstrings")).entry("files")?.localization("pl"))
        let byCategory = Dictionary(uniqueKeysWithValues: pl.leaves.map { ($0.path.last!, $0.unit) })
        #expect(byCategory["one"] == StringUnit(state: "translated", value: "%lld plik"))
        #expect(byCategory["few"]?.value == "%lld pliki")
        #expect(byCategory["other"] == StringUnit(state: "needs_review", value: "%lld other"))
    }

    // MARK: Whole-call rewrites never drop code (H2)

    @Test func wrappedOrExtraArgumentsAreNotRewrittenWholesale() throws {
        let root = try TestSupport.makeProject([
            ".l10n-agent.yml": "codeStyle: literal\n",
            "App/Localizable.xcstrings": TestSupport.catalogJSON([:]),
            "App/HomeView.swift": """
            import SwiftUI
            struct HomeView: View {
                var body: some View {
                    Text(flag ? "Online now" : "Offline now")
                    Text(name ?? "Guest user")
                    Text("Package text", bundle: .module)
                    Text("Commented text", comment: "Shown on the home screen")
                }
                func update() { label.text = flag ? "Switch on" : "Switch off" }
            }
            """,
        ])
        let project = try Project.discover(root: root)
        let plan = try Fixer(project: project).plan()
        func item(_ text: String) -> FixItem? { plan.items.first { $0.sourceValue == text } }
        #expect(item("Online now")?.status == .skipped)
        #expect(item("Offline now")?.status == .skipped)
        #expect(item("Guest user")?.status == .skipped)
        #expect(item("Package text")?.reason?.contains("bundle:") == true)
        #expect(item("Commented text")?.status == .ready)
        #expect(item("Commented text")?.comment == "Shown on the home screen")
        #expect(item("Switch on")?.status == .ready, "literal-only replacements inside a ternary are safe")

        let result = try Fixer(project: project).apply(plan)
        let code = try String(contentsOf: root.appendingPathComponent("App/HomeView.swift"), encoding: .utf8)
        #expect(code.contains(#"Text(flag ? "Online now" : "Offline now")"#))
        #expect(code.contains(#"Text(name ?? "Guest user")"#))
        #expect(code.contains(#"label.text = flag ? String(localized: "home.switch.label", defaultValue: "Switch on"#), "\(code)")
        #expect(code.contains(#"comment: "Shown on the home screen")"#))
        #expect(result.applied.count == 3)
    }

    @Test func formatSpecifierLiteralsAreSkipped() throws {
        let root = try TestSupport.makeProject([
            ".l10n-agent.yml": "codeStyle: symbols\n",
            "App/Localizable.xcstrings": TestSupport.catalogJSON([:]),
            "App/Home.swift": #"func f() { label.text = String(format: NSLocalizedString("Hello %@", comment: ""), name) }"#,
        ])
        let plan = try Fixer(project: try Project.discover(root: root)).plan()
        #expect(plan.items.allSatisfy { $0.status == .skipped })
    }

    @Test func newCatalogsInPackagesGoIntoTheTarget() throws {
        let root = try TestSupport.makeProject([
            ".l10n-agent.yml": "codeStyle: literal\n",
            "Feature/Package.swift": "// swift-tools-version: 6.0\n",
            "Feature/Sources/Feat/F.swift": "enum Errors { static var errorTitle: String { \"Something failed\" } }\n",
            // A root manifest kept for tooling must not make app files package code.
            "Package.swift": "// swift-tools-version: 6.0\n",
            "App.xcodeproj/project.pbxproj": "// stub\n",
            "App/V.swift": "func f() { label.text = \"App text\" }\n",
        ])
        let project = try Project.discover(root: root)
        let plan = try Fixer(project: project).plan()
        let feature = try #require(plan.items.first { $0.file.hasPrefix("Feature/") })
        let app = try #require(plan.items.first { $0.file.hasPrefix("App/") })
        #expect(feature.catalog == "Feature/Sources/Feat/Localizable.xcstrings")
        #expect(feature.replacement.contains("bundle: .module"))
        #expect(!app.replacement.contains("bundle: .module"))
        let result = try Fixer(project: project).apply(plan)
        #expect(result.catalogsChanged.contains("Feature/Sources/Feat/Localizable.xcstrings"))
        #expect(result.notes.contains { $0.contains("defaultLocalization") })
    }

    @Test func swiftPackageLiteralsUseModuleBundle() throws {
        let root = try TestSupport.makeProject([
            ".l10n-agent.yml": "codeStyle: literal\n",
            "Packages/Feature/Package.swift": "// swift-tools-version: 6.0\n",
            "Packages/Feature/Sources/Feature/Localizable.xcstrings": TestSupport.catalogJSON([:]),
            "Packages/Feature/Sources/Feature/View.swift": "func f() { label.text = \"Feature title\" }\n",
        ])
        let plan = try Fixer(project: try Project.discover(root: root)).plan()
        #expect(plan.items.first?.replacement.contains("bundle: .module") == true)
    }

    // MARK: Keys added by fix stay in their own catalog (H3)

    @Test func applyDoesNotDeleteKeysFromOtherCatalogs() throws {
        let root = try TestSupport.makeProject([
            ".l10n-agent.yml": "codeStyle: literal\n",
            "App/Localizable.xcstrings": TestSupport.catalogJSON([:]),
            "App/Settings.xcstrings": TestSupport.catalogJSON([
                "home.saveDraft": TestSupport.manual("Save draft", translations: ["de": TestSupport.unit("Entwurf sichern")]),
            ]),
            "App/HomeView.swift": """
            import SwiftUI
            struct HomeView: View {
                var body: some View {
                    Text("Sync now", tableName: "Settings")
                }
                func f() { label.text = "Save draft" }
            }
            """,
        ])
        let project = try Project.discover(root: root)
        var plan = try Fixer(project: project).plan()
        // Force a conflict in Localizable so one edit is skipped.
        if let index = plan.items.firstIndex(where: { $0.sourceValue == "Save draft" }) {
            plan.items[index].key = "home.saveDraft"
        }
        _ = try Fixer(project: project).apply(plan)
        let settings = try StringCatalog.load(root.appendingPathComponent("App/Settings.xcstrings"))
        #expect(settings.entry("home.saveDraft")?.localization("de")?.stringUnit?.value == "Entwurf sichern")
    }

    // MARK: Plans are untrusted input (M1, M5)

    @Test func craftedPlanCannotInjectCodeOrWriteElsewhere() throws {
        let root = try TestSupport.makeProject([
            ".l10n-agent.yml": "codeStyle: literal\n",
            "Package.swift": "// swift-tools-version: 6.0\nlet name = \"pkg\"\n",
            "App/Localizable.xcstrings": TestSupport.catalogJSON([:]),
            "App/View.swift": "func f() { label.text = \"Hello there\" }\n",
        ])
        let project = try Project.discover(root: root)
        let honest = try Fixer(project: project).plan()
        var plan = honest
        var item = plan.items[0]
        item.segments = [.expression(#"{ () -> String in print("pwned"); return "" }()"#)]
        item.placeholders = [FixPlaceholder(expression: #"{ () -> String in print("pwned"); return "" }()"#, specifier: "%@", confident: true)]
        plan.items = [item]
        let injected = try Fixer(project: project).apply(plan)
        #expect(injected.applied.isEmpty)
        #expect(!(try String(contentsOf: root.appendingPathComponent("App/View.swift"), encoding: .utf8)).contains("pwned"))

        // Plans may not target non-source files, non-catalog paths or bogus ranges.
        var other = honest
        other.files = ["Package.swift": Hashing.sha256(try String(contentsOf: root.appendingPathComponent("Package.swift"), encoding: .utf8))]
        other.items[0].file = "Package.swift"
        #expect(throws: L10nError.self) { try Fixer(project: project).apply(other) }

        var badCatalog = honest
        badCatalog.items[0].catalog = "notes/evil.txt"
        #expect(try Fixer(project: project).apply(badCatalog).applied.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("notes/evil.txt").path))

        var badRange = honest
        badRange.items[0].range = ByteRange(start: 20, end: 5)
        #expect(try Fixer(project: project).apply(badRange).applied.isEmpty)

        // Editing the documented fields (key, comment) is fine.
        var edited = honest
        edited.items[0].key = "view.hello"
        edited.items[0].comment = "Greeting \"quoted\" \\(boom)"
        #expect(try Fixer(project: project).apply(edited).applied == [honest.items[0].id])
        let code = try String(contentsOf: root.appendingPathComponent("App/View.swift"), encoding: .utf8)
        #expect(code.contains(#"comment: "Greeting \"quoted\" \\(boom)")"#), "comments are escaped, not interpolated")
    }

    // MARK: Paths stay inside the project, including through symlinks (M2)

    @Test func symlinksCannotEscapeTheRoot() throws {
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let root = try TestSupport.makeProject(["App/View.swift": "\n"])
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("outlink"), withDestinationURL: outside)
        #expect(throws: L10nError.self) { try PathUtil.resolveInside("outlink/Localizable.xcstrings", root: root) }
        #expect(throws: L10nError.self) { try PathUtil.resolveInside("../x", root: root) }
        #expect(try PathUtil.resolveInside("App/New.xcstrings", root: root).lastPathComponent == "New.xcstrings")
    }

    // MARK: Provided translations (M3)

    @Test func providedTranslationsCannotTouchSourceOrUnknownLocales() throws {
        let root = try TestSupport.makeProject([
            ".l10n-agent.yml": "locales: [de]\n",
            "L.xcstrings": TestSupport.catalogJSON(["Hello world": [:], "brand": ["shouldTranslate": false, "localizations": ["en": TestSupport.unit("Acme")]]]),
        ])
        let report = try TranslationEngine(project: try Project.discover(root: root)).applyProvided([
            ProvidedTranslation(key: "Hello world", locale: "en", value: "Get lost"),
            ProvidedTranslation(key: "Hello world", locale: "../../x", value: "x"),
            ProvidedTranslation(key: "brand", locale: "de", value: "Akme"),
            ProvidedTranslation(key: "Hello world", locale: "de", value: "Hallo Welt"),
        ])
        #expect(report.translated == 1)
        #expect(report.failed.count == 3)
        let entry = try StringCatalog.load(root.appendingPathComponent("L.xcstrings")).entry("Hello world")
        #expect(entry?.localizationLocales == ["de"])
    }

    // MARK: Remote endpoints need a user-level opt-in (M6)

    @Test func repoConfigAloneCannotEnableRemoteEndpoints() async throws {
        await #expect(throws: L10nError.self) {
            _ = try await ChatModelFactory.make(TranslatorConfig(provider: .openai, baseURL: "https://api.example.com", model: "x", allowRemote: true))
        }
    }

    // MARK: Byte-exact text (L2)

    @Test func preservesByteOrderMarks() throws {
        let value = try JSONParser.parse("{\"\u{FEFF}key\":\"\u{FEFF}value\"}")
        #expect(value.objectValue?.members.first?.key.unicodeScalars.first == "\u{FEFF}")
        #expect(value["\u{FEFF}key"]?.stringValue?.unicodeScalars.first == "\u{FEFF}")

        let root = try TestSupport.makeProject([".l10n-agent.yml": "codeStyle: literal\n", "App/Localizable.xcstrings": TestSupport.catalogJSON([:])])
        let file = root.appendingPathComponent("App/View.swift")
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(Data("func f() { label.text = \"Hello there\" }\n".utf8))
        try data.write(to: file)
        let project = try Project.discover(root: root)
        let result = try Fixer(project: project).apply(try Fixer(project: project).plan())
        #expect(result.applied.count == 1)
        let written = try Data(contentsOf: file)
        #expect(written.starts(with: [0xEF, 0xBB, 0xBF]))
        #expect(String(decoding: written.dropFirst(3), as: UTF8.self).contains("String(localized:"))
    }

    @Test func productionFilesEndingInTestAreScanned() {
        #expect(!SwiftScanner.isTestFile(path: "App/SpeedTest.swift", source: "import UIKit"))
        #expect(SwiftScanner.isTestFile(path: "App/SpeedTests.swift", source: ""))
    }

    // MARK: Rule coverage (M7)

    @Test func catalogRulePositives() throws {
        let root = try TestSupport.makeProject([
            ".l10n-agent.yml": """
            sourceLanguage: en
            locales: [de]
            glossary: { "Acme Cloud": { de: "Acme Cloud" } }
            """,
            "A/Localizable.xcstrings": TestSupport.catalogJSON([
                "sync.title": TestSupport.manual("Sync with Acme Cloud", translations: ["de": TestSupport.unit("Mit Acme Wolke synchronisieren")]),
                "share.title": TestSupport.manual("Share this file", translations: ["de": TestSupport.unit("Share this file")]),
                "no.comment": TestSupport.manual("Uncommented", comment: nil, translations: ["de": TestSupport.unit("Ohne")]),
            ]),
            "B/Localizable.xcstrings": TestSupport.catalogJSON([:], sourceLanguage: "de"),
            "C/Broken.xcstrings": "{ not json",
            "A/View.swift": """
            import SwiftUI
            struct V: View { var body: some View { VStack { Text("missing.key"); Text("You have \\(count) files") } } }
            """,
        ])
        let report = try Linter(project: try Project.discover(root: root)).run()
        let rules = Set(report.diagnostics.map(\.rule))
        for rule in ["L10N100", "L10N004", "L10N005", "L10N105", "L10N108", "L10N109", "L10N111"] {
            #expect(rules.contains(rule), "expected \(rule)")
        }
        #expect(report.diagnostics.first { $0.rule == "L10N108" }?.key == "sync.title")
        #expect(report.diagnostics.first { $0.rule == "L10N109" }?.key == "share.title")
        #expect(report.diagnostics.first { $0.rule == "L10N105" }?.key == "no.comment")
    }
}
