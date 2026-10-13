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
        #expect(Set(tools.map(\.name)) == ["l10n_lint", "l10n_status", "l10n_plan_fixes", "l10n_apply_fixes", "l10n_translate", "l10n_set_translations", "l10n_add_keys", "l10n_accept"])
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
}
