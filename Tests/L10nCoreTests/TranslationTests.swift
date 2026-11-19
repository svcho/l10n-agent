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

    // MARK: Catalog scope

    /// Two targets that share `color.name.blue`, plus a second iOS key and a French
    /// translation, so the catalog, key and locale selectors can be told apart.
    func twoCatalogProject() throws -> (URL, Project) {
        let root = try TestSupport.makeProject([
            ".l10n-agent.yml": "locales: [de, fr]\n",
            "iOS/Localizable.xcstrings": TestSupport.catalogJSON([
                "color.name.blue": TestSupport.manual("Blue", translations: ["de": TestSupport.unit("Blau"), "fr": TestSupport.unit("Bleu")]),
                "color.name.red": TestSupport.manual("Red", translations: ["de": TestSupport.unit("Rot")]),
            ]),
            "Mac/Localizable.xcstrings": TestSupport.catalogJSON([
                "color.name.blue": TestSupport.manual("Blue", translations: ["de": TestSupport.unit("Blau")]),
            ]),
        ])
        return (root, try Project.discover(root: root))
    }

    /// Rewrites the English source of `values`, leaving every translation as written.
    func editSource(_ root: URL, _ path: String, _ values: [String: String]) throws {
        let url = root.appendingPathComponent(path)
        var catalog = try StringCatalog.load(url)
        for (key, value) in values {
            var entry = catalog.entry(key)!
            entry.setLocalization("en", LocalizationNode(unit: StringUnit(state: "translated", value: value)))
            catalog.setEntry(key, entry)
        }
        try catalog.write()
    }

    func bytes(_ root: URL, _ path: String) throws -> Data {
        try Data(contentsOf: root.appendingPathComponent(path))
    }

    /// `catalog|key|locale` for every fingerprint that differs between two stores.
    func changedFingerprints(_ before: FingerprintStore, _ after: FingerprintStore) -> [String] {
        var changed: [String] = []
        for catalog in Set(before.entries.keys).union(after.entries.keys) {
            let keys = Set(before.entries[catalog].map { Array($0.keys) } ?? []).union(after.entries[catalog].map { Array($0.keys) } ?? [])
            for key in keys {
                let locales = Set(before.entries[catalog]?[key].map { Array($0.keys) } ?? []).union(after.entries[catalog]?[key].map { Array($0.keys) } ?? [])
                for locale in locales where before.entries[catalog]?[key]?[locale] != after.entries[catalog]?[key]?[locale] {
                    changed.append("\(catalog)|\(key.string)|\(locale)")
                }
            }
        }
        return changed.sorted()
    }

    /// L10N103 findings as `file|key|locales`, order-independent.
    func staleFindings(_ project: Project) throws -> Set<String> {
        let report = try Linter(project: project).run(LintOptions(rules: ["L10N103"], code: false))
        return Set(report.diagnostics.map { "\($0.file)|\($0.key ?? "")|\(($0.locales ?? []).joined(separator: ","))" })
    }

    @Test func scopedAcceptUpdatesOnlyTheSelectedCatalog() throws {
        let (root, project) = try twoCatalogProject()
        #expect(try TranslationEngine(project: project).accept(keys: nil, locales: nil) == 4)

        try editSource(root, "iOS/Localizable.xcstrings", ["color.name.blue": "Deep Blue", "color.name.red": "Crimson"])
        try editSource(root, "Mac/Localizable.xcstrings", ["color.name.blue": "Deep Blue"])

        // Both targets share the German key; iOS also has a French translation and a second key.
        #expect(try staleFindings(project) == [
            "iOS/Localizable.xcstrings|color.name.blue|de,fr",
            "iOS/Localizable.xcstrings|color.name.red|de",
            "Mac/Localizable.xcstrings|color.name.blue|de",
        ])

        let before = try FingerprintStore.load(root: root)
        let iosBytes = try bytes(root, "iOS/Localizable.xcstrings")
        let macBytes = try bytes(root, "Mac/Localizable.xcstrings")

        #expect(try TranslationEngine(project: project).accept(keys: ["color.name.blue"], locales: ["de"], catalog: "iOS/Localizable.xcstrings") == 1)

        let after = try FingerprintStore.load(root: root)
        #expect(changedFingerprints(before, after) == ["iOS/Localizable.xcstrings|color.name.blue|de"])
        let ios = try StringCatalog.load(root.appendingPathComponent("iOS/Localizable.xcstrings"))
        let source = ios.entry("color.name.blue")!.sourceNode(key: "color.name.blue", sourceLanguage: ios.sourceLanguage)
        #expect(after.fingerprint(catalog: "iOS/Localizable.xcstrings", key: "color.name.blue", locale: "de") == FingerprintStore.sourceFingerprint(source))

        // Only the reviewed tuple is cleared: the Mac target, the French translation and the
        // second iOS key still need review.
        #expect(try staleFindings(try Project.discover(root: root)) == [
            "iOS/Localizable.xcstrings|color.name.blue|fr",
            "iOS/Localizable.xcstrings|color.name.red|de",
            "Mac/Localizable.xcstrings|color.name.blue|de",
        ])

        // Acceptance records review against the source; Xcode keeps owning the catalogs.
        #expect(try bytes(root, "iOS/Localizable.xcstrings") == iosBytes)
        #expect(try bytes(root, "Mac/Localizable.xcstrings") == macBytes)
    }

    @Test func scopedAcceptIsIdempotentAndEmptyMatchesUpdateNothing() throws {
        let (root, project) = try twoCatalogProject()
        _ = try TranslationEngine(project: project).accept(keys: nil, locales: nil)
        try editSource(root, "iOS/Localizable.xcstrings", ["color.name.blue": "Deep Blue"])
        try editSource(root, "Mac/Localizable.xcstrings", ["color.name.blue": "Deep Blue"])

        let engine = TranslationEngine(project: try Project.discover(root: root))
        #expect(try engine.accept(keys: ["color.name.blue"], locales: ["de"], catalog: "iOS/Localizable.xcstrings") == 1)
        let settled = try FingerprintStore.load(root: root).serialized()
        let iosBytes = try bytes(root, "iOS/Localizable.xcstrings")
        let macBytes = try bytes(root, "Mac/Localizable.xcstrings")

        #expect(try engine.accept(keys: ["color.name.blue"], locales: ["de"], catalog: "iOS/Localizable.xcstrings") == 0)
        #expect(try FingerprintStore.load(root: root).serialized() == settled)
        #expect(try bytes(root, "iOS/Localizable.xcstrings") == iosBytes)
        #expect(try bytes(root, "Mac/Localizable.xcstrings") == macBytes)

        // A valid catalog with no matching key or locale is a successful no-op.
        #expect(try engine.accept(keys: ["color.name.green"], locales: ["de"], catalog: "iOS/Localizable.xcstrings") == 0)
        #expect(try engine.accept(keys: ["color.name.blue"], locales: ["ja"], catalog: "iOS/Localizable.xcstrings") == 0)
        #expect(try FingerprintStore.load(root: root).serialized() == settled)
    }

    @Test func scopedAcceptRejectsPathsThatAreNotDiscoveredCatalogs() throws {
        let (root, project) = try twoCatalogProject()
        _ = try TranslationEngine(project: project).accept(keys: nil, locales: nil)
        try editSource(root, "iOS/Localizable.xcstrings", ["color.name.blue": "Deep Blue"])
        try editSource(root, "Mac/Localizable.xcstrings", ["color.name.blue": "Deep Blue"])

        // A catalog outside the project, reachable through a symlink inside it.
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("l10n-agent-outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let outsideCatalog = outside.appendingPathComponent("Outside.xcstrings")
        try bytes(root, "iOS/Localizable.xcstrings").write(to: outsideCatalog)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Linked.xcstrings"), withDestinationURL: outsideCatalog)

        let fingerprintBytes = try Data(contentsOf: FingerprintStore.path(root: root))
        let iosBytes = try bytes(root, "iOS/Localizable.xcstrings")
        let macBytes = try bytes(root, "Mac/Localizable.xcstrings")
        let engine = TranslationEngine(project: try Project.discover(root: root))

        func expectRejected(_ catalog: String, contains: String) throws {
            // Compare the raw file: re-encoding through FingerprintStore could hide a rewrite.
            let before = try Data(contentsOf: FingerprintStore.path(root: root))
            var message: String?
            do {
                _ = try engine.accept(keys: ["color.name.blue"], locales: ["de"], catalog: catalog)
                Issue.record("\(catalog) was accepted")
            } catch let error as L10nError {
                if case .invalidArgument(let text) = error {
                    message = text
                } else {
                    Issue.record("\(catalog): unexpected \(error)")
                }
            } catch {
                Issue.record("\(catalog): unexpected \(error)")
            }
            if let message {
                #expect(message.contains(catalog), "\(message)")
                #expect(message.contains(contains), "\(message)")
            }
            #expect(try Data(contentsOf: FingerprintStore.path(root: root)) == before, "\(catalog) rewrote fingerprints.json")
        }

        // Only nested files share this basename, so the filename is not a full relative path.
        try expectRejected("Localizable.xcstrings", contains: "discovered")
        try expectRejected("Missing.xcstrings", contains: "discovered")
        // The selector is checked before it is normalized, so neither a `..` component nor an
        // absolute path can name a discovered catalog by a spelling the project does not use.
        try expectRejected("../Outside.xcstrings", contains: "project-relative")
        try expectRejected("iOS/../Mac/Localizable.xcstrings", contains: "project-relative")
        try expectRejected(root.appendingPathComponent("Mac/Localizable.xcstrings").path, contains: "project-relative")
        try expectRejected("Linked.xcstrings", contains: "outside the project root")

        #expect(try Data(contentsOf: FingerprintStore.path(root: root)) == fingerprintBytes)
        #expect(try bytes(root, "iOS/Localizable.xcstrings") == iosBytes)
        #expect(try bytes(root, "Mac/Localizable.xcstrings") == macBytes)
    }

    /// `String` comparisons work on grapheme clusters, so a combining mark can hide a `/` or a
    /// `..` component from `hasPrefix`/`split` while the path still standardizes to a
    /// discovered catalog. The guard reads UTF-8 bytes instead.
    @Test func scopedAcceptRejectsParentComponentsHiddenByCombiningMarks() throws {
        let (root, project) = try twoCatalogProject()
        _ = try TranslationEngine(project: project).accept(keys: nil, locales: nil)
        try editSource(root, "iOS/Localizable.xcstrings", ["color.name.blue": "Deep Blue"])
        try editSource(root, "Mac/Localizable.xcstrings", ["color.name.blue": "Deep Blue"])
        let fingerprintBytes = try Data(contentsOf: FingerprintStore.path(root: root))

        // U+0600 is a prepend character: it joins the following `/` into one grapheme cluster,
        // so a `Character` split sees `iOS\u{0600}/..` and misses the `..` component, while
        // standardization is lexical and still resolves the path to the Mac catalog.
        let hiddenParent = "iOS\u{0600}/../Mac/Localizable.xcstrings"
        #expect(hiddenParent.split(separator: "/").map(String.init) == ["iOS\u{0600}/..", "Mac", "Localizable.xcstrings"])
        // A combining mark after the leading `/` hides the slash from `hasPrefix("/")`.
        let hiddenSlash = "/\u{0301}tmp/Localizable.xcstrings"
        #expect(!hiddenSlash.hasPrefix("/"))

        for catalog in [hiddenParent, hiddenSlash] {
            var message: String?
            do {
                _ = try TranslationEngine(project: project).accept(keys: ["color.name.blue"], locales: ["de"], catalog: catalog)
                Issue.record("\(catalog) was accepted")
            } catch let error as L10nError {
                if case .invalidArgument(let text) = error {
                    message = text
                } else {
                    Issue.record("\(catalog): unexpected \(error)")
                }
            } catch {
                Issue.record("\(catalog): unexpected \(error)")
            }
            #expect(message?.contains("project-relative") == true, "\(message ?? "no message")")
            // Compare the raw file: re-encoding through FingerprintStore could hide a rewrite.
            #expect(try Data(contentsOf: FingerprintStore.path(root: root)) == fingerprintBytes, "\(catalog) rewrote fingerprints.json")
        }

        // Nothing was acknowledged: both catalogs still report their stale translations.
        #expect(try staleFindings(project) == [
            "iOS/Localizable.xcstrings|color.name.blue|de,fr",
            "Mac/Localizable.xcstrings|color.name.blue|de",
        ])
    }

    @Test func scopedAcceptAddressesARootLevelCatalogByFilename() throws {
        let root = try TestSupport.makeProject([
            ".l10n-agent.yml": "locales: [de]\n",
            "Localizable.xcstrings": TestSupport.catalogJSON([
                "color.name.blue": TestSupport.manual("Blue", translations: ["de": TestSupport.unit("Blau")]),
            ]),
            "iOS/Localizable.xcstrings": TestSupport.catalogJSON([
                "color.name.blue": TestSupport.manual("Blue", translations: ["de": TestSupport.unit("Blau")]),
            ]),
        ])
        #expect(try TranslationEngine(project: try Project.discover(root: root)).accept(keys: nil, locales: nil) == 2)
        try editSource(root, "Localizable.xcstrings", ["color.name.blue": "Deep Blue"])
        try editSource(root, "iOS/Localizable.xcstrings", ["color.name.blue": "Deep Blue"])

        let project = try Project.discover(root: root)
        #expect(try TranslationEngine(project: project).accept(keys: ["color.name.blue"], locales: ["de"], catalog: "Localizable.xcstrings") == 1)
        #expect(try staleFindings(project) == ["iOS/Localizable.xcstrings|color.name.blue|de"])
    }

    @Test func unscopedAcceptAndInitStayProjectWide() async throws {
        let (root, project) = try twoCatalogProject()
        _ = try TranslationEngine(project: project).accept(keys: nil, locales: nil)
        try editSource(root, "iOS/Localizable.xcstrings", ["color.name.blue": "Deep Blue", "color.name.red": "Crimson"])
        try editSource(root, "Mac/Localizable.xcstrings", ["color.name.blue": "Deep Blue"])

        // Key and locale filters still span every catalog when no scope is given.
        #expect(try TranslationEngine(project: try Project.discover(root: root)).accept(keys: ["color.name.blue"], locales: ["de"]) == 2)
        #expect(try staleFindings(try Project.discover(root: root)) == [
            "iOS/Localizable.xcstrings|color.name.blue|fr",
            "iOS/Localizable.xcstrings|color.name.red|de",
        ])

        // No filters at all: every matching catalog is updated.
        #expect(try TranslationEngine(project: try Project.discover(root: root)).accept(keys: nil, locales: nil) == 2)
        #expect(try staleFindings(try Project.discover(root: root)).isEmpty)

        // init seeds every catalog when no scope is given.
        let (initRoot, _) = try twoCatalogProject()
        let iosStart = try bytes(initRoot, "iOS/Localizable.xcstrings")
        let macStart = try bytes(initRoot, "Mac/Localizable.xcstrings")
        let result = try await InitCommand.run(root: initRoot)
        #expect(result.baselined == 4)
        let store = try FingerprintStore.load(root: initRoot)
        #expect(store.entries["iOS/Localizable.xcstrings"]?.count == 2)
        #expect(store.entries["Mac/Localizable.xcstrings"]?.count == 1)
        #expect(store.fingerprint(catalog: "iOS/Localizable.xcstrings", key: "color.name.blue", locale: "fr") != nil)
        #expect(try bytes(initRoot, "iOS/Localizable.xcstrings") == iosStart)
        #expect(try bytes(initRoot, "Mac/Localizable.xcstrings") == macStart)
    }
}

actor Counter {
    var value = 0
    func next() -> Int { value += 1; return value }
}
