import Foundation
import L10nCore
import MCP
import Testing
@testable import L10nMCP

@Suite("MCP server")
struct MCPServerTests {
    func makeProject() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("l10n-mcp-\(UUID().uuidString)")
        let files: [String: String] = [
            ".l10n-agent.yml": "locales: [de]\ncodeStyle: symbols\n",
            "App/Localizable.xcstrings": #"{"sourceLanguage":"en","strings":{"home.title":{"comment":"Title","extractionState":"manual","localizations":{"en":{"stringUnit":{"state":"translated","value":"Home"}}}}},"version":"1.1"}"#,
            "App/SettingsView.swift": "import UIKit\nfunc f() { label.text = \"Notifications\" }\n",
        ]
        for (path, content) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
        }
        return root
    }

    func connect(root: URL) async throws -> Client {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let l10n = L10nMCPServer(root: root, version: "test")
        let server = l10n.makeServer()
        await l10n.register(on: server)
        try await server.start(transport: serverTransport)
        let client = Client(name: "test", version: "1")
        _ = try await client.connect(transport: clientTransport)
        return client
    }

    func text(_ content: [Tool.Content]) -> String {
        content.compactMap { if case .text(let text, _, _) = $0 { return text } else { return nil } }.joined()
    }

    @Test func listsTools() async throws {
        let client = try await connect(root: try makeProject())
        let (tools, _) = try await client.listTools()
        #expect(Set(tools.map(\.name)) == ["l10n_lint", "l10n_status", "l10n_plan_fixes", "l10n_apply_fixes", "l10n_translate", "l10n_set_translations", "l10n_add_keys", "l10n_accept", "l10n_migrate_strings", "l10n_remove_keys", "l10n_rename_key"])
    }

    @Test func lintPlanApplyAndTranslateLoop() async throws {
        let root = try makeProject()
        let client = try await connect(root: root)

        let (lintContent, lintError) = try await client.callTool(name: "l10n_lint", arguments: ["scope": "code"])
        #expect(lintError == false)
        let report = try JSONDecoder().decode(LintReport.self, from: Data(text(lintContent).utf8))
        #expect(report.diagnostics.map(\.rule) == ["L10N001"])

        let (planContent, _) = try await client.callTool(name: "l10n_plan_fixes", arguments: ["finding_ids": .array([.string(report.diagnostics[0].id)])])
        var plan = try JSONDecoder().decode(FixPlan.self, from: Data(text(planContent).utf8))
        #expect(plan.items.count == 1)
        plan.items[0].key = "settings.notifications.title"
        plan.items[0].comment = "Settings section title"

        let planValue = try JSONDecoder().decode(Value.self, from: JSONEncoder().encode(plan))
        let (applyContent, applyError) = try await client.callTool(name: "l10n_apply_fixes", arguments: ["plan": planValue])
        #expect(applyError == false, "\(text(applyContent))")
        let source = try String(contentsOf: root.appendingPathComponent("App/SettingsView.swift"), encoding: .utf8)
        #expect(source.contains("label.text = String(localized: .settingsNotificationsTitle)"))

        let (setContent, _) = try await client.callTool(name: "l10n_set_translations", arguments: [
            "translations": [["key": "settings.notifications.title", "locale": "de", "value": "Mitteilungen"], ["key": "home.title", "locale": "de", "value": "Start"]],
        ])
        #expect(text(setContent).contains("\"translated\" : 2"))

        let (statusContent, _) = try await client.callTool(name: "l10n_status")
        let status = try JSONDecoder().decode(StatusReport.self, from: Data(text(statusContent).utf8))
        #expect(status.catalogs.first?.locales.first?.needsReview == 2)
    }

    @Test func addKeysReturnsSymbols() async throws {
        let client = try await connect(root: try makeProject())
        let (content, isError) = try await client.callTool(name: "l10n_add_keys", arguments: [
            "keys": [["key": "profile.greeting", "value": "Hello %@", "comment": "Greeting"], ["key": "Bad Key", "value": "x"]],
        ])
        #expect(isError == false)
        let result = try JSONDecoder().decode(AddKeysResult.self, from: Data(text(content).utf8))
        #expect(result.added == ["profile.greeting"])
        #expect(result.symbols["profile.greeting"] == ".profileGreeting")
        #expect(result.rejected["Bad Key"] != nil)
    }

    @Test func concurrentMutationsAreSerialized() async throws {
        let client = try await connect(root: try makeProject())
        let results = try await withThrowingTaskGroup(of: Bool?.self) { group in
            for index in 0..<4 {
                group.addTask {
                    try await client.callTool(name: "l10n_add_keys", arguments: [
                        "keys": [["key": "profile.item\(index)", "value": "Item \(index)", "comment": "c"]],
                    ]).isError
                }
            }
            return try await group.reduce(into: [Bool?]()) { $0.append($1) }
        }
        #expect(results.allSatisfy { $0 == false })
        let (statusContent, _) = try await client.callTool(name: "l10n_status")
        #expect(text(statusContent).contains("\"keys\" : 5"))
    }

    @Test func rejectsPathsOutsideTheProject() async throws {
        let client = try await connect(root: try makeProject())
        let (content, isError) = try await client.callTool(name: "l10n_lint", arguments: ["paths": ["../../etc"]])
        #expect(isError == true)
        #expect(text(content).contains("outside the project root"))
    }

    @Test func removeKeysOverMCPCannotForceOrDeleteUsedKeys() async throws {
        let root = try makeProject()
        try "import SwiftUI\nfunc f() -> String { String(localized: \"home.title\") }\n".write(to: root.appendingPathComponent("App/Home.swift"), atomically: true, encoding: .utf8)
        let client = try await connect(root: root)
        let (forced, forcedError) = try await client.callTool(name: "l10n_remove_keys", arguments: ["keys": ["home.title"], "force": true])
        #expect(forcedError == true && text(forced).contains("Unknown argument(s)"))
        let (content, isError) = try await client.callTool(name: "l10n_remove_keys", arguments: ["keys": ["home.title"]])
        #expect(isError == false)
        let result = try JSONDecoder().decode(KeyChangeResult.self, from: Data(text(content).utf8))
        #expect(result.removed.isEmpty && result.rejected["home.title"]?.contains("still referenced") == true)
        let (renamed, _) = try await client.callTool(name: "l10n_rename_key", arguments: ["from": "home.title", "to": "home.gone"])
        #expect(text(renamed).contains("pass --update-code"))
    }

    @Test func setTranslationsOverMCPNeverReplacesApprovedValues() async throws {
        let root = try makeProject()
        let catalog = #"{"sourceLanguage":"en","strings":{"home.title":{"comment":"Title","extractionState":"manual","localizations":{"de":{"stringUnit":{"state":"translated","value":"Start"}},"en":{"stringUnit":{"state":"translated","value":"Home"}}}}},"version":"1.1"}"#
        try catalog.write(to: root.appendingPathComponent("App/Localizable.xcstrings"), atomically: true, encoding: .utf8)
        let client = try await connect(root: root)
        let (refused, _) = try await client.callTool(name: "l10n_set_translations", arguments: ["translations": [["key": "home.title", "locale": "de", "value": "Startseite"]]])
        #expect(text(refused).contains("an approved translation exists"))
        let (unknown, isError) = try await client.callTool(name: "l10n_set_translations", arguments: ["translations": [["key": "home.title", "locale": "de", "value": "Startseite"]], "replace_approved": true])
        #expect(isError == true && text(unknown).contains("Unknown argument(s)"))
    }

    // MARK: Catalog scope

    struct AcceptResponse: Decodable { var updated: Int }

    /// Two targets that share `color.name.blue` and its approved German translation.
    func makeTwoCatalogProject() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("l10n-mcp-scope-\(UUID().uuidString)")
        let catalog = #"{"sourceLanguage":"en","strings":{"color.name.blue":{"comment":"Color","extractionState":"manual","localizations":{"de":{"stringUnit":{"state":"translated","value":"Blau"}},"en":{"stringUnit":{"state":"translated","value":"Blue"}}}}},"version":"1.1"}"#
        for (path, content) in [".l10n-agent.yml": "locales: [de]\n", "iOS/Localizable.xcstrings": catalog, "Mac/Localizable.xcstrings": catalog] {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
        }
        return root
    }

    /// Seeds fingerprints, then changes both English sources so both German translations are stale.
    func makeStaleTwoCatalogProject() async throws -> (URL, Client) {
        let root = try makeTwoCatalogProject()
        let client = try await connect(root: root)
        let (seed, seedError) = try await client.callTool(name: "l10n_accept")
        #expect(seedError == false, "\(text(seed))")
        for target in ["iOS", "Mac"] {
            let url = root.appendingPathComponent("\(target)/Localizable.xcstrings")
            let source = try String(contentsOf: url, encoding: .utf8)
            try source.replacingOccurrences(of: #""value":"Blue""#, with: #""value":"Deep Blue""#).write(to: url, atomically: true, encoding: .utf8)
        }
        return (root, client)
    }

    func bytes(_ root: URL, _ path: String) throws -> Data {
        try Data(contentsOf: root.appendingPathComponent(path))
    }

    @Test func acceptScopeIsAdvertisedAndLimitsUpdatesToOneCatalog() async throws {
        let (root, client) = try await makeStaleTwoCatalogProject()

        let (tools, _) = try await client.listTools()
        let accept = try #require(tools.first { $0.name == "l10n_accept" })
        guard case .object(let schema) = accept.inputSchema,
              case .object(let properties)? = schema["properties"],
              case .object(let catalog)? = properties["catalog"],
              case .string(let type)? = catalog["type"]
        else {
            Issue.record("l10n_accept does not declare a string catalog property")
            return
        }
        #expect(type == "string")
        if case .array(let required)? = schema["required"] {
            let names = required.compactMap { value -> String? in
                if case .string(let name) = value { return name }
                return nil
            }
            #expect(!names.contains("catalog"), "catalog stays optional")
        }

        let iosBytes = try bytes(root, "iOS/Localizable.xcstrings")
        let macBytes = try bytes(root, "Mac/Localizable.xcstrings")

        let (content, isError) = try await client.callTool(name: "l10n_accept", arguments: [
            "catalog": "iOS/Localizable.xcstrings", "keys": ["color.name.blue"], "locales": ["de"],
        ])
        #expect(isError == false, "\(text(content))")
        #expect(try JSONDecoder().decode(AcceptResponse.self, from: Data(text(content).utf8)).updated == 1)
        #expect(try bytes(root, "iOS/Localizable.xcstrings") == iosBytes)
        #expect(try bytes(root, "Mac/Localizable.xcstrings") == macBytes)

        // The Mac target still needs review.
        let (lintContent, _) = try await client.callTool(name: "l10n_lint", arguments: ["scope": "catalogs", "rules": ["L10N103"]])
        let report = try JSONDecoder().decode(LintReport.self, from: Data(text(lintContent).utf8))
        #expect(report.diagnostics.map(\.file) == ["Mac/Localizable.xcstrings"])
        #expect(report.diagnostics.first?.key == "color.name.blue")
        #expect(report.diagnostics.first?.locales == ["de"])

        // Repeating the scoped call changes nothing.
        let settled = try FingerprintStore.load(root: root).serialized()
        let (repeatContent, repeatError) = try await client.callTool(name: "l10n_accept", arguments: [
            "catalog": "iOS/Localizable.xcstrings", "keys": ["color.name.blue"], "locales": ["de"],
        ])
        #expect(repeatError == false)
        #expect(try JSONDecoder().decode(AcceptResponse.self, from: Data(text(repeatContent).utf8)).updated == 0)
        #expect(try FingerprintStore.load(root: root).serialized() == settled)

        // A basename that only matches nested catalogs is refused before anything changes.
        let (badContent, badError) = try await client.callTool(name: "l10n_accept", arguments: [
            "catalog": "Localizable.xcstrings", "keys": ["color.name.blue"], "locales": ["de"],
        ])
        #expect(badError == true)
        #expect(text(badContent).contains("Localizable.xcstrings"))
        #expect(text(badContent).contains("discovered"))
        #expect(try FingerprintStore.load(root: root).serialized() == settled)

        let (outsideContent, outsideError) = try await client.callTool(name: "l10n_accept", arguments: [
            "catalog": "../Outside.xcstrings", "keys": ["color.name.blue"], "locales": ["de"],
        ])
        #expect(outsideError == true)
        #expect(text(outsideContent).contains("outside the project root"))
        #expect(try FingerprintStore.load(root: root).serialized() == settled)

        // Without a catalog the remaining German record is updated too.
        let (allContent, allError) = try await client.callTool(name: "l10n_accept", arguments: [
            "keys": ["color.name.blue"], "locales": ["de"],
        ])
        #expect(allError == false)
        #expect(try JSONDecoder().decode(AcceptResponse.self, from: Data(text(allContent).utf8)).updated == 1)
        let (afterContent, _) = try await client.callTool(name: "l10n_lint", arguments: ["scope": "catalogs", "rules": ["L10N103"]])
        let after = try JSONDecoder().decode(LintReport.self, from: Data(text(afterContent).utf8))
        #expect(after.diagnostics.isEmpty)

        // Undeclared arguments are still refused.
        let (unknownContent, unknownError) = try await client.callTool(name: "l10n_accept", arguments: ["force": true])
        #expect(unknownError == true)
        #expect(text(unknownContent).contains("Unknown argument(s)"))
    }
}
