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
