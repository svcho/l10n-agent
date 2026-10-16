import Foundation
import Testing
@testable import L10nCore

/// Regression tests for the findings of the pangi rerun (R1–R11).
@Suite("Rerun regressions")
struct RerunRegressionTests {
    func lint(_ root: URL, rules: Set<String>) throws -> [Diagnostic] {
        try Linter(project: try Project.discover(root: root)).run(LintOptions(rules: rules)).diagnostics
    }

    // R1
    @Test func unusedKeysAreCountedPerTarget() throws {
        let root = try TestSupport.makeProject([
            "App/Localizable.xcstrings": TestSupport.catalogJSON(["common.em.dash": TestSupport.manual("—")]),
            "App/Settings.swift": "func f() { _ = String(localized: \"common.em.dash\") }\n",
            "Widget/Localizable.xcstrings": TestSupport.catalogJSON(["common.em.dash": TestSupport.manual("—")]),
            "Widget/W.swift": "func g() {}\n",
        ])
        #expect(try lint(root, rules: ["L10N106"]).map(\.file) == ["Widget/Localizable.xcstrings"])
    }

    @Test func keysHeldBySharedPackagesCountForEveryCatalog() throws {
        let root = try TestSupport.makeProject([
            "App/Localizable.xcstrings": TestSupport.catalogJSON(["color.name.blue": TestSupport.manual("Blue")]),
            "App/Edit.swift": "func f(name: String) -> String { NSLocalizedString(name, comment: \"Color\") }\n",
            "Shared/Package.swift": "// swift-tools-version: 6.0\n",
            "Shared/Sources/Shared/Colors.swift": "let colors = [(\"#0055CC\", \"color.name.blue\")]\n",
        ])
        #expect(try lint(root, rules: ["L10N106"]).isEmpty)
    }

    @Test func renameRefusesKeysUsedAsPlainOrBuiltStrings() throws {
        let files = [
            "App/Localizable.xcstrings": TestSupport.catalogJSON([
                "color.name.blue": TestSupport.manual("Blue", translations: ["de": TestSupport.unit("Blau")]),
                "onboarding.step1": TestSupport.manual("Welcome", translations: ["de": TestSupport.unit("Willkommen")]),
            ]),
            "App/Edit.swift": """
            func f(name: String) -> String { NSLocalizedString(name, comment: "Color") }
            func step(_ n: Int) -> String { NSLocalizedString("onboarding.step\\(n)", comment: "") }
            """,
            "Shared/Package.swift": "// swift-tools-version: 6.0\n",
            "Shared/Sources/Shared/Colors.swift": "let colors = [(\"#0055CC\", \"color.name.blue\")]\n",
        ]
        let root = try TestSupport.makeProject(files)
        let project = try Project.discover(root: root)
        let data = try KeysCommand.rename(project: project, from: "color.name.blue", to: "color.name.azure", updateCode: true)
        #expect(data.renamed.isEmpty)
        #expect(data.rejected["color.name.blue"]?.contains("Shared/Sources/Shared/Colors.swift:1") == true)
        let built = try KeysCommand.rename(project: project, from: "onboarding.step1", to: "onboarding.welcome", updateCode: true)
        #expect(built.rejected["onboarding.step1"]?.contains("App/Edit.swift:2") == true)
        // The translations stay, and remove still sees the key as used.
        #expect(try KeysCommand.remove(project: try Project.discover(root: root), keys: ["color.name.blue", "onboarding.step1"]).removed.isEmpty)
        let catalog = try StringCatalog.load(root.appendingPathComponent("App/Localizable.xcstrings"))
        #expect(catalog.entry("color.name.blue")?.localization("de")?.stringUnit?.value == "Blau")
    }

    // R2
    @Test func keysRemoveRefusesReferencedKeys() throws {
        let root = try TestSupport.makeProject([
            "App/Localizable.xcstrings": TestSupport.catalogJSON([
                "dead.key": TestSupport.manual("Dead", translations: ["de": TestSupport.unit("Tot")]),
                "live.key": TestSupport.manual("Live"),
            ]),
            ".l10n-agent/fingerprints.json": #"{"catalogs":{"App/Localizable.xcstrings":{"dead.key":{"de":"abc"}}},"version":1}"#,
            "App/V.swift": "func f() { _ = String(localized: \"live.key\") }\n",
        ])
        let project = try Project.discover(root: root)
        let result = try KeysCommand.remove(project: project, keys: ["dead.key", "live.key", "missing.key"])
        #expect(result.removed == ["dead.key"])
        #expect(result.rejected["live.key"]?.contains("still referenced") == true)
        #expect(result.rejected["missing.key"] == "not found in any readable catalog")
        let catalog = try StringCatalog.load(root.appendingPathComponent("App/Localizable.xcstrings"))
        #expect(catalog.keys == ["live.key"])
        #expect(try FingerprintStore.load(root: root).fingerprint(catalog: "App/Localizable.xcstrings", key: "dead.key", locale: "de") == nil)
        #expect(try KeysCommand.remove(project: project, keys: ["live.key"], force: true).removed == ["live.key"])
    }

    @Test func keysRenameMovesTranslationsFingerprintsAndCode() throws {
        let root = try TestSupport.makeProject([
            ".l10n-agent.yml": "codeStyle: symbols\n",
            "App/Localizable.xcstrings": TestSupport.catalogJSON([
                "deeplink.message.and_more": TestSupport.manual("and more", translations: ["de": TestSupport.unit("und mehr")]),
                "other.key": TestSupport.manual("Other"),
            ]),
            ".l10n-agent/fingerprints.json": #"{"catalogs":{"App/Localizable.xcstrings":{"deeplink.message.and_more":{"de":"abc"}}},"version":1}"#,
            "App/V.swift": """
            import SwiftUI
            func f() -> String { NSLocalizedString("deeplink.message.and_more", comment: "") }
            struct V: View { var body: some View { Text(.deeplinkMessageAndMore) } }
            """,
        ])
        let project = try Project.discover(root: root)
        #expect(try KeysCommand.rename(project: project, from: "deeplink.message.and_more", to: "other.key").rejected.values.first?.contains("already exists") == true)
        #expect(try KeysCommand.rename(project: project, from: "deeplink.message.and_more", to: "Bad Key").rejected.values.first?.contains("segments") == true)

        // While code uses the key, a rename without --update-code is refused (code would
        // point at a missing key, and a later remove could delete its translations).
        let refused = try KeysCommand.rename(project: project, from: "deeplink.message.and_more", to: "deeplink.message.andMore")
        #expect(refused.renamed.isEmpty)
        #expect(refused.rejected.values.first?.contains("2 reference(s) in code") == true)

        let fresh = try TestSupport.makeProject([
            ".l10n-agent.yml": "codeStyle: symbols\n",
            "App/Localizable.xcstrings": TestSupport.catalogJSON(["deeplink.message.and_more": TestSupport.manual("and more", translations: ["de": TestSupport.unit("und mehr")])]),
            ".l10n-agent/fingerprints.json": #"{"catalogs":{"App/Localizable.xcstrings":{"deeplink.message.and_more":{"de":"abc"}}},"version":1}"#,
            "App/V.swift": """
            import SwiftUI
            func f() -> String { NSLocalizedString("deeplink.message.and_more", comment: "") }
            struct V: View { var body: some View { Text(.deeplinkMessageAndMore) } }
            """,
        ])
        let renamed = try KeysCommand.rename(project: try Project.discover(root: fresh), from: "deeplink.message.and_more", to: "deeplink.message.andMore", updateCode: true)
        #expect(renamed.filesChanged == ["App/V.swift"])
        let code = try String(contentsOf: fresh.appendingPathComponent("App/V.swift"), encoding: .utf8)
        #expect(code.contains("NSLocalizedString(\"deeplink.message.andMore\"") && code.contains("Text(.deeplinkMessageAndMore)"))
        let catalog = try StringCatalog.load(fresh.appendingPathComponent("App/Localizable.xcstrings"))
        #expect(catalog.entry("deeplink.message.andMore")?.localization("de")?.stringUnit == StringUnit(state: "translated", value: "und mehr"))
        #expect(catalog.entry("deeplink.message.and_more") == nil)
        #expect(try FingerprintStore.load(root: fresh).fingerprint(catalog: "App/Localizable.xcstrings", key: "deeplink.message.andMore", locale: "de") == "abc")
    }

    // R3
    @Test func errorMessagesUseTheErrorScopeAndWholePhrases() throws {
        let root = try TestSupport.makeProject([
            ".l10n-agent.yml": "codeStyle: literal\n",
            "App/Localizable.xcstrings": TestSupport.catalogJSON([
                "error.unknown": TestSupport.manual("Unknown"),
                "error.network": TestSupport.manual("Network"),
                "error.storage": TestSupport.manual("Storage"),
            ]),
            "App/AppDelegate.swift": """
            final class AppDelegate {
                func currentModelContext() throws {
                    throw NSError(domain: "app", code: 1, userInfo: [NSLocalizedDescriptionKey: "Model container not yet initialized"])
                }
            }
            """,
        ])
        let plan = try Fixer(project: try Project.discover(root: root)).plan()
        #expect(plan.items.map(\.key) == ["error.modelContainerNotInitialized.message"], "the negation is kept")
        // R11: whether the error is shown cannot be seen, so it needs review.
        #expect(plan.items.first?.status == .needsReview)
        #expect(plan.items.first?.reason?.contains("NSError message") == true)
    }

    // R5, R8
    @Test func statusReportsKeysWithoutText() throws {
        let root = try TestSupport.makeProject([
            ".l10n-agent.yml": "locales: [de]\n",
            "L.xcstrings": TestSupport.catalogJSON([
                "a.title": TestSupport.manual("A title", translations: ["de": TestSupport.unit("A Titel")]),
                "common.dash": TestSupport.manual("—"),
                "%lld": ["shouldTranslate": false],
            ]),
        ])
        let report = try StatusCommand.run(project: try Project.discover(root: root))
        #expect(report.catalogs[0].withoutText == 1 && report.catalogs[0].doNotTranslate == 1)
        #expect(StatusCommand.text(report).contains("(3 keys, 2 manual; 1 without text and 1 don't translate not counted)"))
    }

    // R6
    @Test func migrationUsesCodeAndSectionComments() throws {
        let english = """
        /* pangiMac — English */

        /* Settings */

        "settings.title" = "Settings";
        "settings.lock" = "Lock";
        /* Shown above the list. */
        "settings.header" = "Header";
        "settings.footer" = "Footer";

        "settings.version" = "Version";
        """
        let root = try TestSupport.makeProject([
            "App/en.lproj/Localizable.strings": english,
            "App/V.swift": "func f() -> String { NSLocalizedString(\"settings.lock\", comment: \"Button that locks the app now.\") }\n",
        ])
        _ = try MigrateCommand.run(project: try Project.discover(root: root), apply: true)
        let catalog = try StringCatalog.load(root.appendingPathComponent("App/Localizable.xcstrings"))
        #expect(catalog.entry("settings.title")?.comment == "Settings", "the file title is skipped, the section applies")
        #expect(catalog.entry("settings.lock")?.comment == "Button that locks the app now.", "code comments beat section comments")
        #expect(catalog.entry("settings.header")?.comment == "Shown above the list.")
        #expect(catalog.entry("settings.footer")?.comment == "Shown above the list.", "a comment heads its block of entries")
        #expect(catalog.entry("settings.version")?.comment == "Settings", "after a blank line the section applies again")
    }

    // R7
    @Test func filesOfTestTargetsAreNotScanned() throws {
        let pbxproj = """
        // !$*UTF8*$!
        {
            archiveVersion = 1;
            objectVersion = 77;
            objects = {
                G1 = { isa = PBXFileSystemSynchronizedRootGroup; path = AppTests; sourceTree = "<group>"; };
                G2 = { isa = PBXFileSystemSynchronizedRootGroup; path = App; sourceTree = "<group>"; };
                T1 = { isa = PBXNativeTarget; name = AppTests; productType = "com.apple.product-type.bundle.unit-test"; fileSystemSynchronizedGroups = (G1); };
                T2 = { isa = PBXNativeTarget; name = App; productType = "com.apple.product-type.application"; fileSystemSynchronizedGroups = (G2); };
            };
            rootObject = P1;
        }
        """
        let root = try TestSupport.makeProject([
            "App.xcodeproj/project.pbxproj": pbxproj,
            "AppTests/Polling.swift": "final class Poller { func f() { label.text = \"Waiting for sync\" } }\n",
            "App/V.swift": "final class Screen { func f() { label.text = \"Shown for sure\" } }\n",
        ])
        let project = try Project.discover(root: root)
        #expect(project.xcode.testFolders.map(\.lastPathComponent) == ["AppTests"])
        #expect(try lint(root, rules: ["L10N001"]).map(\.file) == ["App/V.swift"])
        #expect(DoctorCommand.swiftFilesDetail(project) == "1 Swift file(s) scanned (1 test or generated file(s) skipped)")
    }

    // R9
    @Test func wrappedTranslationsAreReported() async throws {
        #expect(FormatParity.wrapperProblem(source: "An error occurred: %@", target: #"{"text":"Ein Fehler: %@"}"#) != nil)
        #expect(FormatParity.wrapperProblem(source: "[beta] Feature", target: "[Beta] Funktion") == nil, "brackets in prose are fine")
        #expect(FormatParity.wrapperProblem(source: "Hello", target: "```\nHallo\n```") != nil)
        let root = try TestSupport.makeProject([
            ".l10n-agent.yml": "locales: [de]\n",
            "L.xcstrings": TestSupport.catalogJSON(["error.unknown": TestSupport.manual("An error occurred: %@", translations: ["de": TestSupport.unit(#"{"text":"Ein Fehler ist aufgetreten: %@"}"#)])]),
        ])
        let findings = try lint(root, rules: ["L10N113"])
        #expect(findings.map(\.key) == ["error.unknown"] && findings.first?.severity == .warning)

        // translate rejects such model output and retries.
        let model = EchoTranslator(transform: { _, text in #"{"text":"\#(text)"}"# }).model()
        let fresh = try TestSupport.makeProject([".l10n-agent.yml": "locales: [de]\ntranslator: { maxRetries: 0 }\n", "L.xcstrings": TestSupport.catalogJSON(["a.title": TestSupport.manual("Hello")])])
        let report = try await TranslationEngine(project: try Project.discover(root: fresh)).run(TranslateOptions(), model: model)
        #expect(report.translated == 0)
        #expect(report.failed.first?.reason.contains("JSON value") == true)
    }

    // R10
    @Test func replacingApprovedTranslationsIsExplicit() throws {
        let root = try TestSupport.makeProject([
            ".l10n-agent.yml": "locales: [de]\n",
            "L.xcstrings": TestSupport.catalogJSON(["error.unknown": TestSupport.manual("An error occurred: %@", translations: ["de": TestSupport.unit(#"{"text":"Ein Fehler ist aufgetreten: %@"}"#)])]),
        ])
        let engine = TranslationEngine(project: try Project.discover(root: root))
        let fix = ProvidedTranslation(key: "error.unknown", locale: "de", value: "Ein Fehler ist aufgetreten: %@")
        let refused = try engine.applyProvided([fix])
        #expect(refused.failed.first?.reason.contains("--replace-approved") == true)
        let replaced = try engine.applyProvided([fix], replaceApproved: true)
        #expect(replaced.translated == 1 && replaced.warnings.first?.contains("needs review again") == true)
        let unit = try StringCatalog.load(root.appendingPathComponent("L.xcstrings")).entry("error.unknown")?.localization("de")?.stringUnit
        #expect(unit == StringUnit(state: "needs_review", value: "Ein Fehler ist aufgetreten: %@"))
        // Still validated: a broken replacement is refused.
        #expect(try engine.applyProvided([ProvidedTranslation(key: "error.unknown", locale: "de", value: "Fehler")], replaceApproved: true).failed.count == 1)
    }

    // Review findings on the follow-up

    @Test func renameKeepsTheSourceTextOfExtractedKeys() throws {
        let root = try TestSupport.makeProject([
            ".l10n-agent.yml": "codeStyle: literal\n",
            "App/Localizable.xcstrings": TestSupport.catalogJSON(["Hello world": ["localizations": ["de": TestSupport.unit("Hallo Welt")]]]),
            "App/V.swift": "import SwiftUI\nstruct V: View { var body: some View { Text(\"Hello world\") } }\n",
        ])
        let result = try KeysCommand.rename(project: try Project.discover(root: root), from: "Hello world", to: "home.greeting", updateCode: true)
        #expect(result.renamed == ["Hello world": "home.greeting"])
        let entry = try #require(try StringCatalog.load(root.appendingPathComponent("App/Localizable.xcstrings")).entry("home.greeting"))
        #expect(entry.localization("en")?.stringUnit == StringUnit(state: "translated", value: "Hello world"))
        #expect(entry.isManual && entry.localization("de")?.stringUnit?.value == "Hallo Welt")
        #expect(try String(contentsOf: root.appendingPathComponent("App/V.swift"), encoding: .utf8).contains("Text(\"home.greeting\")"))
    }

    @Test func renameOnlyTouchesLocalizationLookups() throws {
        let root = try TestSupport.makeProject([
            ".l10n-agent.yml": "codeStyle: symbols\n",
            "App/Localizable.xcstrings": TestSupport.catalogJSON(["title": TestSupport.manual("Title")]),
            "App/Settings.xcstrings": TestSupport.catalogJSON(["title": TestSupport.manual("Settings title")]),
            "App/V.swift": """
            import SwiftUI
            struct V: View {
                var body: some View {
                    VStack {
                        Text(.title).font(.title)
                        Text(.Settings.title)
                        Button(String(localized: "title")) {}
                    }
                }
            }
            """,
        ])
        let result = try KeysCommand.rename(project: try Project.discover(root: root), from: "title", to: "home.title", catalog: "App/Localizable.xcstrings", updateCode: true)
        #expect(result.renamed == ["title": "home.title"], "\(result.rejected)")
        let code = try String(contentsOf: root.appendingPathComponent("App/V.swift"), encoding: .utf8)
        #expect(code.contains("Text(.homeTitle).font(.title)"), "only the lookup changes, not .font(.title)")
        #expect(code.contains("Text(.Settings.title)"), "another table's symbol stays")
        #expect(code.contains("String(localized: \"home.title\")"))

        // A plain string equal to the key keeps it alive for L10N106 and keys remove, so the
        // rename is refused rather than stranding it.
        let plain = try TestSupport.makeProject([
            ".l10n-agent.yml": "codeStyle: symbols\n",
            "App/Localizable.xcstrings": TestSupport.catalogJSON(["title": TestSupport.manual("Title")]),
            "App/V.swift": "import SwiftUI\nstruct V: View { var body: some View { Button(String(localized: \"title\")) { print(\"title\") } } }\n",
        ])
        let refused = try KeysCommand.rename(project: try Project.discover(root: plain), from: "title", to: "home.title", updateCode: true)
        #expect(refused.renamed.isEmpty && refused.rejected["title"]?.contains("App/V.swift:2") == true)
        #expect(try String(contentsOf: plain.appendingPathComponent("App/V.swift"), encoding: .utf8).contains("String(localized: \"title\")"), "nothing was rewritten")
    }

    @Test func removeRefusesBuildAndExtractedKeys() throws {
        let root = try TestSupport.makeProject([
            "App/InfoPlist.xcstrings": TestSupport.catalogJSON(["NSCameraUsageDescription": TestSupport.manual("Scan codes", translations: ["de": TestSupport.unit("Codes scannen")])]),
            "App/Localizable.xcstrings": TestSupport.catalogJSON([
                "%lld items": ["localizations": ["de": TestSupport.unit("%lld Einträge")]],
                "Old text": ["extractionState": "stale", "localizations": ["de": TestSupport.unit("Alter Text")]],
            ]),
            "App/Broken.xcstrings": "{ not json",
            "App/V.swift": "import SwiftUI\nstruct V: View { let n: Int; var body: some View { Text(\"\\(n) items\") } }\n",
        ])
        let before = try Data(contentsOf: root.appendingPathComponent("App/InfoPlist.xcstrings"))
        let result = try KeysCommand.remove(project: try Project.discover(root: root), keys: ["NSCameraUsageDescription", "%lld items", "Old text"])
        #expect(result.removed == ["Old text"], "only the stale key can go; a malformed unrelated catalog does not block it")
        #expect(result.rejected["NSCameraUsageDescription"]?.contains("used by the build") == true)
        #expect(result.rejected["%lld items"]?.contains("extracts this key") == true)
        #expect(result.catalogsChanged == ["App/Localizable.xcstrings"])
        #expect(try Data(contentsOf: root.appendingPathComponent("App/InfoPlist.xcstrings")) == before, "untouched catalogs are not rewritten")
    }

    @Test func nestedTestGroupsResolveThroughTheirParents() {
        let pbxproj = """
        {
            objects = {
                M = { isa = PBXGroup; children = (TG, G2); sourceTree = "<group>"; };
                TG = { isa = PBXGroup; children = (G1); path = Tests; sourceTree = "<group>"; };
                G1 = { isa = PBXFileSystemSynchronizedRootGroup; path = App; sourceTree = "<group>"; };
                G2 = { isa = PBXFileSystemSynchronizedRootGroup; path = App; sourceTree = "<group>"; };
                G3 = { isa = PBXFileSystemSynchronizedRootGroup; path = Shared; sourceTree = SOURCE_ROOT; exceptions = (E1); };
                E1 = { isa = PBXFileSystemSynchronizedBuildFileExceptionSet; target = T2; };
                T1 = { isa = PBXNativeTarget; productType = "com.apple.product-type.bundle.unit-test"; fileSystemSynchronizedGroups = (G1, G3); };
                T2 = { isa = PBXNativeTarget; productType = "com.apple.product-type.application"; fileSystemSynchronizedGroups = (G2); };
                P = { isa = PBXProject; mainGroup = M; };
            };
        }
        """
        let folders = XcodeSettings.testFolders(pbxproj: pbxproj, projectDirectory: URL(fileURLWithPath: "/repo"))
        #expect(folders.map(\.path) == ["/repo/Tests/App"], "the nested group resolves under Tests; Shared gives files to the app")
    }

    @Test func rawKeysInErrorMessagesAreStillReported() throws {
        let root = try TestSupport.makeProject([
            "App/Localizable.xcstrings": TestSupport.catalogJSON(["error.network": TestSupport.manual("Network error")]),
            "App/E.swift": "func f() -> NSError { NSError(domain: \"a\", code: 1, userInfo: [NSLocalizedDescriptionKey: \"error.network\"]) }\n",
        ])
        #expect(try lint(root, rules: ["L10N001"]).first?.message.contains("is a catalog key") == true)
    }

    @Test func migrationSkipsHeadersAndPrefersCodeOverBlockComments() throws {
        let english = """
        /* Copyright 2024 Acme Inc. */

        /* Toolbar */
        "toolbar.add" = "Add";
        "toolbar.edit" = "Edit";
        """
        let root = try TestSupport.makeProject([
            "App/en.lproj/Localizable.strings": english,
            "App/V.swift": "func f() -> String { NSLocalizedString(\"toolbar.edit\", comment: \"Edits the selected account.\") }\n",
            "Other/W.swift": "func g() -> String { NSLocalizedString(\"toolbar.add\", comment: \"Another target's comment\") }\n",
        ])
        _ = try MigrateCommand.run(project: try Project.discover(root: root), apply: true)
        let catalog = try StringCatalog.load(root.appendingPathComponent("App/Localizable.xcstrings"))
        #expect(catalog.entry("toolbar.add")?.comment == "Toolbar", "the copyright header is not a section; other targets' code does not count")
        #expect(catalog.entry("toolbar.edit")?.comment == "Edits the selected account.", "code comments beat block comments")
    }

    @Test func replacingWithTheSameValueIsANoOp() throws {
        let root = try TestSupport.makeProject([
            ".l10n-agent.yml": "locales: [de]\n",
            "L.xcstrings": TestSupport.catalogJSON(["a.title": TestSupport.manual("Hello", translations: ["de": TestSupport.unit("Hallo")])]),
        ])
        let report = try TranslationEngine(project: try Project.discover(root: root)).applyProvided([ProvidedTranslation(key: "a.title", locale: "de", value: "Hallo")], replaceApproved: true)
        #expect(report.translated == 0 && report.failed.isEmpty && report.warnings.first?.contains("left as is") == true)
        #expect(try StringCatalog.load(root.appendingPathComponent("L.xcstrings")).entry("a.title")?.localization("de")?.stringUnit?.state == "translated")
    }

    @Test func statusFailureLinesNameTheCatalog() throws {
        let root = try TestSupport.makeProject([
            ".l10n-agent.yml": "locales: [de]\n",
            "L.xcstrings": TestSupport.catalogJSON(["a.title": TestSupport.manual("Hello")]),
        ])
        #expect(StatusCommand.below(try StatusCommand.run(project: try Project.discover(root: root)), percent: 100) == ["L.xcstrings de 0%"])
    }
}
