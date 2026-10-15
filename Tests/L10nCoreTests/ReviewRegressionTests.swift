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

    // MARK: PR review (Codex)

    @Test func reusingAnExistingKeyKeepsTheTextKeysTranslations() throws {
        let root = try TestSupport.makeProject([
            ".l10n-agent.yml": "codeStyle: literal\nlocales: [de, ja]\n",
            "App/Localizable.xcstrings": TestSupport.catalogJSON([
                "home.welcomeBack": TestSupport.manual("Welcome back", translations: ["ja": TestSupport.unit("おかえりなさい")]),
                "Welcome back": ["localizations": ["de": TestSupport.unit("Willkommen zurück"), "ja": TestSupport.unit("お帰り")]],
            ]),
            "App/HomeView.swift": "import SwiftUI\nstruct HomeView: View { var body: some View { Text(\"Welcome back\") } }\n",
        ])
        let project = try Project.discover(root: root)
        let plan = try Fixer(project: project).plan()
        #expect(plan.items.first?.reusesExistingKey == true)
        #expect(plan.items.first?.key == "home.welcomeBack")
        let result = try Fixer(project: project).apply(plan)
        #expect(result.applied.count == 1)
        #expect(result.keysAdded.isEmpty)
        let catalog = try StringCatalog.load(root.appendingPathComponent("App/Localizable.xcstrings"))
        let entry = try #require(catalog.entry("home.welcomeBack"))
        #expect(entry.localization("de")?.stringUnit?.value == "Willkommen zurück", "missing locale copied from the text key")
        #expect(entry.localization("ja")?.stringUnit?.value == "おかえりなさい", "existing translation kept")
        #expect(catalog.entry("Welcome back")?.isStale == true)
    }

    @Test func planCodeStyleMustMatchTheProject() throws {
        let root = try TestSupport.makeProject([
            ".l10n-agent.yml": "codeStyle: literal\n",
            "App/Localizable.xcstrings": TestSupport.catalogJSON([:]),
            "App/View.swift": "func f() { label.text = \"Hello there\" }\n",
        ])
        let project = try Project.discover(root: root)
        var plan = try Fixer(project: project).plan()
        plan.codeStyle = CodeStyle.symbols.rawValue
        #expect(throws: L10nError.self) { try Fixer(project: project).apply(plan) }
    }

    @Test func planCannotMoveKeysToAnotherTargetsCatalog() throws {
        let root = try TestSupport.makeProject([
            ".l10n-agent.yml": "codeStyle: literal\n",
            "AppA/Localizable.xcstrings": TestSupport.catalogJSON([:]),
            "AppB/Localizable.xcstrings": TestSupport.catalogJSON([:]),
            "AppA/View.swift": "func f() { label.text = \"Hello there\" }\n",
        ])
        let project = try Project.discover(root: root)
        var plan = try Fixer(project: project).plan()
        #expect(plan.items.first?.catalog == "AppA/Localizable.xcstrings")
        plan.items[0].catalog = "AppB/Localizable.xcstrings"
        let result = try Fixer(project: project).apply(plan)
        #expect(result.applied.isEmpty)
        #expect(try StringCatalog.load(root.appendingPathComponent("AppB/Localizable.xcstrings")).keys.isEmpty)
    }

    @Test func dynamicTableOrCommentBlocksWholeCallRewrites() throws {
        let root = try TestSupport.makeProject([
            ".l10n-agent.yml": "codeStyle: literal\n",
            "App/Localizable.xcstrings": TestSupport.catalogJSON([:]),
            "App/HomeView.swift": """
            import SwiftUI
            struct HomeView: View {
                var body: some View {
                    Text("Welcome dynamic", tableName: activeTable)
                    Text("Welcome noted", comment: note)
                    Text("Welcome literal", tableName: "Localizable", comment: "Greeting")
                }
            }
            """,
        ])
        let plan = try Fixer(project: try Project.discover(root: root)).plan()
        func item(_ text: String) -> FixItem? { plan.items.first { $0.sourceValue == text } }
        #expect(item("Welcome dynamic")?.status == .skipped)
        #expect(item("Welcome dynamic")?.reason?.contains("tableName:") == true)
        #expect(item("Welcome noted")?.status == .skipped)
        #expect(item("Welcome literal")?.status == .ready)
        #expect(item("Welcome literal")?.comment == "Greeting")
    }

    @Test func missingKeyLookupIsScopedToTheFilesCatalog() throws {
        let root = try TestSupport.makeProject([
            "AppA/Localizable.xcstrings": TestSupport.catalogJSON(["a.title": TestSupport.manual("A")]),
            "AppB/Localizable.xcstrings": TestSupport.catalogJSON(["b.title": TestSupport.manual("B")]),
            "AppA/View.swift": """
            import SwiftUI
            struct V: View { var body: some View { VStack { Text("a.title"); Text("b.title") } } }
            """,
        ])
        let report = try Linter(project: try Project.discover(root: root)).run(LintOptions(rules: ["L10N004"]))
        #expect(report.diagnostics.map(\.key) == ["b.title"])
    }

    @Test func everyDeviceVariationMustBeTranslated() async throws {
        let root = try TestSupport.makeProject([
            ".l10n-agent.yml": "locales: [de]\n",
            "L.xcstrings": TestSupport.catalogJSON([
                "tap.hint": [
                    "extractionState": "manual", "comment": "c",
                    "localizations": [
                        "en": ["variations": ["device": ["iphone": TestSupport.unit("Tap here"), "mac": TestSupport.unit("Click here")]]],
                        "de": ["variations": ["device": ["iphone": TestSupport.unit("Hier tippen")]]],
                    ],
                ],
            ]),
        ])
        let project = try Project.discover(root: root)
        let lint = try Linter(project: project).run(LintOptions(rules: ["L10N101"]))
        #expect(lint.diagnostics.first?.locales == ["de"])
        #expect(try StatusCommand.run(project: project).catalogs.first?.locales.first?.missing == 1)
        let planned = try await TranslationEngine(project: project).run(TranslateOptions(dryRun: true), model: nil)
        #expect(planned.units?.map(\.path) == [["variations", "device", "mac"]])
    }

    @Test func pluralCategoriesCoverCLDRAndUnknownLanguagesAreNotGuessed() async throws {
        #expect(PluralRules.categories(for: "mt") == ["one", "two", "few", "many", "other"])
        #expect(PluralRules.categories(for: "cy") == ["zero", "one", "two", "few", "many", "other"])
        #expect(PluralRules.categories(for: "gd") == ["one", "two", "few", "other"])
        #expect(PluralRules.categories(for: "xx") == nil)
        #expect(PluralRules.categories(for: "xx-YY", overrides: ["xx": ["one", "few", "other"]]) == ["one", "few", "other"])

        let source: [String: Any] = ["extractionState": "manual", "comment": "c", "localizations": ["en": ["variations": ["plural": ["one": TestSupport.unit("%lld file"), "other": TestSupport.unit("%lld files")]]]]]
        let root = try TestSupport.makeProject([".l10n-agent.yml": "locales: [xx]\n", "L.xcstrings": TestSupport.catalogJSON(["files": source])])
        let report = try await TranslationEngine(project: try Project.discover(root: root)).run(TranslateOptions(dryRun: true), model: nil)
        #expect(report.planned == 0)
        #expect(report.failed.first?.reason.contains("pluralCategories") == true)

        let invalid = try TestSupport.makeProject([".l10n-agent.yml": "pluralCategories: { xx: [one, some] }\n"])
        #expect(throws: L10nError.self) { try Project.discover(root: invalid) }
    }

    @Test func namedTablesResolveWithinTheFilesTarget() throws {
        let root = try TestSupport.makeProject([
            ".l10n-agent.yml": "codeStyle: literal\n",
            "AppA/Localizable.xcstrings": TestSupport.catalogJSON([:]),
            "AppA/Settings.xcstrings": TestSupport.catalogJSON([:]),
            "AppB/Localizable.xcstrings": TestSupport.catalogJSON([:]),
            "AppB/Settings.xcstrings": TestSupport.catalogJSON([:]),
            "AppB/View.swift": """
            import SwiftUI
            struct V: View { var body: some View { VStack {
                Text("Sync settings now", tableName: "Settings")
                Text("Start onboarding now", tableName: "Onboarding")
            } } }
            """,
        ])
        let project = try Project.discover(root: root)
        let plan = try Fixer(project: project).plan()
        let settings = try #require(plan.items.first { $0.sourceValue == "Sync settings now" })
        let onboarding = try #require(plan.items.first { $0.sourceValue == "Start onboarding now" })
        #expect(settings.catalog == "AppB/Settings.xcstrings")
        #expect(onboarding.catalog == "AppB/Onboarding.xcstrings", "a new table keeps its name and lives in the file's target")
        #expect(onboarding.replacement.contains(#"table: "Onboarding""#))
        let result = try Fixer(project: project).apply(plan)
        #expect(result.applied.count == 2)
        #expect(try StringCatalog.load(root.appendingPathComponent("AppA/Settings.xcstrings")).keys.isEmpty)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("AppB/Onboarding.xcstrings").path))
    }

    @Test func unknownPluralRulesAreReportedEvenWithAnOtherForm() async throws {
        let source: [String: Any] = [
            "extractionState": "manual", "comment": "c",
            "localizations": [
                "en": ["variations": ["plural": ["one": TestSupport.unit("%lld file"), "other": TestSupport.unit("%lld files")]]],
                "xx": ["variations": ["plural": ["other": TestSupport.unit("%lld fileo", state: "needs_review")]]],
            ],
        ]
        let root = try TestSupport.makeProject([".l10n-agent.yml": "locales: [xx]\n", "L.xcstrings": TestSupport.catalogJSON(["files": source])])
        let project = try Project.discover(root: root)
        let report = try await TranslationEngine(project: project).run(TranslateOptions(dryRun: true), model: nil)
        #expect(report.failed.first?.reason.contains("pluralCategories") == true)
        #expect(try Linter(project: project).run(LintOptions(rules: ["L10N101"])).diagnostics.first?.locales == ["xx"])

        let configured = try TestSupport.makeProject([".l10n-agent.yml": "locales: [xx]\npluralCategories: { xx: [other] }\n", "L.xcstrings": TestSupport.catalogJSON(["files": source])])
        #expect(try Linter(project: try Project.discover(root: configured)).run(LintOptions(rules: ["L10N101"])).diagnostics.isEmpty)
    }

    @Test func glossaryIsCheckedInEveryVariation() throws {
        let root = try TestSupport.makeProject([
            ".l10n-agent.yml": "locales: [de]\nglossary: { \"Acme Cloud\": { de: \"Acme Cloud\" } }\n",
            "L.xcstrings": TestSupport.catalogJSON([
                "sync.files": [
                    "extractionState": "manual", "comment": "c",
                    "localizations": [
                        "en": ["variations": ["plural": ["one": TestSupport.unit("%lld file in Acme Cloud"), "other": TestSupport.unit("%lld files in Acme Cloud")]]],
                        "de": ["variations": ["plural": ["one": TestSupport.unit("%lld Datei in Acme Cloud"), "other": TestSupport.unit("%lld Dateien in der Wolke")]]],
                    ],
                ],
            ]),
        ])
        let findings = try Linter(project: try Project.discover(root: root)).run(LintOptions(rules: ["L10N108"])).diagnostics
        #expect(findings.count == 1)
        #expect(findings.first?.message.contains("plural.other") == true)
    }

    @Test func catalogFilterDoesNotNarrowTargetLocales() async throws {
        let root = try TestSupport.makeProject([
            "A/First.xcstrings": TestSupport.catalogJSON(["a.title": TestSupport.manual("A", translations: ["de": TestSupport.unit("A-de")])]),
            "B/Second.xcstrings": TestSupport.catalogJSON(["b.title": TestSupport.manual("Second title")]),
        ])
        let report = try await TranslationEngine(project: try Project.discover(root: root)).run(TranslateOptions(catalogs: ["Second.xcstrings"], dryRun: true), model: nil)
        #expect(report.units?.map { "\($0.key)/\($0.locale)" } == ["b.title/de"])
    }

    @Test func glossaryIsValidatedPerPluralForm() async throws {
        let source: [String: Any] = ["extractionState": "manual", "comment": "c", "localizations": ["en": ["variations": ["plural": [
            "one": TestSupport.unit("%lld file in Acme Cloud"),
            "other": TestSupport.unit("%lld files"),
        ]]]]]
        let root = try TestSupport.makeProject([
            ".l10n-agent.yml": "locales: [de]\nglossary: { \"Acme Cloud\": { de: \"Acme Cloud\" } }\ntranslator: { maxRetries: 1 }\n",
            "L.xcstrings": TestSupport.catalogJSON(["files": source]),
        ])
        let attempts = Counter()
        let model = ScriptedChatModel { _, _ in
            // First answer drops the term from "one" (where the source has it); "other" never needs it.
            let one = await attempts.next() == 1 ? "⟦1⟧ Datei" : "⟦1⟧ Datei in Acme Cloud"
            return #"{"translations":[{"id":"1","forms":{"one":"\#(one)","other":"⟦1⟧ Dateien"}}]}"#
        }
        let report = try await TranslationEngine(project: try Project.discover(root: root)).run(TranslateOptions(), model: model)
        #expect(report.translated == 1)
        #expect(report.warnings.isEmpty)
        #expect(await attempts.value == 2)
    }

    @Test func providedTranslationsNeedACatalogWhenTheKeyIsAmbiguous() throws {
        let root = try TestSupport.makeProject([
            ".l10n-agent.yml": "locales: [de]\n",
            "AppA/Localizable.xcstrings": TestSupport.catalogJSON(["common.cancel": TestSupport.manual("Cancel")]),
            "AppB/Localizable.xcstrings": TestSupport.catalogJSON(["common.cancel": TestSupport.manual("Cancel")]),
        ])
        let engine = TranslationEngine(project: try Project.discover(root: root))
        let ambiguous = try engine.applyProvided([ProvidedTranslation(key: "common.cancel", locale: "de", value: "Abbrechen")])
        #expect(ambiguous.translated == 0)
        #expect(ambiguous.failed.first?.reason.contains("several catalogs") == true)
        let explicit = try engine.applyProvided([ProvidedTranslation(catalog: "AppB/Localizable.xcstrings", key: "common.cancel", locale: "de", value: "Abbrechen")])
        #expect(explicit.translated == 1)
        #expect(try StringCatalog.load(root.appendingPathComponent("AppB/Localizable.xcstrings")).entry("common.cancel")?.localization("de") != nil)
        #expect(try StringCatalog.load(root.appendingPathComponent("AppA/Localizable.xcstrings")).entry("common.cancel")?.localization("de") == nil)
    }

    @Test func textKeysStillUsedElsewhereStayLive() throws {
        let root = try TestSupport.makeProject([
            ".l10n-agent.yml": "codeStyle: literal\n",
            "App/Localizable.xcstrings": TestSupport.catalogJSON(["Welcome back": ["localizations": ["de": TestSupport.unit("Willkommen zurück")]]]),
            "App/HomeView.swift": "import SwiftUI\nstruct HomeView: View { var body: some View { Text(\"Welcome back\") } }\n",
            "App/LoginView.swift": "import SwiftUI\nstruct LoginView: View { var body: some View { Text(\"Welcome back\") } }\n",
        ])
        let project = try Project.discover(root: root)
        let partial = try Fixer(project: project).apply(try Fixer(project: project).plan(files: ["App/HomeView.swift"]))
        #expect(partial.applied.count == 1)
        #expect(try StringCatalog.load(root.appendingPathComponent("App/Localizable.xcstrings")).entry("Welcome back")?.isStale == false)

        let rest = try Project.discover(root: root)
        _ = try Fixer(project: rest).apply(try Fixer(project: rest).plan(files: ["App/LoginView.swift"]))
        #expect(try StringCatalog.load(root.appendingPathComponent("App/Localizable.xcstrings")).entry("Welcome back")?.isStale == true)
    }

    @Test func brokenFingerprintsStopApplyBeforeAnySourceWrite() throws {
        let root = try TestSupport.makeProject([
            ".l10n-agent.yml": "codeStyle: literal\n",
            ".l10n-agent/fingerprints.json": "<<<<<<< HEAD\n{}\n=======\n{}\n>>>>>>> branch\n",
            "App/Localizable.xcstrings": TestSupport.catalogJSON([:]),
            "App/View.swift": "func f() { label.text = \"Hello there\" }\n",
        ])
        let project = try Project.discover(root: root)
        let plan = try Fixer(project: project).plan()
        #expect(throws: (any Error).self) { try Fixer(project: project).apply(plan) }
        #expect(try String(contentsOf: root.appendingPathComponent("App/View.swift"), encoding: .utf8) == "func f() { label.text = \"Hello there\" }\n")
    }

    @Test func symbolGenerationIsResolvedPerProjectAndTarget() throws {
        let enabled = "STRING_CATALOG_GENERATE_SYMBOLS = YES;\n"
        let root = try TestSupport.makeProject([
            "A/AppA.xcodeproj/project.pbxproj": enabled,
            "A/Localizable.xcstrings": TestSupport.catalogJSON([:]),
            "A/View.swift": "func f() { label.text = \"Hello from A\" }\n",
            "B/AppB.xcodeproj/project.pbxproj": enabled + "STRING_CATALOG_GENERATE_SYMBOLS = NO;\n",
            "B/Localizable.xcstrings": TestSupport.catalogJSON([:]),
            "B/View.swift": "func f() { label.text = \"Hello from B\" }\n",
            "A/Packages/Kit/Package.swift": "// swift-tools-version: 6.0\n",
            "A/Packages/Kit/Sources/Kit/K.swift": "func f() { label.text = \"Hello from Kit\" }\n",
        ])
        let project = try Project.discover(root: root)
        #expect(project.xcode.symbolGeneration(for: root.appendingPathComponent("B/View.swift")) == .mixed)
        let plan = try Fixer(project: project).plan()
        #expect(plan.codeStyle == "mixed")
        func replacement(_ prefix: String) -> String { plan.items.first { $0.file.hasPrefix(prefix) }?.replacement ?? "" }
        #expect(replacement("A/View.swift").hasPrefix("String(localized: ."), "A generates symbols")
        #expect(replacement("B/").contains("defaultValue:"), "B is mixed, so literals")
        #expect(replacement("A/Packages/").contains("bundle: .module"), "package targets use literals")
        #expect(try Fixer(project: project).apply(plan).applied.count == 3)
    }

    @Test func initHoldsTheProjectLock() async throws {
        let root = try TestSupport.makeProject(["App/Localizable.xcstrings": TestSupport.catalogJSON([:])])
        let lock = try ProjectLock.acquire(root: root)
        await #expect(throws: L10nError.self) { _ = try await InitCommand.run(root: root, model: "none") }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(L10nConfig.fileName).path))
        lock.release()
        let result = try await InitCommand.run(root: root, model: "none")
        #expect(result.createdConfig)
    }

    @Test func dynamicWidthsCountAsArguments() throws {
        #expect(FormatSpecifier.argumentSignature(of: "%*d items") == [1: .integer, 2: .integer])
        #expect(FormatSpecifier.argumentSignature(of: "%@ %.*f") == [1: .object, 2: .integer, 3: .double])
        #expect(FormatParity.problem(source: "%*d items", target: "%d Elemente") != nil)
        #expect(FormatParity.problem(source: "%*d items", target: "%*d Elemente") == nil)
        // The width consumes argument 2, so the value is ⟦3⟧.
        let masked = MaskedText(source: "%@ scored %*d points")
        #expect(masked.text == "⟦1⟧ scored ⟦3⟧ points")
        #expect(try masked.unmask("⟦1⟧ hat ⟦3⟧ Punkte") == "%@ hat %*d Punkte")
        #expect(throws: MaskedText.UnmaskError.self) { try masked.unmask("⟦3⟧ Punkte für ⟦1⟧") }
    }

    @Test func onlyDebugOnlyConditionsAreSkipped() {
        let sites = SwiftScanner().scan(source: """
        func f() {
            #if DEBUG || os(iOS)
            label.text = "Shipping text one"
            #endif
            #if DEBUG && TRACE
            label.text = "Debug text one"
            #endif
            #if (DEBUG)
            label.text = "Debug text two"
            #endif
            #if !DEBUG
            label.text = "Shipping text two"
            #endif
            #if FEATURE || DEBUG
            label.text = "Shipping text three"
            #endif
        }
        """, path: "App/F.swift")
        #expect(Set(sites.map(\.displayText)) == ["Shipping text one", "Shipping text two", "Shipping text three"])
    }

    @Test func secretScanChecksStagedBlobs() throws {
        let repo = FileManager.default.temporaryDirectory.appendingPathComponent("scan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("scripts"), withIntermediateDirectories: true)
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/secret-scan.sh")
        try FileManager.default.copyItem(at: script, to: repo.appendingPathComponent("scripts/secret-scan.sh"))
        #expect(TestSupport.shell(["git", "init", "-q"], cwd: repo).0 == 0)
        let fakeKey = "AK" + "IA" + String(repeating: "Q", count: 16)   // built at runtime so this file stays clean
        let file = repo.appendingPathComponent("config.txt")
        try "key=\(fakeKey)\n".write(to: file, atomically: true, encoding: .utf8)
        #expect(TestSupport.shell(["git", "add", "config.txt"], cwd: repo).0 == 0)
        try "key=removed\n".write(to: file, atomically: true, encoding: .utf8)   // cleaned only in the working copy
        let (status, output) = TestSupport.shell(["bash", "scripts/secret-scan.sh"], cwd: repo)
        #expect(status != 0)
        #expect(output.contains("config.txt (staged)"))

        // A secret at the start of a large staged blob must not be hidden by SIGPIPE.
        let big = repo.appendingPathComponent("big.txt")
        try ("key=\(fakeKey)\n" + String(repeating: "filler line of text\n", count: 200_000)).write(to: big, atomically: true, encoding: .utf8)
        #expect(TestSupport.shell(["git", "add", "big.txt"], cwd: repo).0 == 0)
        try "clean\n".write(to: big, atomically: true, encoding: .utf8)
        let (_, bigOutput) = TestSupport.shell(["bash", "scripts/secret-scan.sh"], cwd: repo)
        #expect(bigOutput.contains("big.txt (staged)"))

        // Binary blobs (with NUL bytes) are scanned too.
        var binary = Data([0x00, 0x01, 0x02, 0x00])
        binary.append(Data(fakeKey.utf8))
        binary.append(Data([0x00, 0xFF]))
        try binary.write(to: repo.appendingPathComponent("blob.bin"))
        #expect(TestSupport.shell(["git", "add", "blob.bin"], cwd: repo).0 == 0)
        let (_, binaryOutput) = TestSupport.shell(["bash", "scripts/secret-scan.sh"], cwd: repo)
        #expect(binaryOutput.contains("blob.bin (staged)"))
    }

    @Test func siblingResourceCatalogsResolveThroughTheOwningProject() throws {
        let root = try TestSupport.makeProject([
            "AppA/AppA.xcodeproj/project.pbxproj": "// stub\n",
            "AppA/Resources/Localizable.xcstrings": TestSupport.catalogJSON(["a.title": TestSupport.manual("A")]),
            "AppA/Sources/View.swift": "import SwiftUI\nstruct V: View { var body: some View { VStack { Text(\"a.title\"); Text(\"b.title\") } } }\n",
            "AppB/AppB.xcodeproj/project.pbxproj": "// stub\n",
            "AppB/Resources/Localizable.xcstrings": TestSupport.catalogJSON(["b.title": TestSupport.manual("B")]),
        ])
        let project = try Project.discover(root: root)
        #expect(project.catalogURLs(forTable: "Localizable", file: root.appendingPathComponent("AppA/Sources/View.swift")).map(project.relativePath) == ["AppA/Resources/Localizable.xcstrings"])
        let report = try Linter(project: project).run(LintOptions(rules: ["L10N004"]))
        #expect(report.diagnostics.map(\.key) == ["b.title"])
    }

    @Test func symbolCollisionsOnlyMatterWhereSymbolsAreGenerated() throws {
        let colliding = TestSupport.catalogJSON(["dup.x": TestSupport.manual("One"), "dupX": TestSupport.manual("Two")])
        let root = try TestSupport.makeProject([
            "App.xcodeproj/project.pbxproj": "STRING_CATALOG_GENERATE_SYMBOLS = YES;\n",
            "App/Localizable.xcstrings": colliding,
            "Packages/Kit/Package.swift": "// swift-tools-version: 6.0\n",
            "Packages/Kit/Sources/Kit/Localizable.xcstrings": colliding,
        ])
        let report = try Linter(project: try Project.discover(root: root)).run(LintOptions(rules: ["L10N110"]))
        #expect(Set(report.diagnostics.map(\.file)) == ["App/Localizable.xcstrings"])
    }

    @Test func providedFormsFillCategoriesBesideApprovedOnes() throws {
        let root = try TestSupport.makeProject([
            ".l10n-agent.yml": "locales: [de]\n",
            "L.xcstrings": TestSupport.catalogJSON([
                "files": [
                    "extractionState": "manual", "comment": "c",
                    "localizations": [
                        "en": ["variations": ["plural": ["one": TestSupport.unit("%lld file"), "other": TestSupport.unit("%lld files")]]],
                        "de": ["variations": ["plural": ["one": TestSupport.unit("%lld Datei")]]],
                    ],
                ],
            ]),
        ])
        let report = try TranslationEngine(project: try Project.discover(root: root)).applyProvided([
            ProvidedTranslation(key: "files", locale: "de", forms: ["one": "Eine Datei überschrieben", "other": "%lld Dateien"]),
        ])
        #expect(report.translated == 1, "\(report.failed)")
        let de = try #require(try StringCatalog.load(root.appendingPathComponent("L.xcstrings")).entry("files")?.localization("de"))
        let byCategory = Dictionary(uniqueKeysWithValues: de.leaves.map { ($0.path.last!, $0.unit) })
        #expect(byCategory["one"] == StringUnit(state: "translated", value: "%lld Datei"), "approved form untouched")
        #expect(byCategory["other"] == StringUnit(state: "needs_review", value: "%lld Dateien"))
    }

    @Test func spaceFlagIsASpecifierButProseIsNot() {
        #expect(FormatSpecifier.argumentSignature(of: "% d items") == [1: .integer])
        #expect(FormatParity.problem(source: "% d items", target: "Elemente") != nil)
        #expect(FormatSpecifier.argumentSignature(of: "100% discount").isEmpty)
        #expect(FormatSpecifier.argumentSignature(of: "Save 50% off today").isEmpty)
    }

    @Test func symbolConstraintsOnlyApplyToSymbolRewrites() throws {
        let root = try TestSupport.makeProject([
            "App.xcodeproj/project.pbxproj": "STRING_CATALOG_GENERATE_SYMBOLS = YES;\n",
            "App/Localizable.xcstrings": TestSupport.catalogJSON([:]),
            "Packages/Kit/Package.swift": "// swift-tools-version: 6.0\n",
            "Packages/Kit/Sources/Kit/Localizable.xcstrings": TestSupport.catalogJSON(["kit.dup.x": TestSupport.manual("Other text")]),
            "Packages/Kit/Sources/Kit/K.swift": "func f() { label.text = \"Dup text\" }\n",
        ])
        let project = try Project.discover(root: root)
        var plan = try Fixer(project: project).plan()
        // "kit.dupX" collides with "kit.dup.x" only as a generated symbol; the package uses literals.
        plan.items[0].key = "kit.dupX"
        let result = try Fixer(project: project).apply(plan)
        #expect(result.applied.count == 1, "\(result.skipped)")
        #expect(try String(contentsOf: root.appendingPathComponent("Packages/Kit/Sources/Kit/K.swift"), encoding: .utf8).contains(#"String(localized: "kit.dupX""#))
    }

    @Test func pluralFormsAreRestoredAgainstTheirOwnSourceForm() async throws {
        let source: [String: Any] = ["extractionState": "manual", "comment": "c", "localizations": ["en": ["variations": ["plural": [
            "one": TestSupport.unit("One file from %@"),
            "other": TestSupport.unit("%lld files"),
        ]]]]]
        let root = try TestSupport.makeProject([".l10n-agent.yml": "locales: [de]\n", "L.xcstrings": TestSupport.catalogJSON(["files": source])])
        let model = ScriptedChatModel { _, _ in
            #"{"translations":[{"id":"1","forms":{"one":"Eine Datei von ⟦1⟧","other":"⟦1⟧ Dateien"}}]}"#
        }
        let report = try await TranslationEngine(project: try Project.discover(root: root)).run(TranslateOptions(), model: model)
        #expect(report.translated == 1, "\(report.failed)")
        let de = try #require(try StringCatalog.load(root.appendingPathComponent("L.xcstrings")).entry("files")?.localization("de"))
        let byCategory = Dictionary(uniqueKeysWithValues: de.leaves.map { ($0.path.last!, $0.unit.value) })
        #expect(byCategory["one"] == "Eine Datei von %@")
        #expect(byCategory["other"] == "%lld Dateien")
    }

    @Test func parserRejectsNonJSONNumbers() throws {
        for literal in ["+1", "01", "1.", ".5", "1e", "--1", "0x10"] {
            #expect(throws: JSONParseError.self, "\(literal)") { try JSONParser.parse("{\"n\":\(literal)}") }
        }
        for literal in ["0", "-0", "12", "-0.5e10", "1E+2", "3.25"] {
            #expect(try JSONParser.parse("{\"n\":\(literal)}")["n"] == .number(literal))
        }
    }

    @Test func typedLocalizedDeclarationsGetTypeCorrectRewrites() throws {
        let source = """
        import SwiftUI
        struct HomeView {
            let title: LocalizedStringResource = "Welcome home"
            var subtitle: LocalizedStringResource { "Good to see you" }
            let key: LocalizedStringKey = "Plain key text"
        }
        """
        let literal = try TestSupport.makeProject([".l10n-agent.yml": "codeStyle: literal\n", "App/Localizable.xcstrings": TestSupport.catalogJSON([:]), "App/HomeView.swift": source])
        let literalPlan = try Fixer(project: try Project.discover(root: literal)).plan()
        func item(_ plan: FixPlan, _ text: String) -> FixItem? { plan.items.first { $0.sourceValue == text } }
        #expect(item(literalPlan, "Welcome home")?.replacement.hasPrefix("LocalizedStringResource(\"home.") == true)
        #expect(item(literalPlan, "Plain key text")?.status == .skipped)

        let symbols = try TestSupport.makeProject([".l10n-agent.yml": "codeStyle: symbols\n", "App/Localizable.xcstrings": TestSupport.catalogJSON([:]), "App/HomeView.swift": source])
        let symbolPlan = try Fixer(project: try Project.discover(root: symbols)).plan()
        #expect(item(symbolPlan, "Welcome home")?.replacement.hasPrefix(".home") == true)
        #expect(item(symbolPlan, "Good to see you")?.replacement.hasPrefix(".home") == true)

        // The literal-style rewrite type-checks.
        let project = try Project.discover(root: literal)
        _ = try Fixer(project: project).apply(literalPlan)
        if TestSupport.hasXcstringstool {
            let file = literal.appendingPathComponent("App/HomeView.swift").path
            let (status, output) = TestSupport.shell(["xcrun", "--sdk", "macosx", "swiftc", "-typecheck", "-target", "arm64-apple-macos14", file])
            #expect(status == 0, "\(output)")
        }
    }

    @Test func keyLookupsAndFingerprintsAreByteExact() throws {
        let precomposed = "caf\u{E9}.title"
        let decomposed = "cafe\u{301}.title"
        #expect(precomposed == decomposed, "Swift considers them equal")
        let root = try TestSupport.makeProject([
            ".l10n-agent.yml": "locales: [de]\n",
            "App/Localizable.xcstrings": TestSupport.catalogJSON([
                precomposed: TestSupport.manual("Cafe", translations: ["de": TestSupport.unit("Café")]),
            ]),
            "App/View.swift": "import SwiftUI\nstruct V: View { var body: some View { Text(\"cafe\\u{301}.title\") } }\n",
        ])
        let lint = try Linter(project: try Project.discover(root: root)).run(LintOptions(rules: ["L10N004"]))
        #expect(lint.diagnostics.count == 1, "the decomposed key is not in the catalog")

        var store = try FingerprintStore.load(root: root)
        store.set(catalog: "App/Localizable.xcstrings", key: precomposed, locale: "de", fingerprint: "aaa")
        store.set(catalog: "App/Localizable.xcstrings", key: decomposed, locale: "de", fingerprint: "bbb")
        try store.save()
        let loaded = try FingerprintStore.load(root: root)
        #expect(loaded.fingerprint(catalog: "App/Localizable.xcstrings", key: precomposed, locale: "de") == "aaa")
        #expect(loaded.fingerprint(catalog: "App/Localizable.xcstrings", key: decomposed, locale: "de") == "bbb")
    }

    @Test func initPinsACatalogOnlyWhenUnambiguous() async throws {
        let many = try TestSupport.makeProject([
            "AppA/Localizable.xcstrings": TestSupport.catalogJSON([:]),
            "AppB/Localizable.xcstrings": TestSupport.catalogJSON([:]),
        ])
        _ = try await InitCommand.run(root: many, model: "none")
        #expect(try Project.discover(root: many).config.catalog == nil)

        let one = try TestSupport.makeProject(["App/Localizable.xcstrings": TestSupport.catalogJSON([:])])
        _ = try await InitCommand.run(root: one, model: "none")
        #expect(try Project.discover(root: one).config.catalog == "App/Localizable.xcstrings")
    }

    @Test func blankCatalogsAreReportedNotReplaced() throws {
        let root = try TestSupport.makeProject(["App/Localizable.xcstrings": "  \n"])
        #expect(throws: L10nError.self) { try StringCatalog.load(root.appendingPathComponent("App/Localizable.xcstrings")) }
        let report = try Linter(project: try Project.discover(root: root)).run()
        #expect(report.diagnostics.map(\.rule) == ["L10N100"])
    }

    @Test func rootUnitIsPlannedBesideApprovedSubstitutionForms() async throws {
        let root = try TestSupport.makeProject([
            ".l10n-agent.yml": "locales: [de]\n",
            "L.xcstrings": TestSupport.catalogJSON([
                "files.left": [
                    "extractionState": "manual", "comment": "c",
                    "localizations": [
                        "en": [
                            "stringUnit": ["state": "translated", "value": "%#@files@ left"],
                            "substitutions": ["files": ["argNum": 1, "formatSpecifier": "lld", "variations": ["plural": ["one": TestSupport.unit("%arg file"), "other": TestSupport.unit("%arg files")]]]],
                        ],
                        "de": [
                            "substitutions": ["files": ["argNum": 1, "formatSpecifier": "lld", "variations": ["plural": ["one": TestSupport.unit("%arg Datei"), "other": TestSupport.unit("%arg Dateien")]]]],
                        ],
                    ],
                ],
            ]),
        ])
        let report = try await TranslationEngine(project: try Project.discover(root: root)).run(TranslateOptions(dryRun: true), model: nil)
        #expect(report.units?.map(\.path) == [[]], "the missing root string is planned")
        #expect(report.approvedSkipped.isEmpty)
    }

    @Test func translateKeyFilterIsByteExact() async throws {
        let precomposed = "caf\u{E9}.title"
        let decomposed = "cafe\u{301}.title"
        let root = try TestSupport.makeProject([
            ".l10n-agent.yml": "locales: [de]\n",
            // Swift dictionaries merge the two spellings, so write the catalog as raw JSON.
            "L.xcstrings": "{\"sourceLanguage\":\"en\",\"version\":\"1.1\",\"strings\":{"
                + "\"\(precomposed)\":{\"comment\":\"c\",\"extractionState\":\"manual\",\"localizations\":{\"en\":{\"stringUnit\":{\"state\":\"translated\",\"value\":\"One\"}}}},"
                + "\"\(decomposed)\":{\"comment\":\"c\",\"extractionState\":\"manual\",\"localizations\":{\"en\":{\"stringUnit\":{\"state\":\"translated\",\"value\":\"Two\"}}}}}}",
        ])
        let report = try await TranslationEngine(project: try Project.discover(root: root)).run(TranslateOptions(keys: [decomposed], dryRun: true), model: nil)
        #expect(report.units?.count == 1)
        #expect(report.units?.first?.source == "Two")
    }

    @Test func migrationMergesMissingLeavesIntoAnExistingLocalization() throws {
        let plural: (String, String, String) -> [String: Any] = { one, other, state in
            ["variations": ["plural": ["one": TestSupport.unit(one, state: state), "other": TestSupport.unit(other, state: state)]]]
        }
        var existing = TestSupport.manual("%lld files")
        existing["localizations"] = [
            "en": ["stringUnit": ["state": "translated", "value": "%lld files"]],
            "de": ["variations": ["plural": ["one": TestSupport.unit("%lld Datei (neu)")]]],
        ]
        let root = try TestSupport.makeProject([
            ".l10n-agent.yml": "codeStyle: literal\nlocales: [de]\n",
            "App/Localizable.xcstrings": TestSupport.catalogJSON([
                "home.files": existing,
                "%lld files": ["localizations": ["de": plural("%lld Datei", "%lld Dateien", "translated")]],
            ]),
            "App/HomeView.swift": "import SwiftUI\nstruct HomeView: View { let count = 2; var body: some View { Text(\"\\(count) files\") } }\n",
        ])
        let project = try Project.discover(root: root)
        var plan = try Fixer(project: project).plan()
        let index = try #require(plan.items.firstIndex { $0.sourceValue == "%lld files" })
        #expect(plan.items[index].key == "home.files")
        plan.items[index].status = .ready
        _ = try Fixer(project: project).apply(plan)
        let de = try #require(try StringCatalog.load(root.appendingPathComponent("App/Localizable.xcstrings")).entry("home.files")?.localization("de"))
        let byCategory = Dictionary(uniqueKeysWithValues: de.leaves.map { ($0.path.last!, $0.unit.value) })
        #expect(byCategory["one"] == "%lld Datei (neu)", "existing leaf kept")
        #expect(byCategory["other"] == "%lld Dateien", "missing leaf merged from the text key")
    }

    @Test func initRefusesMalformedCatalogsBeforeWriting() async throws {
        let root = try TestSupport.makeProject(["App/Localizable.xcstrings": "{ broken"])
        await #expect(throws: L10nError.self) { _ = try await InitCommand.run(root: root, model: "none") }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(L10nConfig.fileName).path))
    }

    @Test func providedFormsKeepStalenessOfApprovedNeighbors() throws {
        let catalogPath = "L.xcstrings"
        let root = try TestSupport.makeProject([
            ".l10n-agent.yml": "locales: [de]\n",
            catalogPath: TestSupport.catalogJSON([
                "files": [
                    "extractionState": "manual", "comment": "c",
                    "localizations": [
                        "en": ["variations": ["plural": ["one": TestSupport.unit("%lld file"), "other": TestSupport.unit("%lld files")]]],
                        "de": ["variations": ["plural": ["one": TestSupport.unit("%lld Datei")]]],
                    ],
                ],
            ]),
        ])
        _ = try TranslationEngine(project: try Project.discover(root: root)).accept(keys: nil, locales: nil)
        // The source changes after "one" was approved.
        var catalog = try StringCatalog.load(root.appendingPathComponent(catalogPath))
        var entry = catalog.entry("files")!
        var en = entry.localization("en")!
        en.setUnit(StringUnit(state: "translated", value: "%lld document"), at: ["variations", "plural", "one"])
        entry.setLocalization("en", en)
        catalog.setEntry("files", entry)
        try catalog.write()

        let report = try TranslationEngine(project: try Project.discover(root: root)).applyProvided([
            ProvidedTranslation(key: "files", locale: "de", forms: ["other": "%lld Dateien"]),
        ])
        #expect(report.translated == 1)
        let stale = try Linter(project: try Project.discover(root: root)).run(LintOptions(rules: ["L10N103"]))
        #expect(stale.diagnostics.first?.key == "files", "the approved form was not reviewed against the new source")
    }

    @Test func plannedAssignmentsAreByteExact() throws {
        let precomposed = "caf\u{E9}.title"
        let decomposed = "cafe\u{301}.title"
        let root = try TestSupport.makeProject([
            ".l10n-agent.yml": "codeStyle: literal\n",
            "App/Localizable.xcstrings": "{\"sourceLanguage\":\"en\",\"version\":\"1.1\",\"strings\":{"
                + "\"\(precomposed)\":{\"comment\":\"c\",\"extractionState\":\"manual\",\"localizations\":{\"en\":{\"stringUnit\":{\"state\":\"translated\",\"value\":\"Coffee time\"}}}},"
                + "\"\(decomposed)\":{\"comment\":\"c\",\"extractionState\":\"manual\",\"localizations\":{\"en\":{\"stringUnit\":{\"state\":\"translated\",\"value\":\"Tea time\"}}}}}}",
            "App/View.swift": "func f() { a.text = \"Coffee time\"; b.text = \"Tea time\" }\n",
        ])
        let project = try Project.discover(root: root)
        var plan = try Fixer(project: project).plan()
        let coffee = try #require(plan.items.firstIndex { $0.sourceValue == "Coffee time" })
        let tea = try #require(plan.items.firstIndex { $0.sourceValue == "Tea time" })
        plan.items[coffee].key = precomposed
        plan.items[tea].key = decomposed
        let result = try Fixer(project: project).apply(plan)
        #expect(result.applied.count == 2, "\(result.skipped)")
    }

    @Test func initLeavesLocalesUnsetWhenNoneAreDetected() async throws {
        let root = try TestSupport.makeProject(["App/Localizable.xcstrings": TestSupport.catalogJSON([:])])
        _ = try await InitCommand.run(root: root, model: "none")
        #expect(try Project.discover(root: root).config.locales == nil)
    }

    @Test func siblingCatalogsInASharedProjectResolvePerTarget() throws {
        let root = try TestSupport.makeProject([
            "App.xcodeproj/project.pbxproj": "// stub\n",
            "FeatureA/Resources/Localizable.xcstrings": TestSupport.catalogJSON(["a.title": TestSupport.manual("A")]),
            "FeatureA/Sources/View.swift": "import SwiftUI\nstruct V: View { var body: some View { VStack { Text(\"a.title\"); Text(\"b.title\") } } }\n",
            "FeatureB/Resources/Localizable.xcstrings": TestSupport.catalogJSON(["b.title": TestSupport.manual("B")]),
        ])
        let project = try Project.discover(root: root)
        #expect(project.catalogURLs(forTable: "Localizable", file: root.appendingPathComponent("FeatureA/Sources/View.swift")).map(project.relativePath) == ["FeatureA/Resources/Localizable.xcstrings"])
        #expect(try Linter(project: project).run(LintOptions(rules: ["L10N004"])).diagnostics.map(\.key) == ["b.title"])
    }

    @Test func malformedFingerprintStoresAreRejected() throws {
        for content in ["[]", "{}", #"{"catalogs":[],"version":1}"#, #"{"catalogs":{},"version":2}"#, #"{"catalogs":{"L.xcstrings":{"k":{"de":1}}},"version":1}"#] {
            let root = try TestSupport.makeProject([".l10n-agent/fingerprints.json": content])
            #expect(throws: L10nError.self, "\(content)") { try FingerprintStore.load(root: root) }
        }
        let valid = try TestSupport.makeProject([".l10n-agent/fingerprints.json": #"{"catalogs":{"L.xcstrings":{"k":{"de":"abc"}}},"version":1}"#])
        #expect(try FingerprintStore.load(root: valid).fingerprint(catalog: "L.xcstrings", key: "k", locale: "de") == "abc")
    }

    @Test func discoveryIgnoresSymlinksThatLeaveTheProject() throws {
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try "func f() { label.text = \"Private text\" }\n".write(to: outside.appendingPathComponent("Secret.swift"), atomically: true, encoding: .utf8)
        try TestSupport.catalogJSON([:]).write(to: outside.appendingPathComponent("Other.xcstrings"), atomically: true, encoding: .utf8)
        let root = try TestSupport.makeProject(["App/View.swift": "func f() { label.text = \"Inside text\" }\n"])
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("App/Leak.swift"), withDestinationURL: outside.appendingPathComponent("Secret.swift"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("App/Leak.xcstrings"), withDestinationURL: outside.appendingPathComponent("Other.xcstrings"))
        let project = try Project.discover(root: root)
        #expect(project.swiftFiles.map(project.relativePath) == ["App/View.swift"])
        #expect(project.catalogURLs.isEmpty)
    }

    @Test func migrationKeepsSourceLanguageVariations() throws {
        let root = try TestSupport.makeProject([
            ".l10n-agent.yml": "codeStyle: literal\n",
            "App/Localizable.xcstrings": TestSupport.catalogJSON([
                "%lld items": ["localizations": [
                    "en": ["variations": ["plural": ["one": TestSupport.unit("One item"), "other": TestSupport.unit("%lld items")]]],
                    "de": ["variations": ["plural": ["one": TestSupport.unit("Ein Element"), "other": TestSupport.unit("%lld Elemente")]]],
                ]],
            ]),
            "App/HomeView.swift": "import SwiftUI\nstruct HomeView: View { let count = 2; var body: some View { Text(\"\\(count) items\") } }\n",
        ])
        let project = try Project.discover(root: root)
        var plan = try Fixer(project: project).plan()
        plan.items[0].status = .ready
        _ = try Fixer(project: project).apply(plan)
        let entry = try #require(try StringCatalog.load(root.appendingPathComponent("App/Localizable.xcstrings")).entry(plan.items[0].key))
        let en = Dictionary(uniqueKeysWithValues: (entry.localization("en")?.leaves ?? []).map { ($0.path.last ?? "", $0.unit.value) })
        #expect(en["one"] == "One item")
        #expect(en["other"] == "%lld items")
    }

    @Test func addKeysRejectsAmbiguousCatalogs() throws {
        let root = try TestSupport.makeProject([
            "AppA/Localizable.xcstrings": TestSupport.catalogJSON([:]),
            "AppB/Localizable.xcstrings": TestSupport.catalogJSON([:]),
        ])
        let project = try Project.discover(root: root)
        let result = try AddKeysCommand.run(project: project, keys: [NewKey(key: "home.title", value: "Home")])
        #expect(result.added.isEmpty)
        #expect(result.rejected["home.title"]?.contains("set catalog") == true)
        let explicit = try AddKeysCommand.run(project: project, keys: [NewKey(key: "home.title", value: "Home", catalog: "AppB/Localizable.xcstrings")])
        #expect(explicit.added == ["home.title"])
    }

    @Test func splitSourcesAndResourcesAreMatchedByFolderNameOrRoutes() throws {
        let root = try TestSupport.makeProject([
            "App.xcodeproj/project.pbxproj": "// stub\n",
            "Sources/FeatureA/View.swift": "func f() { label.text = \"Feature A text\" }\n",
            "Resources/FeatureA/Localizable.xcstrings": TestSupport.catalogJSON([:]),
            "Resources/FeatureB/Localizable.xcstrings": TestSupport.catalogJSON([:]),
            "Sources/Shared/Util.swift": "func g() { label.text = \"Shared text\" }\n",
        ])
        let project = try Project.discover(root: root)
        let file = root.appendingPathComponent("Sources/FeatureA/View.swift")
        #expect(project.catalogURLs(forTable: "Localizable", file: file).map(project.relativePath) == ["Resources/FeatureA/Localizable.xcstrings"])

        // Sources/Shared matches neither feature: fix skips it instead of guessing.
        let plan = try Fixer(project: project).plan()
        #expect(plan.items.first { $0.file == "Sources/Shared/Util.swift" }?.reason?.contains("catalogRoutes") == true)

        try "catalogRoutes:\n  - files: \"Sources/Shared/**\"\n    catalog: \"Resources/FeatureB/Localizable.xcstrings\"\n".write(to: root.appendingPathComponent(L10nConfig.fileName), atomically: true, encoding: .utf8)
        let routed = try Fixer(project: try Project.discover(root: root)).plan()
        #expect(routed.items.first { $0.file == "Sources/Shared/Util.swift" }?.catalog == "Resources/FeatureB/Localizable.xcstrings")
    }

    @Test func byteDistinctKeysGetTheirOwnFingerprints() async throws {
        let precomposed = "caf\u{E9}.title"
        let decomposed = "cafe\u{301}.title"
        let root = try TestSupport.makeProject([
            ".l10n-agent.yml": "locales: [de]\n",
            "L.xcstrings": "{\"sourceLanguage\":\"en\",\"version\":\"1.1\",\"strings\":{"
                + "\"\(precomposed)\":{\"comment\":\"c\",\"extractionState\":\"manual\",\"localizations\":{\"en\":{\"stringUnit\":{\"state\":\"translated\",\"value\":\"One\"}}}},"
                + "\"\(decomposed)\":{\"comment\":\"c\",\"extractionState\":\"manual\",\"localizations\":{\"en\":{\"stringUnit\":{\"state\":\"translated\",\"value\":\"Two\"}}}}}}",
        ])
        let report = try await TranslationEngine(project: try Project.discover(root: root)).run(TranslateOptions(batchSize: 1), model: EchoTranslator(transform: { _, text in "DE " + text }).model())
        #expect(report.translated == 2)
        let store = try FingerprintStore.load(root: root)
        #expect(store.fingerprint(catalog: "L.xcstrings", key: precomposed, locale: "de") != nil)
        #expect(store.fingerprint(catalog: "L.xcstrings", key: decomposed, locale: "de") != nil)
    }

    @Test func concatenationsInsideCallsWithOtherArgumentsAreNotRewritten() {
        let sites = SwiftScanner().scan(source: """
        import SwiftUI
        struct V: View { var body: some View { VStack {
            Text("Hello there " + name, tableName: "Settings")
            Text("Welcome back " + name)
        } } }
        """, path: "App/V.swift")
        let named = sites.first { $0.displayText.hasPrefix("Hello there") }
        let plain = sites.first { $0.displayText.hasPrefix("Welcome back") }
        #expect(named?.kind == .concatenation)
        #expect(named?.fixable == false)
        #expect(plain?.fixable == true)
    }

    @Test func colocatedProjectsDoNotDecideSymbolGeneration() throws {
        let root = try TestSupport.makeProject([
            "AppA.xcodeproj/project.pbxproj": "STRING_CATALOG_GENERATE_SYMBOLS = YES;\n",
            "AppB.xcodeproj/project.pbxproj": "// symbols off\n",
            "Localizable.xcstrings": TestSupport.catalogJSON([:]),
            "Shared/View.swift": "func f() { label.text = \"Shared title\" }\n",
        ])
        let project = try Project.discover(root: root)
        let file = root.appendingPathComponent("Shared/View.swift")
        #expect(project.xcode.owningProject(for: file) == nil)
        #expect(!project.usesSymbols(for: file))
        #expect(try Fixer(project: project).plan().items.first?.replacement.contains("defaultValue:") == true)
    }

    @Test func substitutionMetadataCountsForStalenessAndParity() throws {
        func node(argNum: Int, specifier: String) -> LocalizationNode {
            var node = LocalizationNode(unit: StringUnit(state: "translated", value: "%#@n@ left"))
            node.setValue(.number(String(argNum)), at: ["substitutions", "n", "argNum"])
            node.setValue(.string(specifier), at: ["substitutions", "n", "formatSpecifier"])
            node.setUnit(StringUnit(state: "translated", value: "%arg left"), at: ["substitutions", "n", "variations", "plural", "other"])
            return node
        }
        #expect(FingerprintStore.sourceFingerprint(node(argNum: 1, specifier: "lld")) != FingerprintStore.sourceFingerprint(node(argNum: 2, specifier: "lld")))
        #expect(FingerprintStore.sourceFingerprint(LocalizationNode(unit: StringUnit(state: "translated", value: "Hi"))) == Hashing.shortHash("=Hi"), "plain strings keep their fingerprint")

        let root = try TestSupport.makeProject([
            ".l10n-agent.yml": "locales: [de]\n",
            "L.xcstrings": TestSupport.catalogJSON(["left": [
                "extractionState": "manual", "comment": "c",
                "localizations": [
                    "en": ["stringUnit": ["state": "translated", "value": "%#@n@ left"], "substitutions": ["n": ["argNum": 2, "formatSpecifier": "lld", "variations": ["plural": ["one": TestSupport.unit("%arg item"), "other": TestSupport.unit("%arg items")]]]]],
                    "de": ["stringUnit": ["state": "translated", "value": "noch %#@n@"], "substitutions": ["n": ["argNum": 1, "formatSpecifier": "lld", "variations": ["plural": ["one": TestSupport.unit("%arg Element"), "other": TestSupport.unit("%arg Elemente")]]]]],
                ],
            ]]),
        ])
        let lint = try Linter(project: try Project.discover(root: root)).run(LintOptions(rules: ["L10N104"]))
        #expect(lint.diagnostics.first?.message.contains("substitution %#@n@") == true)
    }

    @Test func languageSpecificVariationsCountAsComplete() async throws {
        let source = TestSupport.manual("%lld files")
        func project(_ de: [String: Any]) throws -> Project {
            var entry = source
            var localizations = entry["localizations"] as! [String: Any]
            localizations["de"] = de
            entry["localizations"] = localizations
            return try Project.discover(root: try TestSupport.makeProject([".l10n-agent.yml": "locales: [de]\n", "L.xcstrings": TestSupport.catalogJSON(["files": entry])]))
        }
        let complete = try project(["variations": ["plural": ["one": TestSupport.unit("%lld Datei"), "other": TestSupport.unit("%lld Dateien")]]])
        #expect(try Linter(project: complete).run(LintOptions(rules: ["L10N101"])).diagnostics.isEmpty)
        #expect(try await TranslationEngine(project: complete).run(TranslateOptions(dryRun: true), model: nil).planned == 0)

        let partial = try project(["variations": ["plural": ["one": TestSupport.unit("%lld Datei")]]])
        #expect(try Linter(project: partial).run(LintOptions(rules: ["L10N101"])).diagnostics.first?.locales == ["de"])
        let report = try await TranslationEngine(project: partial).run(TranslateOptions(dryRun: true), model: nil)
        #expect(report.planned == 0, "language-specific variations are never machine-translated")
        #expect(report.approvedSkipped.first?.reason.contains("finish them in Xcode") == true)
    }

    @Test func failedApplyRollsBackEveryWrittenFile() throws {
        let catalogJSON = TestSupport.catalogJSON([:])
        let root = try TestSupport.makeProject([
            ".l10n-agent.yml": "codeStyle: literal\ncatalog: Localizable.xcstrings\n",
            "Localizable.xcstrings": catalogJSON,
            "App/A.swift": "func a() { label.text = \"First title\" }\n",
            "Locked/B.swift": "func b() { label.text = \"Second title\" }\n",
        ])
        let project = try Project.discover(root: root)
        let plan = try Fixer(project: project).plan()
        #expect(plan.items.count == 2)
        let catalogBefore = try Data(contentsOf: root.appendingPathComponent("Localizable.xcstrings"))

        // Make the second file's folder read-only so its atomic write fails after the
        // catalog and the first source file were already written.
        let locked = root.appendingPathComponent("Locked")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }

        #expect(throws: (any Error).self) { try Fixer(project: project).apply(plan) }
        #expect(try Data(contentsOf: root.appendingPathComponent("Localizable.xcstrings")) == catalogBefore, "catalog restored")
        #expect(try String(contentsOf: root.appendingPathComponent("App/A.swift"), encoding: .utf8) == "func a() { label.text = \"First title\" }\n", "first file restored")
        #expect(!FileManager.default.fileExists(atPath: FingerprintStore.path(root: root).path), "no fingerprints left behind")
    }

    @Test func failedTranslateSaveRollsBackCatalogs() async throws {
        let catalogJSON = TestSupport.catalogJSON(["home.title": TestSupport.manual("Home")])
        let root = try TestSupport.makeProject([".l10n-agent.yml": "locales: [de]\n", "App/Localizable.xcstrings": catalogJSON])
        let project = try Project.discover(root: root)
        // Make the fingerprints file unwritable: its folder exists but is read-only.
        let state = root.appendingPathComponent(".l10n-agent")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        let catalogBefore = try Data(contentsOf: root.appendingPathComponent("App/Localizable.xcstrings"))
        let engine = TranslationEngine(project: project)
        var loaded = try engine.load(TranslateOptions())
        var catalog = loaded.catalogs["App/Localizable.xcstrings"]!
        var entry = catalog.entry("home.title")!
        entry.setLocalization("de", LocalizationNode(unit: StringUnit(state: "needs_review", value: "Start")))
        catalog.setEntry("home.title", entry)
        loaded.catalogs["App/Localizable.xcstrings"] = catalog
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: state.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: state.path) }
        #expect(throws: (any Error).self) { try engine.saveTouched(&loaded, catalogs: ["App/Localizable.xcstrings"]) }
        #expect(try Data(contentsOf: root.appendingPathComponent("App/Localizable.xcstrings")) == catalogBefore, "catalog restored")
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
