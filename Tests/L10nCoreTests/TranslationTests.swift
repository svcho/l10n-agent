import Foundation
import Testing
@testable import L10nCore

/// Fake model: answers each item with a deterministic transformation of the masked text.
struct EchoTranslator {
    var transform: @Sendable (_ locale: String, _ text: String) -> String
    var formsTransform: (@Sendable (_ locale: String, _ categories: [String], _ forms: [String: String]) -> [String: String])?

    func model(calls: CallLog? = nil) -> ScriptedChatModel {
        ScriptedChatModel(name: "echo") { system, user in
            await calls?.append(user)
            let locale = system.firstMatch(of: /\(([a-zA-Z-]+)\)\./).map { String($0.1) } ?? "?"
            let request = try JSONSerialization.jsonObject(with: Data(user.utf8)) as! [String: Any]
            let items = request["items"] as! [[String: Any]]
            let translations: [[String: Any]] = items.map { item in
                let id = item["id"] as! String
                if let forms = item["forms"] as? [String: String], let categories = item["categories"] as? [String] {
                    let result = formsTransform?(locale, categories, forms) ?? Dictionary(uniqueKeysWithValues: categories.map { ($0, "[\(locale)] " + (forms["other"] ?? "")) })
                    return ["id": id, "forms": result]
                }
                return ["id": id, "text": transform(locale, item["text"] as! String)]
            }
            let data = try JSONSerialization.data(withJSONObject: ["translations": translations])
            return "<think>planning…</think>```json\n" + String(decoding: data, as: UTF8.self) + "\n```"
        }
    }
}

actor CallLog {
    var prompts: [String] = []
    func append(_ prompt: String) { prompts.append(prompt) }
}

@Suite("Translation engine")
struct TranslationTests {
    func project(_ strings: [String: Any], config: String = "locales: [de, pl]\n") throws -> (URL, Project) {
        let root = try TestSupport.makeProject([
            ".l10n-agent.yml": config,
            "App/Localizable.xcstrings": TestSupport.catalogJSON(strings),
        ])
        return (root, try Project.discover(root: root))
    }

    func catalog(_ root: URL) throws -> StringCatalog {
        try StringCatalog.load(root.appendingPathComponent("App/Localizable.xcstrings"))
    }

    @Test func translatesMissingWithMaskingReorderingAndPlurals() async throws {
        let (root, project) = try project([
            "files.shared": TestSupport.manual("%@ shared %lld files", comment: "%@ is a name"),
            "inbox.unread": [
                "extractionState": "manual",
                "localizations": ["en": ["variations": ["plural": ["one": TestSupport.unit("%lld unread"), "other": TestSupport.unit("%lld unread")]]]],
            ],
            "home.title": TestSupport.manual("Home", translations: ["de": TestSupport.unit("Start")]),
            "brand": ["shouldTranslate": false, "localizations": ["en": TestSupport.unit("Acme")]],
        ])
        let translator = EchoTranslator(transform: { locale, text in
            // Move the second token first, as a German translator might.
            text == "⟦1⟧ shared ⟦2⟧ files" ? "⟦2⟧ Dateien von ⟦1⟧ (\(locale))" : "\(text) (\(locale))"
        }, formsTransform: { locale, categories, _ in
            Dictionary(uniqueKeysWithValues: categories.map { ($0, "⟦1⟧ \($0) \(locale)") })
        })
        let report = try await TranslationEngine(project: project).run(TranslateOptions(), model: translator.model())
        #expect(report.failed.isEmpty, "\(report.failed)")
        #expect(report.planned == 5) // files.shared ×2, inbox.unread ×2, home.title for pl
        #expect(report.translated == 5)

        let result = try catalog(root)
        #expect(result.entry("files.shared")?.localization("de")?.stringUnit == StringUnit(state: "needs_review", value: "%2$lld Dateien von %1$@ (de)"))
        let plural = try #require(result.entry("inbox.unread")?.localization("pl"))
        #expect(plural.leaves.map(\.label) == ["plural.few", "plural.many", "plural.one", "plural.other"])
        #expect(plural.leaves.allSatisfy { $0.unit.state == "needs_review" && $0.unit.value.hasPrefix("%lld ") })
        #expect(result.entry("home.title")?.localization("de")?.stringUnit == StringUnit(state: "translated", value: "Start"), "existing translations untouched")
        #expect(result.entry("brand")?.localization("de") == nil)

        // Fingerprints were recorded, so nothing is left to do.
        let second = try await TranslationEngine(project: try Project.discover(root: root)).run(TranslateOptions(dryRun: true), model: nil)
        #expect(second.planned == 0)
        let lint = try Linter(project: try Project.discover(root: root)).run(LintOptions(code: false))
        #expect(!lint.diagnostics.contains { $0.rule == Rules.formatMismatch.id || $0.rule == Rules.missingTranslation.id })
    }

    @Test func retriesInvalidItemsWithFeedback() async throws {
        let (root, project) = try project(["greet": TestSupport.manual("Hello %@")], config: "locales: [de]\n")
        let log = CallLog()
        let attempts = Counter()
        let model = ScriptedChatModel(name: "flaky") { _, user in
            await log.append(user)
            let attempt = await attempts.next()
            let text = attempt == 1 ? "Hallo" : "Hallo ⟦1⟧"   // first answer drops the placeholder
            return #"{"translations":[{"id":"1","text":"\#(text)"}]}"#
        }
        let report = try await TranslationEngine(project: project).run(TranslateOptions(), model: model)
        #expect(report.translated == 1)
        #expect(await log.prompts.count == 2)
        #expect(await log.prompts[1].contains("feedback"))
        #expect(try catalog(root).entry("greet")?.localization("de")?.stringUnit?.value == "Hallo %@")
    }

    @Test func givesUpAfterRetriesAndReportsFailure() async throws {
        let (root, project) = try project(["greet": TestSupport.manual("Hello %@")], config: "locales: [de]\ntranslator: { maxRetries: 1 }\n")
        let model = ScriptedChatModel { _, _ in "not json at all" }
        let report = try await TranslationEngine(project: project).run(TranslateOptions(), model: model)
        #expect(report.translated == 0)
        #expect(report.failed.first?.reason.contains("missing argument 1") == true, "a bare reply is used as text, then rejected for the missing placeholder")
        #expect(try catalog(root).entry("greet")?.localization("de") == nil)
    }

    @Test func staleNeedsReviewIsRetranslatedButApprovedIsNot() async throws {
        let (root, project) = try project([
            "a.machine": TestSupport.manual("Old A", translations: ["de": TestSupport.unit("Alt A", state: "needs_review")]),
            "b.human": TestSupport.manual("Old B", translations: ["de": TestSupport.unit("Alt B", state: "translated")]),
        ], config: "locales: [de]\n")
        _ = try TranslationEngine(project: project).accept(keys: nil, locales: nil)

        var edited = try catalog(root)
        for (key, value) in [("a.machine", "New A"), ("b.human", "New B")] {
            var entry = edited.entry(key)!
            entry.setLocalization("en", LocalizationNode(unit: StringUnit(state: "translated", value: value)))
            edited.setEntry(key, entry)
        }
        try edited.write()

        let report = try await TranslationEngine(project: try Project.discover(root: root)).run(TranslateOptions(), model: EchoTranslator(transform: { _, text in "DE " + text }).model())
        #expect(report.translated == 1)
        #expect(report.approvedSkipped.map(\.key) == ["b.human"])
        let result = try catalog(root)
        #expect(result.entry("a.machine")?.localization("de")?.stringUnit?.value == "DE New A")
        #expect(result.entry("b.human")?.localization("de")?.stringUnit == StringUnit(state: "translated", value: "Alt B"))
    }

    @Test func glossaryIsEnforcedThenWarned() async throws {
        let (_, project) = try project(["sync.title": TestSupport.manual("Sync with Acme Cloud")], config: """
        locales: [de]
        glossary: { "Acme Cloud": { de: "Acme Cloud" } }
        translator: { maxRetries: 1 }
        """)
        let model = ScriptedChatModel { system, _ in
            #expect(system.contains("- Acme Cloud => Acme Cloud"))
            return #"{"translations":[{"id":"1","text":"Mit Acme Wolke synchronisieren"}]}"#
        }
        let report = try await TranslationEngine(project: project).run(TranslateOptions(), model: model)
        #expect(report.translated == 1)
        #expect(report.warnings.first?.contains("Glossary") == true)
    }

    @Test func providedTranslationsAreValidated() throws {
        let (root, project) = try project([
            "files.shared": TestSupport.manual("%@ shared %lld files"),
            "inbox.unread": [
                "extractionState": "manual",
                "localizations": ["en": ["variations": ["plural": ["one": TestSupport.unit("%lld unread"), "other": TestSupport.unit("%lld unread")]]]],
            ],
            "approved": TestSupport.manual("Done", translations: ["de": TestSupport.unit("Fertig")]),
        ])
        let report = try TranslationEngine(project: project).applyProvided([
            ProvidedTranslation(key: "files.shared", locale: "de", value: "%2$lld Dateien von %1$@"),
            ProvidedTranslation(key: "files.shared", locale: "pl", value: "%@ udostępnił pliki"),
            ProvidedTranslation(key: "inbox.unread", locale: "pl", forms: ["one": "%lld nieprzeczytana", "few": "%lld nieprzeczytane", "many": "%lld nieprzeczytanych", "other": "%lld nieprzeczytanej"]),
            ProvidedTranslation(key: "approved", locale: "de", value: "Erledigt"),
            ProvidedTranslation(key: "nope", locale: "de", value: "x"),
        ])
        #expect(report.translated == 2)
        #expect(report.failed.map(\.key) == ["files.shared", "approved", "nope"])
        let result = try catalog(root)
        #expect(result.entry("files.shared")?.localization("de")?.stringUnit?.value == "%2$lld Dateien von %1$@")
        #expect(result.entry("inbox.unread")?.localization("pl")?.leaves.count == 4)
        #expect(result.entry("approved")?.localization("de")?.stringUnit?.value == "Fertig")
    }

    @Test func substitutionsKeepArgumentMetadata() async throws {
        let (root, project) = try project([
            "files.left": [
                "extractionState": "manual",
                "localizations": ["en": [
                    "stringUnit": ["state": "translated", "value": "%#@files@ left"],
                    "substitutions": ["files": [
                        "argNum": 1, "formatSpecifier": "lld",
                        "variations": ["plural": ["one": TestSupport.unit("%arg file"), "other": TestSupport.unit("%arg files")]],
                    ]],
                ]],
            ],
        ], config: "locales: [de]\n")
        let report = try await TranslationEngine(project: project).run(TranslateOptions(), model: EchoTranslator(transform: { _, text in "noch " + text.replacingOccurrences(of: " left", with: "") }).model())
        #expect(report.failed.isEmpty, "\(report.failed)")
        let de = try #require(try catalog(root).entry("files.left")?.localization("de"))
        #expect(de.stringUnit?.value == "noch %#@files@")
        #expect(de.substitutions["files"]?.argNum == 1)
        #expect(de.substitutions["files"]?.formatSpecifier == "lld")
        #expect(de.leaves.count == 3)
    }

    @Test func pluralOtherMustKeepTheCountAndLiteralNumbersAreRejected() async throws {
        let (root, project) = try project([
            "inbox.unread": [
                "extractionState": "manual",
                "localizations": ["en": ["variations": ["plural": ["one": TestSupport.unit("%lld unread message"), "other": TestSupport.unit("%lld unread messages")]]]],
            ],
        ], config: "locales: [de]\n")
        let attempts = Counter()
        let model = ScriptedChatModel { _, _ in
            let attempt = await attempts.next()
            // First answer hard-codes "1" and drops the count from "other" (seen with small models).
            let forms = attempt == 1
                ? #"{"one":"1 ungelesene Nachricht","other":"1 ungelesene Nachrichten"}"#
                : #"{"one":"⟦1⟧ ungelesene Nachricht","other":"⟦1⟧ ungelesene Nachrichten"}"#
            return #"{"translations":[{"id":"1","forms":\#(forms)}]}"#
        }
        let report = try await TranslationEngine(project: project).run(TranslateOptions(), model: model)
        #expect(report.translated == 1)
        #expect(await attempts.value == 2)
        let de = try #require(try catalog(root).entry("inbox.unread")?.localization("de"))
        #expect(de.leaves.map(\.unit.value) == ["%lld ungelesene Nachricht", "%lld ungelesene Nachrichten"])
    }

    @Test func mixedUpBatchAnswersAreRetriedIndividually() async throws {
        let (root, project) = try project([
            "a.greeting": TestSupport.manual("Greeting: %@"),
            "b.hello": TestSupport.manual("Hello, %@!"),
        ], config: "locales: [de]\n")
        let log = CallLog()
        let model = ScriptedChatModel { _, user in
            await log.append(user)
            let request = try JSONSerialization.jsonObject(with: Data(user.utf8)) as! [String: Any]
            let items = request["items"] as! [[String: Any]]
            if items.count > 1 {
                // Batched: the model answers both items with the second item's translation.
                return #"{"translations":[{"id":"1","text":"Hallo, ⟦1⟧!"},{"id":"2","text":"Hallo, ⟦1⟧!"}]}"#
            }
            let id = items[0]["id"] as! String
            let text = (items[0]["text"] as! String).hasPrefix("Greeting") ? "Begrüßung: ⟦1⟧" : "Hallo, ⟦1⟧!"
            return #"{"translations":[{"id":"\#(id)","text":"\#(text)"}]}"#
        }
        let report = try await TranslationEngine(project: project).run(TranslateOptions(), model: model)
        #expect(report.translated == 2)
        #expect(await log.prompts.count == 3)
        let result = try catalog(root)
        #expect(result.entry("a.greeting")?.localization("de")?.stringUnit?.value == "Begrüßung: %@")
        #expect(result.entry("b.hello")?.localization("de")?.stringUnit?.value == "Hallo, %@!")
    }

    @Test func brokenMachineTranslationsAreRepairedButApprovedOnesAreNot() async throws {
        let (root, project) = try project([
            "files.machine": TestSupport.manual("%1$@ shared %2$lld files", translations: ["ja": TestSupport.unit("%@さんが%@ファイル", state: "needs_review")]),
            "files.human": TestSupport.manual("%1$@ shared %2$lld files", translations: ["ja": TestSupport.unit("%@さんが%@ファイル", state: "translated")]),
        ], config: "locales: [ja]\n")
        let planned = try await TranslationEngine(project: project).run(TranslateOptions(dryRun: true), model: nil)
        #expect(planned.units?.map(\.key) == ["files.machine"])
        #expect(planned.units?.first?.reason == "invalid")

        let report = try await TranslationEngine(project: project).run(TranslateOptions(), model: EchoTranslator(transform: { _, _ in "⟦1⟧さんが⟦2⟧個のファイルを共有しました" }).model())
        #expect(report.translated == 1)
        let result = try catalog(root)
        #expect(result.entry("files.machine")?.localization("ja")?.stringUnit?.value == "%1$@さんが%2$lld個のファイルを共有しました")
        #expect(result.entry("files.human")?.localization("ja")?.stringUnit?.value == "%@さんが%@ファイル")
    }

    @Test func refusesRemoteEndpointsByDefault() async throws {
        await #expect(throws: L10nError.self) {
            _ = try await ChatModelFactory.make(TranslatorConfig(provider: .openai, baseURL: "https://api.example.com", model: "x"))
        }
    }

    @Test func parsesLenientResponses() {
        let parsed = TranslationEngine.parseResponse("<think>hmm {no}</think>Sure! ```json\n{\"translations\":[{\"id\":1,\"text\":\"a\"},{\"id\":\"2\",\"forms\":{\"one\":\"b\"}}]}\n```")
        #expect(parsed["1"] == .text("a"))
        #expect(parsed["2"] == .forms(["one": "b"]))

        let unit = TranslationUnit(id: "37", catalog: "c", key: "k", locale: "de", path: [], source: "Hello", sourceForms: nil, categories: nil, comment: nil, reason: "missing")
        // Single item: a reply with the wrong id, a bare string, or a lone form is still used.
        #expect(TranslationEngine.parseResponse(#"{"translations":[{"id":"37","text":"Hallo"}]}"#, expecting: [unit])["1"] == .text("Hallo"))
        #expect(TranslationEngine.parseResponse("```\n\"Hallo\"\n```", expecting: [unit])["1"] == .text("Hallo"))
        #expect(TranslationEngine.parseResponse(#"{"id":"1","forms":{"other":"Hallo"}}"#, expecting: [unit])["1"] == .text("Hallo"))
        // Several items: ids must match.
        #expect(TranslationEngine.parseResponse(#"{"translations":[{"id":"37","text":"Hallo"}]}"#, expecting: [unit, unit])["1"] == nil)
    }
}

actor Counter {
    var value = 0
    func next() -> Int { value += 1; return value }
}
