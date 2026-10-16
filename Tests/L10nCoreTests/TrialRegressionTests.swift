import Foundation
import Testing
@testable import L10nCore

/// Regression tests for the findings of the real-repo trial on pangi (2026-10-16).
@Suite("Trial regressions")
struct TrialRegressionTests {
    func lint(_ root: URL, rules: Set<String>? = nil) throws -> [Diagnostic] {
        try Linter(project: try Project.discover(root: root)).run(LintOptions(rules: rules)).diagnostics
    }

    // MARK: 1. Keys passed to localizing parameters

    @Test func keyPassedToLocalizedStringKeyParameterIsNotRewritten() throws {
        let root = try TestSupport.makeProject([
            ".l10n-agent.yml": "codeStyle: literal\nlocales: []\n",
            "App/Localizable.xcstrings": TestSupport.catalogJSON(["content.error.alert.title": TestSupport.manual("Error")]),
            "App/ErrorAlert.swift": """
            import SwiftUI
            extension View {
                func pangiErrorAlert(isPresented: Binding<Bool>, title: LocalizedStringKey = "common.error", message: String?) -> some View { self }
            }
            """,
            "App/ContentView.swift": """
            import SwiftUI
            struct ContentView: View {
                @State var shown = false
                var body: some View {
                    VStack {}
                        .pangiErrorAlert(isPresented: $shown, title: "content.error.alert.title", message: nil)
                        .pangiErrorAlert(isPresented: $shown, title: "content.missing.title", message: nil)
                        .pangiErrorAlert(isPresented: $shown, title: "Something failed", message: nil)
                }
            }
            """,
        ])
        let diagnostics = try lint(root, rules: ["L10N001", "L10N002", "L10N004"])
        #expect(!diagnostics.contains { $0.rule == Rules.unlocalized.id }, "\(diagnostics.map(\.message))")
        #expect(diagnostics.filter { $0.rule == Rules.missingKey.id }.map(\.key) == ["content.missing.title"])
        let textAsKey = try #require(diagnostics.first { $0.rule == Rules.textAsKey.id })
        #expect(!textAsKey.fixable, "a LocalizedStringKey parameter cannot take String(localized:)")

        let plan = try Fixer(project: try Project.discover(root: root)).plan()
        #expect(plan.items.allSatisfy { $0.status == .skipped }, "\(plan.items.map(\.replacement))")
        #expect(!plan.items.contains { $0.replacement.contains("defaultValue: \"content.error.alert.title\"") })
    }

    @Test func localizedStringResourceParameterGetsAResourceRewrite() throws {
        let root = try TestSupport.makeProject([
            ".l10n-agent.yml": "codeStyle: literal\n",
            "App/Localizable.xcstrings": TestSupport.catalogJSON([:]),
            "App/Banner.swift": """
            struct Banner { let title: LocalizedStringResource }
            func make() -> Banner { Banner(title: "Welcome aboard") }
            """,
        ])
        let plan = try Fixer(project: try Project.discover(root: root)).plan()
        let item = try #require(plan.items.first)
        #expect(item.replacement.hasPrefix("LocalizedStringResource(\"banner.welcomeAboard"), "\(item.replacement)")
    }

    @Test func existingKeyAtAKnownUIAPIIsReportedAsARawKey() throws {
        let root = try TestSupport.makeProject([
            ".l10n-agent.yml": "codeStyle: literal\n",
            "App/Localizable.xcstrings": TestSupport.catalogJSON(["settings.title": TestSupport.manual("Settings")]),
            "App/V.swift": """
            func f() {
                label.text = "settings.title"
                showSheet(title: "settings.title")
            }
            """,
        ])
        let diagnostics = try lint(root, rules: ["L10N001"])
        #expect(diagnostics.count == 1)
        #expect(diagnostics.first?.message.contains("is a catalog key") == true)
        #expect(diagnostics.first?.fixable == false)
        #expect(try Fixer(project: try Project.discover(root: root)).plan().items.isEmpty)
    }

    // MARK: 2-4. False positives

    @Test func queueLabelsIdentifiersAndLogOnlyTextAreIgnored() throws {
        let root = try TestSupport.makeProject([
            "App/K.swift": """
            import Foundation
            final class KeychainManager {
                private let queue = DispatchQueue(label: "com.pangi.keychain", qos: .userInitiated)
                func f() { register(label: "com.example.scanner-queue") }
            }
            enum StoreIssue {
                case disabled
                var warningMessage: String {
                    switch self {
                    case .disabled: return "Skipping AutoFill credential identity sync because the store is disabled"
                    }
                }
            }
            func sync(issue: StoreIssue) {
                PangiLogger.accounts.warning(issue.warningMessage, metadata: [:])
                logger.error("Failed: \\(issue.warningMessage)")
            }
            struct Panel {
                var logMessage: String { "internal state dump" }
            }
            """,
        ])
        #expect(try lint(root, rules: ["L10N001"]).isEmpty)
    }

    @Test func propertyAlsoShownInTheUIIsStillReported() throws {
        let root = try TestSupport.makeProject([
            "App/K.swift": """
            import SwiftUI
            enum StoreIssue {
                case disabled
                var warningMessage: String { "AutoFill is turned off" }
            }
            func sync(issue: StoreIssue) { logger.warning(issue.warningMessage) }
            struct V: View { let issue: StoreIssue; var body: some View { Text(verbatim: issue.warningMessage) } }
            """,
        ])
        #expect(try lint(root, rules: ["L10N001"]).count == 1)
    }

    @Test func generatedFilesAreSkipped() throws {
        let source = """
        import Foundation

        // GENERATED by scripts/generate-brand-icons.mjs — do not edit by hand.
        let entries = [BrandIconEntry(slug: "github", title: "GitHub")]
        """
        #expect(SwiftScanner.isGeneratedFile(source: source))
        #expect(SwiftScanner().scan(source: source, path: "Brand.swift").isEmpty)
        #expect(!SwiftScanner.isGeneratedFile(source: "import UIKit\n// A view.\nlet title = \"Hello there\"\n// generated by the user later\n"))
    }

    @Test func fixesFoundByNameOnlyNeedReview() throws {
        let root = try TestSupport.makeProject([
            ".l10n-agent.yml": "codeStyle: literal\n",
            "App/Localizable.xcstrings": TestSupport.catalogJSON([:]),
            "App/V.swift": """
            final class Screen {
                func f() {
                    present(title: "Delete everything")
                    label.text = "Shown for sure"
                }
            }
            """,
        ])
        let plan = try Fixer(project: try Project.discover(root: root)).plan()
        let byText = Dictionary(uniqueKeysWithValues: plan.items.map { ($0.sourceValue, $0) })
        #expect(byText["Delete everything"]?.status == .needsReview)
        #expect(byText["Delete everything"]?.reason?.contains("found only by the name") == true)
        #expect(byText["Shown for sure"]?.status == .ready)
    }

    // MARK: 5-6. Edited plans and placeholder types

    @Test func declaredTypesGiveConfidentSpecifiers() {
        let sites = SwiftScanner().scan(source: """
        struct MacAppSettings {
            var total: Double = 0
            func keyLabel(for keyCode: UInt32) -> String {
                return "Key \\(keyCode)"
            }
            func f() {
                let count: Int = 3
                label.text = "Items: \\(count) of \\(self.total)"
                items.forEach { (n: Int8) in other.text = "Row \\(n)" }
            }
        }
        """, path: "S.swift")
        let placeholders = sites.map { Fixer.placeholders(for: $0) }
        #expect(placeholders.map { $0.map(\.specifier) } == [["%u"], ["%lld", "%lf"], ["%hhd"]])
        #expect(placeholders.allSatisfy { $0.allSatisfy(\.confident) })
    }

    @Test func editedPlanPreviewIsRecomputed() throws {
        let root = try TestSupport.makeProject([
            ".l10n-agent.yml": "codeStyle: literal\n",
            "App/Localizable.xcstrings": TestSupport.catalogJSON([:]),
            "App/V.swift": "final class Screen { func f(code: Code) { label.text = \"Key \\(code)\" } }\n",
        ])
        let fixer = Fixer(project: try Project.discover(root: root))
        var plan = try fixer.plan()
        #expect(plan.items.first?.status == .needsReview)
        #expect(plan.items.first?.comment.contains("%@ is code") == true)
        plan.items[0].key = "screen.hotkey.code"
        plan.items[0].placeholders[0].specifier = "%u"
        plan.items[0].status = .ready
        let refreshed = try fixer.refresh(plan)
        let item = try #require(refreshed.items.first)
        #expect(item.sourceValue == "Key %u")
        #expect(item.replacement.contains("\"screen.hotkey.code\""))
        #expect(item.comment.contains("%u is code") && !item.comment.contains("%@"))
        #expect(item.reason == nil)
        #expect(Fixer.preview(refreshed).contains("add \"screen.hotkey.code\" = \"Key %u\""))
        // Nothing was written.
        #expect(try StringCatalog.load(root.appendingPathComponent("App/Localizable.xcstrings")).keys.isEmpty)
    }

    // MARK: 7. Key names follow the project

    @Test func newKeysFollowTheKeysTheTypeAlreadyUses() throws {
        let root = try TestSupport.makeProject([
            ".l10n-agent.yml": "codeStyle: literal\nkeys: { maxDepth: 6 }\n",
            "App/Localizable.xcstrings": TestSupport.catalogJSON([
                "mac.settings.hotkey.title": TestSupport.manual("Hotkey"),
                "mac.settings.hotkey.modifier": TestSupport.manual("Modifier"),
            ]),
            "App/HotkeyView.swift": """
            import SwiftUI
            struct HotkeyView: View {
                var body: some View {
                    VStack {
                        Text("mac.settings.hotkey.title")
                        Text("mac.settings.hotkey.modifier")
                        Button("Record shortcut") {}
                    }
                }
            }
            """,
        ])
        let plan = try Fixer(project: try Project.discover(root: root)).plan(rules: ["L10N002"])
        #expect(plan.items.map(\.key) == ["mac.settings.hotkey.recordShortcut.button"])
    }

    @Test func newKeysFollowTheCatalogsDominantPrefix() throws {
        var strings: [String: Any] = [:]
        for name in ["a", "b", "c", "d", "e"] { strings["mac.\(name).title"] = TestSupport.manual(name) }
        let root = try TestSupport.makeProject([
            ".l10n-agent.yml": "codeStyle: literal\n",
            "Mac/Localizable.xcstrings": TestSupport.catalogJSON(strings),
            "Mac/MacAppSettings.swift": "struct MacAppSettings { func f() { label.text = \"Space bar\" } }\n",
        ])
        let plan = try Fixer(project: try Project.discover(root: root)).plan()
        #expect(plan.items.map(\.key) == ["mac.appSettings.spaceBar.label"])
        #expect(plan.items.first?.comment == "Label in MacAppSettings.f().")
    }

    // MARK: 8. Symbol detection ignores test bundles

    static func pbxproj(appSymbols: String) -> String {
        """
        // !$*UTF8*$!
        {
            archiveVersion = 1;
            objectVersion = 77;
            objects = {
                P1 = { isa = PBXProject; buildConfigurationList = L0; targets = (T1, T2); };
                L0 = { isa = XCConfigurationList; buildConfigurations = (C0); };
                C0 = { isa = XCBuildConfiguration; buildSettings = { SWIFT_VERSION = 6.0; }; name = Debug; };
                T1 = { isa = PBXNativeTarget; name = App; productType = "com.apple.product-type.application"; buildConfigurationList = L1; };
                L1 = { isa = XCConfigurationList; buildConfigurations = (C1, C2); };
                C1 = { isa = XCBuildConfiguration; buildSettings = { STRING_CATALOG_GENERATE_SYMBOLS = \(appSymbols); }; name = Debug; };
                C2 = { isa = XCBuildConfiguration; buildSettings = { STRING_CATALOG_GENERATE_SYMBOLS = YES; }; name = Release; };
                T2 = { isa = PBXNativeTarget; name = AppTests; productType = "com.apple.product-type.bundle.unit-test"; buildConfigurationList = L2; };
                L2 = { isa = XCConfigurationList; buildConfigurations = (C3); };
                C3 = { isa = XCBuildConfiguration; buildSettings = { STRING_CATALOG_GENERATE_SYMBOLS = NO; }; name = Debug; };
            };
            rootObject = P1;
        }
        """
    }

    @Test func symbolDetectionIgnoresTestBundles() throws {
        let enabled = XcodeSettings.symbolSettings(pbxproj: Self.pbxproj(appSymbols: "YES"))
        #expect(enabled.enabled == ["App/Debug", "App/Release"])
        #expect(enabled.disabled.isEmpty)
        let root = try TestSupport.makeProject(["App.xcodeproj/project.pbxproj": Self.pbxproj(appSymbols: "NO"), "App/V.swift": ""])
        let project = try Project.discover(root: root)
        let path = project.xcode.projectFiles[0].path
        #expect(project.xcode.symbolGeneration[path] == .mixed)
        #expect(project.xcode.symbolsDisabledIn[path] == ["App/Debug"])
        #expect(DoctorCommand.codeStyleDetail(project).contains("STRING_CATALOG_GENERATE_SYMBOLS = NO in App/Debug"))
    }

    // MARK: 9-11. Doctor, init and key style

    @Test func remoteTranslatorsAreRecognized() async {
        #expect(await ChatModelFactory.isRemote(TranslatorConfig(provider: .openai, baseURL: "https://api.example.com"), model: "m"))
        #expect(await ChatModelFactory.isRemote(TranslatorConfig(provider: .openai, baseURL: "http://localhost:1234"), model: "deepseek:cloud"))
        #expect(await !ChatModelFactory.isRemote(TranslatorConfig(provider: .openai, baseURL: "http://localhost:1234"), model: "qwen3"))
    }

    @Test func initNotesCloudModelsAndInfersTheKeyScheme() async throws {
        var strings: [String: Any] = [:]
        for index in 0..<6 { strings["settings.security.reauth.interval.option\(index).label"] = TestSupport.manual("Option \(index)") }
        let files = [".l10n-agent.yml": "", "App/Localizable.xcstrings": TestSupport.catalogJSON(strings)]
        let refused = try TestSupport.makeProject(files)
        let result = try await InitCommand.run(root: refused, model: "deepseek-v4.1-flash:cloud", force: true)
        #expect(result.notes.contains { $0.contains("runs remotely, so translate refuses it") })
        let config = try String(contentsOf: refused.appendingPathComponent(".l10n-agent.yml"), encoding: .utf8)
        #expect(config.contains("allowRemote: false"))
        #expect(config.contains("maxDepth: 6"))
        #expect(try L10nConfig.load(root: refused).keys.maxDepth == 6)

        let allowed = try TestSupport.makeProject(files)
        let allowedResult = try await InitCommand.run(root: allowed, model: "deepseek-v4.1-flash:cloud", force: true, allowRemote: true)
        #expect(allowedResult.notes.contains { $0.contains("L10N_AGENT_ALLOW_REMOTE=1") })
        #expect(try L10nConfig.load(root: allowed).translator.allowRemote)
    }

    @Test func laterKeySegmentsMayStartWithADigit() {
        let policy = KeyPolicy(maxDepth: 6)
        #expect(policy.violations(for: "mac.settings.autoLock.15min").isEmpty)
        #expect(!policy.violations(for: "15min.settings").isEmpty)
        #expect(!KeyPolicy(style: .dottedLower).violations(for: "settings.autoLock").isEmpty)
        #expect(!policy.violations(for: "settings.title\n").isEmpty, "a trailing newline is not part of a valid segment")
    }

    // MARK: 12. Glossary forms and translator instructions

    @Test func glossaryAcceptsSeveralForms() throws {
        let root = try TestSupport.makeProject([
            ".l10n-agent.yml": "locales: [de]\nglossary: { account: { de: [Konto, Konten] } }\n",
            "L.xcstrings": TestSupport.catalogJSON([
                "content.empty": TestSupport.manual("No Accounts Yet", translations: ["de": TestSupport.unit("Noch keine Konten")]),
                "import.progress": TestSupport.manual("Importing account %d", translations: ["de": TestSupport.unit("Account %d wird importiert")]),
            ]),
        ])
        let glossary = try lint(root, rules: ["L10N108"])
        #expect(glossary.map(\.key) == ["import.progress"])
        #expect(glossary.first?.message.contains("\"Konto\" or \"Konten\"") == true)
        #expect(try L10nConfig.load(root: root).glossary["account"]?["de"]?.forms == ["Konto", "Konten"])
    }

    @Test func translatorInstructionsReachThePrompt() throws {
        let root = try TestSupport.makeProject([
            ".l10n-agent.yml": "translator: { instructions: { \"*\": \"Keep it short.\", de: \"Use informal du.\" } }\nglossary: { account: { de: [Konto, Konten] } }\n",
        ])
        let prompt = TranslationEngine(project: try Project.discover(root: root)).systemPrompt(locale: "de")
        #expect(prompt.contains("- Keep it short.") && prompt.contains("- Use informal du."))
        #expect(prompt.contains("account => Konto / Konten"))
        #expect(!TranslationEngine(project: try Project.discover(root: root)).systemPrompt(locale: "fr").contains("informal du"))
    }

    // MARK: 13-14. Gates and don't-translate entries

    @Test func statusThresholdAndLetterlessEntries() throws {
        let root = try TestSupport.makeProject([
            ".l10n-agent.yml": "locales: [de]\n",
            "L.xcstrings": TestSupport.catalogJSON([
                "a.title": TestSupport.manual("A", translations: ["de": TestSupport.unit("A de")]),
                "b.title": TestSupport.manual("B", translations: ["de": TestSupport.unit("B de", state: "needs_review")]),
                "%lld": [:],
            ]),
        ])
        let report = try StatusCommand.run(project: try Project.discover(root: root))
        #expect(report.catalogs[0].locales[0].total == 2, "letterless keys need no translation")
        #expect(StatusCommand.below(report, percent: 100).isEmpty)
        #expect(StatusCommand.below(report, percent: 100, approvedOnly: true) == ["L.xcstrings de 50%"])
    }

    @Test func letterlessLiteralsBecomeDoNotTranslateEntries() throws {
        let root = try TestSupport.makeProject([
            ".l10n-agent.yml": "codeStyle: literal\nlocales: [de]\n",
            "App/Localizable.xcstrings": TestSupport.catalogJSON(["%lld · %lld": ["shouldTranslate": false]]),
            "App/V.swift": """
            import SwiftUI
            struct V: View {
                let count: Int
                var body: some View {
                    VStack { Text("\\(count)"); Text("6"); Text("\\(count) · \\(count)"); Text(verbatim: "\\(count)") }
                }
            }
            """,
        ])
        let findings = try lint(root, rules: ["L10N006"])
        #expect(findings.map(\.key) == ["%lld", "6"], "the third key is already marked, verbatim is not extracted")
        let project = try Project.discover(root: root)
        let plan = try Fixer(project: project).plan()
        #expect(plan.items.allSatisfy { $0.doNotTranslate == true && $0.status == .ready })
        let source = try String(contentsOf: root.appendingPathComponent("App/V.swift"), encoding: .utf8)
        let result = try Fixer(project: project).apply(plan)
        #expect(result.filesChanged.isEmpty)
        #expect(Set(result.keysAdded) == ["%lld", "6"])
        #expect(try String(contentsOf: root.appendingPathComponent("App/V.swift"), encoding: .utf8) == source)
        let catalog = try StringCatalog.load(root.appendingPathComponent("App/Localizable.xcstrings"))
        #expect(catalog.entry("%lld")?.shouldTranslate == false)
        #expect(catalog.entry("%lld")?.extractionState == nil)
        #expect(try lint(root, rules: ["L10N006", "L10N101"]).isEmpty)
    }

    @Test func addKeysMarksDoNotTranslate() throws {
        let root = try TestSupport.makeProject([
            ".l10n-agent.yml": "codeStyle: literal\n",
            "App/Localizable.xcstrings": TestSupport.catalogJSON([:]),
        ])
        let keys = try JSONDecoder().decode([NewKey].self, from: Data(#"[{"key": "%lld", "shouldTranslate": false}, {"key": "app.brand.name", "value": "Pangi", "shouldTranslate": false}]"#.utf8))
        let result = try AddKeysCommand.run(project: try Project.discover(root: root), keys: keys)
        #expect(result.added == ["%lld", "app.brand.name"])
        let catalog = try StringCatalog.load(root.appendingPathComponent("App/Localizable.xcstrings"))
        #expect(catalog.entry("%lld")?.shouldTranslate == false && catalog.entry("%lld")?.localization("en") == nil)
        #expect(catalog.entry("app.brand.name")?.shouldTranslate == false && catalog.entry("app.brand.name")?.isManual == true)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(NewKey.self, from: Data(#"{"key": "a.b"}"#.utf8)) }
    }

    // MARK: 15. .strings migration

    @Test func migratesStringsAndStringsdictIntoCatalogs() throws {
        let english = """
        /* Title of the settings screen. */
        "settings.title" = "Settings";

        /* Section header, not the next entry's comment */

        "settings.escapes" = "Tab\\there \\"quoted\\" \\U00E9 line\\nbreak";
        unquoted.key = "Plain";
        "settings.only.en" = "Only English";
        """
        let german = """
        "settings.title" = "Einstellungen";
        "settings.escapes" = "Tab\\thier \\"zitiert\\" \\U00E9 Zeile\\nUmbruch";
        unquoted.key = "Einfach";
        """
        func plural(_ format: String, one: String, other: String) -> String {
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict>
              <key>inbox.count</key>
              <dict>
                <key>NSStringLocalizedFormatKey</key><string>\(format)</string>
                <key>messages</key>
                <dict>
                  <key>NSStringFormatSpecTypeKey</key><string>NSStringPluralRuleType</string>
                  <key>NSStringFormatValueTypeKey</key><string>d</string>
                  <key>one</key><string>\(one)</string>
                  <key>other</key><string>\(other)</string>
                </dict>
              </dict>
            </dict></plist>
            """
        }
        let root = try TestSupport.makeProject([
            ".l10n-agent.yml": "sourceLanguage: en\n",
            "App/en.lproj/Localizable.strings": english,
            "App/de.lproj/Localizable.strings": german,
            "App/en.lproj/Localizable.stringsdict": plural("%@ has %#@messages@", one: "%d message", other: "%d messages"),
            "App/de.lproj/Localizable.stringsdict": plural("%@ hat %#@messages@", one: "%d Nachricht", other: "%d Nachrichten"),
            "App/Base.lproj/Main.storyboard": "<document/>",
            "App/de.lproj/Main.strings": "\"abc.text\" = \"Hallo\";\n",
        ])
        let project = try Project.discover(root: root)
        let preview = try MigrateCommand.run(project: project, apply: false)
        #expect(preview.tables.map(\.catalog) == ["App/Localizable.xcstrings"])
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("App/Localizable.xcstrings").path))
        #expect(preview.skipped["App/de.lproj/Main.strings"]?.contains("Interface Builder") == true)

        let result = try MigrateCommand.run(project: project, apply: true, removeLegacy: true)
        #expect(result.tables.first?.keys == 5)
        let catalog = try StringCatalog.load(root.appendingPathComponent("App/Localizable.xcstrings"))
        let title = try #require(catalog.entry("settings.title"))
        #expect(title.isManual && title.comment == "Title of the settings screen.")
        #expect(title.localization("de")?.stringUnit == StringUnit(state: "translated", value: "Einstellungen"))
        #expect(catalog.entry("settings.escapes")?.comment == "Section header, not the next entry's comment", "entries under a section comment get it")
        #expect(catalog.entry("settings.escapes")?.localization("en")?.stringUnit?.value == "Tab\there \"quoted\" é line\nbreak")
        #expect(catalog.entry("unquoted.key")?.localization("de")?.stringUnit?.value == "Einfach")
        #expect(catalog.entry("settings.only.en")?.localization("de") == nil)

        let count = try #require(catalog.entry("inbox.count")?.localization("de"))
        #expect(count.stringUnit?.value == "%@ hat %#@messages@")
        let substitution = try #require(count.substitutions["messages"])
        #expect(substitution.argNum == 2 && substitution.formatSpecifier == "d")
        #expect(substitution.variations["plural"]?["other"]?.stringUnit?.value == "%arg Nachrichten")

        // Old files are gone (the storyboard's strings stay), fingerprints are recorded.
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("App/en.lproj").path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("App/de.lproj/Main.strings").path))
        let fingerprints = try FingerprintStore.load(root: root)
        #expect(fingerprints.fingerprint(catalog: "App/Localizable.xcstrings", key: "settings.title", locale: "de") != nil)
        // The migrated catalog is clean: no format mismatch, no missing German except the en-only key.
        let diagnostics = try lint(root, rules: ["L10N104", "L10N101"])
        #expect(diagnostics.map(\.key) == ["settings.only.en"])
    }

    @Test func migrationReadsUTF16AndKeepsExistingCatalogValues() throws {
        let root = try TestSupport.makeProject([
            "App/Localizable.xcstrings": TestSupport.catalogJSON(["a.title": TestSupport.manual("A", translations: ["de": TestSupport.unit("A (Katalog)")])]),
            "App/en.lproj/Localizable.strings": "\"a.title\" = \"A\";\n\"b.title\" = \"B\";\n",
        ])
        let german = Data([0xFF, 0xFE]) + "\"a.title\" = \"A (alt)\";\n\"b.title\" = \"B de\";\n".data(using: .utf16LittleEndian)!
        try FileManager.default.createDirectory(at: root.appendingPathComponent("App/de.lproj"), withIntermediateDirectories: true)
        try german.write(to: root.appendingPathComponent("App/de.lproj/Localizable.strings"))
        let result = try MigrateCommand.run(project: try Project.discover(root: root), apply: true)
        #expect(result.tables.first?.created == false)
        #expect(result.tables.first?.conflicts == ["a.title [de]"])
        let catalog = try StringCatalog.load(root.appendingPathComponent("App/Localizable.xcstrings"))
        #expect(catalog.entry("a.title")?.localization("de")?.stringUnit?.value == "A (Katalog)")
        #expect(catalog.entry("b.title")?.localization("de")?.stringUnit?.value == "B de")
    }

    @Test func malformedStringsFilesAreNotMigrated() throws {
        let root = try TestSupport.makeProject(["App/en.lproj/Localizable.strings": "\"a\" = \"A\"\n\"b\" = \"B\";\n"])
        let result = try MigrateCommand.run(project: try Project.discover(root: root), apply: true)
        #expect(result.tables.isEmpty)
        #expect(result.failed["App/en.lproj/Localizable.strings"]?.contains("expected \";\"") == true)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("App/Localizable.xcstrings").path))
    }

    @Test func migratedCatalogsMatchXcodeFormatting() throws {
        guard TestSupport.hasXcstringstool else { return }
        let root = try TestSupport.makeProject([
            "App/en.lproj/Localizable.strings": "/* c */\n\"z.key\" = \"Zed\";\n\"a.key\" = \"Ä \\\"x\\\"\";\n",
            "App/de.lproj/Localizable.strings": "\"z.key\" = \"Zett\";\n",
        ])
        _ = try MigrateCommand.run(project: try Project.discover(root: root), apply: true)
        let url = root.appendingPathComponent("App/Localizable.xcstrings")
        let before = try Data(contentsOf: url)
        // An empty .stringsdata: sync only rewrites the file in Xcode's format.
        let swift = root.appendingPathComponent("Empty.swift")
        try "let x = 1\n".write(to: swift, atomically: true, encoding: .utf8)
        let out = root.appendingPathComponent("extracted")
        _ = TestSupport.shell(["xcrun", "xcstringstool", "extract", swift.path, "--SwiftUI", "-o", out.path])
        let stringsdata = ((try? FileManager.default.contentsOfDirectory(atPath: out.path)) ?? []).map { out.appendingPathComponent($0).path }
        let (status, output) = TestSupport.shell(["xcrun", "xcstringstool", "sync", url.path, "--skip-marking-strings-stale", "--stringsdata"] + stringsdata)
        guard status == 0 else { Issue.record("xcstringstool failed: \(output)"); return }
        #expect(try Data(contentsOf: url) == before)
    }

    // MARK: 16-17. Unused manual keys and catalog plural hints

    @Test func unusedManualKeysAreReported() throws {
        let root = try TestSupport.makeProject([
            ".l10n-agent.yml": "keys: { dynamicPrefixes: [\"onboarding.step\"] }\n",
            "App/Localizable.xcstrings": TestSupport.catalogJSON([
                "used.literal": TestSupport.manual("A"),
                "used.symbol": TestSupport.manual("B"),
                "used.prefix.one": TestSupport.manual("C"),
                "onboarding.step1": TestSupport.manual("D"),
                "unused.key": TestSupport.manual("E"),
                "unused.key.longer": TestSupport.manual("F"),
            ]),
            "App/InfoPlist.xcstrings": TestSupport.catalogJSON(["CFBundleDisplayName": TestSupport.manual("App")]),
            "App/V.swift": """
            func f(kind: String) {
                _ = String(localized: "used.literal")
                _ = String(localized: .usedSymbol)
                _ = NSLocalizedString("used.prefix.\\(kind)", comment: "")
                _ = "unused.key.longer.extra"
            }
            """,
        ])
        #expect(try lint(root, rules: ["L10N106"]).map(\.key) == ["unused.key", "unused.key.longer"])
    }

    @Test func catalogValuesThatCountSomethingAreReported() {
        #expect(Linter.catalogPluralHint("%d accounts already existed") == "%d accounts")
        #expect(Linter.catalogPluralHint("Import %lld account(s)") == "account(s)")
        #expect(Linter.catalogPluralHint("%d of %d") == nil)
        #expect(Linter.catalogPluralHint("Accounts: %@") == nil)
        #expect(Linter.catalogPluralHint("%d class") == nil)
    }

    // MARK: 19. NSError messages

    @Test func errorUserInfoMessagesAreUserFacing() throws {
        let sites = SwiftScanner().scan(source: """
        func fail() -> NSError {
            NSError(domain: "app", code: 1, userInfo: [NSLocalizedDescriptionKey: "Model container not yet initialized", "debug": "internal detail here"])
        }
        """, path: "E.swift")
        #expect(sites.map(\.displayText) == ["Model container not yet initialized"])
        #expect(sites.first?.kind == .unlocalized && sites.first?.fixable == true)
    }

    // MARK: Review findings

    @Test func extractedEnglishKeysAreStillPlainText() throws {
        let root = try TestSupport.makeProject([
            ".l10n-agent.yml": "codeStyle: literal\n",
            "App/Localizable.xcstrings": TestSupport.catalogJSON(["Cancel": ["localizations": ["en": TestSupport.unit("Cancel")]]]),
            "App/V.swift": "final class Screen { func f() { label.text = \"Cancel\"; showToast(title: \"Cancel\") } }\n",
        ])
        let diagnostics = try lint(root, rules: ["L10N001"])
        #expect(diagnostics.count == 2)
        #expect(diagnostics.allSatisfy { $0.fixable && !$0.message.contains("catalog key") })
    }

    @Test func shadowingBindingsMakeTheTypeUnknown() {
        let sites = SwiftScanner().scan(source: """
        final class Screen {
            func f(count: Int, name: Int, value: Int, item: Int, code: Int) {
                names.forEach { count in a.text = "Alpha \\(count)" }
                for name in names { b.text = "Beta \\(name)" }
                if let value = Optional("x") { c.text = "Gamma \\(value)" }
                switch result { case let .some(item): d.text = "Delta \\(item)"; default: break }
                guard let code = lookup() else { return }
                e.text = "Epsilon \\(code)"
                let total: Int32 = 1
                if true { f.text = "Zeta \\(total)" }
            }
        }
        """, path: "S.swift")
        let placeholders = sites.map { Fixer.placeholders(for: $0) }
        #expect(placeholders.map { $0.first?.confident } == [false, false, false, false, false, true])
        #expect(placeholders.last?.first?.specifier == "%d")
    }

    @Test func sameNamedFunctionsWithPlainParametersStayText() {
        let index = ProjectIndex.build(sources: [
            "struct A { func show(title: LocalizedStringKey) {} }",
            "final class B { func show(title: String) { label.text = title } }",
            "struct C { func present(heading: LocalizedStringResource) {} }",
        ])
        #expect(index.localizedParameters["show"] == nil)
        #expect(index.localizedParameters["present"]?["heading"] == "LocalizedStringResource")
        let sites = SwiftScanner(index: index).scan(source: "func f(b: B) { b.show(title: \"Upload finished\") }", path: "F.swift")
        #expect(sites.first?.kind == .unlocalized)
    }

    @Test func logOnlyDetectionCoversFunctionsButNotUICalls() {
        let index = ProjectIndex.build(sources: ["""
        struct Issue {
            func warningMessage() -> String { "Skipping sync because it is off" }
            var errorTitle: String { "Upload failed" }
            func report() {
                logger.warning(warningMessage())
                ProgressHUD.error(errorTitle)
                toast.info(errorTitle)
            }
        }
        """])
        #expect(index.logOnlyNames.contains("warningMessage"))
        #expect(!index.logOnlyNames.contains("errorTitle"))
    }

    @Test func generatedFileDetectionNeedsAGeneratorMarker() {
        #expect(!SwiftScanner.isGeneratedFile(source: "// Created by Bob. Do not edit without asking design.\nlet x = 1\n"))
        #expect(!SwiftScanner.isGeneratedFile(source: "// Generated by Xcode's template\nlet x = 1\n"))
        #expect(!SwiftScanner.isGeneratedFile(source: "import SwiftUI\n/// Generated view. Do not edit without the snapshot tests.\nstruct V {}\n"))
        #expect(SwiftScanner.isGeneratedFile(source: "// @generated by protoc\nlet x = 1\n"))
        #expect(SwiftScanner.isGeneratedFile(source: "/* This file was generated by SwiftGen. Do not edit. */\nenum L {}\n"))
    }

    @Test func symbolStyleSiblingsGiveThePrefix() throws {
        let root = try TestSupport.makeProject([
            ".l10n-agent.yml": "codeStyle: symbols\nkeys: { maxDepth: 6 }\n",
            "App/Localizable.xcstrings": TestSupport.catalogJSON([
                "mac.settings.hotkey.title": TestSupport.manual("Hotkey"),
                "mac.settings.hotkey.modifier": TestSupport.manual("Modifier"),
            ]),
            "App/HotkeyView.swift": """
            import SwiftUI
            struct HotkeyView: View {
                var body: some View {
                    VStack {
                        Text(.macSettingsHotkeyTitle)
                        Text(.macSettingsHotkeyModifier)
                        Button("Record shortcut") {}
                    }
                }
            }
            """,
        ])
        let plan = try Fixer(project: try Project.discover(root: root)).plan(rules: ["L10N002"])
        #expect(plan.items.map(\.key) == ["mac.settings.hotkey.recordShortcut.button"])
    }

    @Test func migrationKeepsFingerprintsAndConflictingFiles() throws {
        let root = try TestSupport.makeProject([
            "App/Localizable.xcstrings": TestSupport.catalogJSON([
                "a.title": TestSupport.manual("New text", translations: ["de": TestSupport.unit("Alter Text")]),
                "b.title": TestSupport.manual("Same", translations: [:]),
            ]),
            ".l10n-agent/fingerprints.json": #"{"catalogs":{"App/Localizable.xcstrings":{"a.title":{"de":"old"}}},"version":1}"#,
            "App/en.lproj/Localizable.strings": "\"a.title\" = \"Old text\";\n\"b.title\" = \"Same\";\n",
            "App/de.lproj/Localizable.strings": "\"a.title\" = \"Neuer Text\";\n\"b.title\" = \"Gleich\";\n",
        ])
        let result = try MigrateCommand.run(project: try Project.discover(root: root), apply: true, removeLegacy: true)
        let fingerprints = try FingerprintStore.load(root: root)
        #expect(fingerprints.fingerprint(catalog: "App/Localizable.xcstrings", key: "a.title", locale: "de") == "old", "existing records are kept")
        #expect(try lint(root, rules: ["L10N103"]).map(\.key) == ["a.title"], "the stale translation is still reported")
        // Both files hold a value that lost a conflict, so neither is deleted.
        #expect(result.removed.isEmpty)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("App/de.lproj/Localizable.strings").path))
        #expect(result.tables.first?.conflicts == ["a.title [de]", "a.title [en]"])
        // b.title's German came from the migration and is stamped against its legacy source.
        #expect(fingerprints.fingerprint(catalog: "App/Localizable.xcstrings", key: "b.title", locale: "de") != nil)
    }

    @Test func migrationReadsUTF16WithoutByteOrderMark() throws {
        let root = try TestSupport.makeProject([:])
        let folder = root.appendingPathComponent("App/en.lproj")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "\"a.title\" = \"Ä\";\n".data(using: .utf16LittleEndian)!.write(to: folder.appendingPathComponent("Localizable.strings"))
        let result = try MigrateCommand.run(project: try Project.discover(root: root), apply: true)
        #expect(result.failed.isEmpty, "\(result.failed)")
        #expect(try StringCatalog.load(root.appendingPathComponent("App/Localizable.xcstrings")).entry("a.title")?.localization("en")?.stringUnit?.value == "Ä")
    }

    @Test func migrationIgnoresSymlinksLeavingTheProject() throws {
        let outside = try TestSupport.makeProject(["secret.strings": "\"a.b\" = \"outside\";\n"])
        let root = try TestSupport.makeProject(["App/en.lproj/Localizable.strings": "\"a.title\" = \"A\";\n"])
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("App/en.lproj/Other.strings"), withDestinationURL: outside.appendingPathComponent("secret.strings"))
        let result = try MigrateCommand.run(project: try Project.discover(root: root), apply: true, removeLegacy: true)
        #expect(result.tables.map(\.catalog) == ["App/Localizable.xcstrings"])
        #expect(FileManager.default.fileExists(atPath: outside.appendingPathComponent("secret.strings").path))
    }

    @Test func letterlessValuesAreNotSentToTheModel() async throws {
        let root = try TestSupport.makeProject([
            ".l10n-agent.yml": "locales: [de]\n",
            "L.xcstrings": TestSupport.catalogJSON(["%lld": ["localizations": ["en": TestSupport.unit("%lld")]], "a.title": TestSupport.manual("Hello")]),
        ])
        let report = try await TranslationEngine(project: try Project.discover(root: root)).run(TranslateOptions(dryRun: true), model: nil)
        #expect(report.units?.map(\.key) == ["a.title"])
    }

    @Test func semanticDoNotTranslateKeysNeedAValue() {
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(NewKey.self, from: Data(#"{"key": "app.brand.name", "shouldTranslate": false}"#.utf8)) }
        #expect((try? JSONDecoder().decode(NewKey.self, from: Data(#"{"key": "•", "shouldTranslate": false}"#.utf8)))?.value == "•")
    }

    @Test func refreshPredictsOverlappingEdits() throws {
        let root = try TestSupport.makeProject([
            ".l10n-agent.yml": "codeStyle: literal\n",
            "App/Localizable.xcstrings": TestSupport.catalogJSON([:]),
            "App/V.swift": "final class Screen { func f() { label.text = \"Shown for sure\" } }\n",
        ])
        let fixer = Fixer(project: try Project.discover(root: root))
        var plan = try fixer.plan()
        var duplicate = plan.items[0]
        duplicate.id = "copy"
        plan.items.append(duplicate)
        let refreshed = try fixer.refresh(plan)
        #expect(refreshed.items.map(\.status) == [.ready, .skipped])
        #expect(refreshed.items[1].reason == "overlaps another fix")
    }

    // MARK: CLI behavior (core helpers)

    @Test func lintExitCodeFollowsFailOn() {
        let warning = Diagnostic(rule: Rules.missingTranslation, severity: .warning, message: "m", file: "f")
        let report = LintReport(diagnostics: [warning], summary: LintSummary())
        #expect(report.exitCode(failOn: .warning) == 1)
        #expect(report.exitCode(failOn: .error) == 0)
        #expect(report.exitCode(failOn: .off) == 0)
        #expect(LintReport(diagnostics: [Diagnostic(rule: Rules.missingComment, severity: .info, message: "m", file: "f")], summary: LintSummary()).exitCode(failOn: .warning) == 0)
    }

    @Test func setTranslationOptionsAreParsed() throws {
        let plain = try ProvidedTranslation.fromOptions(key: "a.b", locale: "de", value: "Hallo", forms: [], catalog: nil)
        #expect(plain.value == "Hallo" && plain.forms == nil)
        let plural = try ProvidedTranslation.fromOptions(key: "a.b", locale: "de", value: nil, forms: ["one=%lld Datei", "other=%lld = viele"], catalog: "L.xcstrings")
        #expect(plural.forms == ["one": "%lld Datei", "other": "%lld = viele"] && plural.catalog == "L.xcstrings")
        #expect(throws: L10nError.self) { try ProvidedTranslation.fromOptions(key: "a", locale: "de", value: "x", forms: ["one=y"], catalog: nil) }
        #expect(throws: L10nError.self) { try ProvidedTranslation.fromOptions(key: "a", locale: "de", value: nil, forms: ["=y"], catalog: nil) }
    }

    @Test func dryRunReportsARefusedTranslator() async {
        let refusal = await TranslationEngine.refusal(TranslatorConfig(provider: .openai, baseURL: "https://api.example.com", model: "m"))
        #expect(refusal?.contains("a real run would stop") == true)
        #expect(refusal?.contains("allowRemote") == true)
    }

    @Test func doctorDetails() throws {
        let root = try TestSupport.makeProject([
            "App/V.swift": "let x = 1\n",
            "App/Gen.swift": "// @generated\nlet y = 2\n",
            "AppTests/VTests.swift": "import XCTest\n",
        ])
        #expect(DoctorCommand.swiftFilesDetail(try Project.discover(root: root)) == "1 Swift file(s) scanned (2 test or generated file(s) skipped)")
        let config = TranslatorConfig(model: "deepseek:cloud")
        #expect(DoctorCommand.translatorDetail(config, model: "deepseek:cloud", remote: true).contains("runs remotely"))
        #expect(DoctorCommand.translatorDetail(config, model: "qwen3", remote: false).hasSuffix("local only"))
    }

    @Test func migrationNotesProjectReferencesByWholeFileName() throws {
        let pbxproj = """
        objects = {
            A1 /* InfoPlist.strings in Resources */ = {isa = PBXBuildFile; };
            A2 /* Localizable.strings */ = {isa = PBXVariantGroup; name = Localizable.strings; };
        };
        """
        let root = try TestSupport.makeProject([
            "App.xcodeproj/project.pbxproj": pbxproj,
            "App/en.lproj/Localizable.strings": "\"a.title\" = \"A\";\n",
            "App/en.lproj/Plist.strings": "\"b.title\" = \"B\";\n",
        ])
        let result = try MigrateCommand.run(project: try Project.discover(root: root), apply: false)
        #expect(result.notes.filter { $0.contains("references") }.map { $0.contains("Localizable.strings") } == [true])
    }

    @Test func failedLegacyDeletesAreReportedNotThrown() throws {
        // Folder permissions do not stop root, so the delete cannot be made to fail.
        guard getuid() != 0 else { return }
        let root = try TestSupport.makeProject(["App/en.lproj/Localizable.strings": "\"a.title\" = \"A\";\n"])
        let folder = root.appendingPathComponent("App/en.lproj")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
        let result = try MigrateCommand.run(project: try Project.discover(root: root), apply: true, removeLegacy: true)
        #expect(result.removed.isEmpty)
        #expect(result.notes.contains { $0.hasPrefix("could not remove App/en.lproj/Localizable.strings") })
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("App/Localizable.xcstrings").path))
    }
}
