import Foundation
import Testing
@testable import L10nCore

@Suite("Fixer")
struct FixerTests {
    @Test func planProposesKeysCommentsAndReplacements() throws {
        let project = try Project.discover(root: try TestSupport.copyFixture("SampleApp"))
        let plan = try Fixer(project: project).plan()
        func item(_ file: String, _ line: Int) -> FixItem? { plan.items.first { $0.file.hasSuffix(file) && $0.line == line } }

        let welcome = try #require(item("ContentView.swift", 14))
        #expect(welcome.key == "content.welcomeBack")
        #expect(welcome.replacement == "Text(.contentWelcomeBack)")
        #expect(welcome.migrateFrom == "Welcome back")
        #expect(welcome.status == .ready)

        let hello = try #require(item("ContentView.swift", 15))
        #expect(hello.status == .needsReview, "name's type is a guess")
        #expect(hello.sourceValue == "Hello, %@!")
        #expect(hello.replacement == "Text(.contentHello(name))")

        let save = try #require(item("ContentView.swift", 19))
        #expect(save.key == "content.saveChanges.button")
        #expect(save.replacement == "String(localized: .contentSaveChangesButton)")
        #expect(save.comment == "Button title in ContentView.")

        // "Cancel" in two screens shares one common key.
        let cancels = plan.items.filter { $0.sourceValue == "Cancel" }
        #expect(cancels.count == 2)
        #expect(Set(cancels.map(\.key)) == ["common.cancel.button"])

        // Existing manual key with the same text and a clean symbol is reused.
        #expect(item("ContentView.swift", 21)?.reusesExistingKey == false, "settings.darkMode collides with settings.dark_mode")

        let concatenation = try #require(item("ContentView.swift", 25))
        #expect(concatenation.rule == Rules.concatenation.id)
        #expect(concatenation.replacement == "String(localized: .contentGreeting(name))")
    }

    @Test func applyRewritesCodeAndCatalogAndIsIdempotent() throws {
        let root = try TestSupport.copyFixture("SampleApp")
        let project = try Project.discover(root: root)
        let fixer = Fixer(project: project)
        let plan = try fixer.plan()
        let result = try fixer.apply(plan, includeReview: true)
        #expect(result.skipped.isEmpty, "\(result.skipped)")
        #expect(result.filesChanged == ["SampleApp/ContentView.swift", "SampleApp/SettingsViewController.swift", "SampleApp/Tab.swift"])

        let catalog = try StringCatalog.load(root.appendingPathComponent("SampleApp/Localizable.xcstrings"))
        let welcome = try #require(catalog.entry("content.welcomeBack"))
        #expect(welcome.isManual)
        #expect(welcome.localization("en")?.stringUnit == StringUnit(state: "translated", value: "Welcome back"))
        #expect(welcome.localization("de")?.stringUnit?.value == "Willkommen zurück", "translations migrate from the text key")
        #expect(catalog.entry("Welcome back")?.isStale == true)
        #expect(catalog.entry("content.hello")?.comment == "Text in ContentView. %@ is name.")

        let content = try String(contentsOf: root.appendingPathComponent("SampleApp/ContentView.swift"), encoding: .utf8)
        #expect(content.contains("Text(.contentWelcomeBack)"))
        #expect(content.contains("Button(String(localized: .contentSaveChangesButton)) { save() }"))
        #expect(content.contains("Text(verbatim: \"Build 42\")"))

        // Re-planning finds nothing left to fix.
        let again = try Fixer(project: try Project.discover(root: root)).plan()
        #expect(again.items.isEmpty, "\(again.items.map(\.original))")
        let lint = try Linter(project: try Project.discover(root: root)).run(LintOptions(rules: ["L10N001", "L10N002", "L10N003"]))
        #expect(lint.diagnostics.isEmpty)
    }

    @Test func applyRefusesChangedFiles() throws {
        let root = try TestSupport.copyFixture("SampleApp")
        let project = try Project.discover(root: root)
        let plan = try Fixer(project: project).plan()
        let file = root.appendingPathComponent("SampleApp/Tab.swift")
        try (String(contentsOf: file, encoding: .utf8) + "\n// edited\n").write(to: file, atomically: true, encoding: .utf8)
        #expect(throws: L10nError.self) { try Fixer(project: project).apply(plan) }
    }

    @Test func editedPlanKeysAreValidated() throws {
        let root = try TestSupport.copyFixture("SampleApp")
        let project = try Project.discover(root: root)
        var plan = try Fixer(project: project).plan(files: ["SampleApp/Tab.swift"])
        #expect(plan.items.count == 2)
        plan.items[0].key = "Bad Key"
        plan.items[1].key = "tabs.profile.title"
        let result = try Fixer(project: project).apply(plan)
        #expect(result.skipped[plan.items[0].id]?.contains("segments") == true)
        #expect(result.applied == [plan.items[1].id])
        let tab = try String(contentsOf: root.appendingPathComponent("SampleApp/Tab.swift"), encoding: .utf8)
        #expect(tab.contains("return String(localized: .tabsProfileTitle)"))
        #expect(tab.contains("return \"Home\""))
    }

    @Test func literalStyleWithoutSymbols() throws {
        let root = try TestSupport.makeProject([
            ".l10n-agent.yml": "codeStyle: literal\n",
            "App/Settings.xcstrings": TestSupport.catalogJSON([:]),
            "App/View.swift": """
            import UIKit
            final class ProfileView {
                func update(user: User) {
                    label.text = "Hello \\(user.name)"
                    other.text = "Saved \\"draft\\"\\n"
                }
            }
            """,
        ])
        let project = try Project.discover(root: root)
        let plan = try Fixer(project: project).plan()
        #expect(plan.codeStyle == "literal")
        #expect(plan.items.map(\.replacement) == [
            #"String(localized: "profile.hello.label", defaultValue: "Hello \(user.name)", table: "Settings", comment: "Label in ProfileView. %@ is user.name.")"#,
            #"String(localized: "profile.savedDraft.label", defaultValue: "Saved \"draft\"\n", table: "Settings", comment: "Label in ProfileView.")"#,
        ])
        _ = try Fixer(project: project).apply(plan, includeReview: true)
        let catalog = try StringCatalog.load(root.appendingPathComponent("App/Settings.xcstrings"))
        #expect(catalog.entry("profile.savedDraft.label")?.localization("en")?.stringUnit?.value == "Saved \"draft\"\n")
    }

    @Test func createsCatalogWhenMissing() throws {
        let root = try TestSupport.makeProject([
            "App/View.swift": "import UIKit\nfunc f() { label.text = \"Welcome aboard\" }\n",
        ])
        let project = try Project.discover(root: root)
        let result = try Fixer(project: project).apply(try Fixer(project: project).plan())
        #expect(result.catalogsChanged == ["App/Localizable.xcstrings"])
        #expect(result.notes.contains { $0.contains("member of your app target") })
    }

    @Test(.enabled(if: TestSupport.hasXcstringstool && TestSupport.hasIOSSimulatorSDK))
    func fixedSampleAppTypeChecksAgainstGeneratedSymbols() throws {
        let root = try TestSupport.copyFixture("SampleApp")
        // Remove the deliberate symbol collision so Xcode can generate symbols.
        var catalog = try StringCatalog.load(root.appendingPathComponent("SampleApp/Localizable.xcstrings"))
        catalog.setEntry("settings.dark_mode", nil)
        try catalog.write()

        let project = try Project.discover(root: root)
        let result = try Fixer(project: project).apply(try Fixer(project: project).plan(), includeReview: true)
        #expect(result.skipped.isEmpty, "\(result.skipped)")

        let generated = root.appendingPathComponent("Generated")
        try FileManager.default.createDirectory(at: generated, withIntermediateDirectories: true)
        let (genStatus, genOutput) = TestSupport.shell(["xcrun", "xcstringstool", "generate-symbols", root.appendingPathComponent("SampleApp/Localizable.xcstrings").path, "-o", generated.path, "-l", "swift"])
        #expect(genStatus == 0, "\(genOutput)")

        let sources = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("SampleApp").path)
            .filter { $0.hasSuffix(".swift") }.map { root.appendingPathComponent("SampleApp/\($0)").path }
        let (status, output) = TestSupport.shell(["xcrun", "--sdk", "iphonesimulator", "swiftc", "-typecheck", "-target", "arm64-apple-ios17.0-simulator", "-module-name", "SampleApp"] + sources + [generated.appendingPathComponent("GeneratedStringSymbols_Localizable.swift").path])
        #expect(status == 0, "\(output)")
    }
}
