import Foundation
import Testing
@testable import L10nCore

@Suite("JSON and String Catalog round trip")
struct CatalogTests {
    @Test func xcodeFormattedCatalogRoundTripsByteForByte() throws {
        let url = TestSupport.fixturesURL.appendingPathComponent("SampleApp/SampleApp/Localizable.xcstrings")
        let original = try Data(contentsOf: url)
        let catalog = try StringCatalog.load(url)
        #expect(catalog.serialized() == original)
    }

    @Test func preservesUnknownFieldsAndExactKeys() throws {
        let text = #"{"sourceLanguage":"en","strings":{"é":{},"é":{"customField":{"nested":[1,2.50,true,null]},"localizations":{"de":{"stringUnit":{"state":"translated","value":"x"},"futureThing":"keep"}}}},"version":"1.0"}"#
        let value = try JSONParser.parse(text)
        let written = XcodeJSONWriter.string(value)
        #expect(written.contains("\"customField\""))
        #expect(written.contains("2.50"))
        #expect(written.contains("\"futureThing\" : \"keep\""))
        let reparsed = try JSONParser.parse(written)
        #expect(XcodeJSONWriter.string(reparsed) == written)
        // Both canonically-equivalent keys survive as separate entries.
        #expect(reparsed["strings"]?.objectValue?.members.count == 2)
    }

    @Test func writerUsesXcodeConventions() {
        let value = JSONValue.object(JSONObject([
            "z": .object(JSONObject()),
            "a": .string("tab\t quote\" slash/ ctrl\u{01} ünï 😀"),
            "Z": .bool(false),
        ]))
        let expected = """
        {
          "Z" : false,
          "a" : "tab\\t quote\\" slash/ ctrl\\u0001 ünï 😀",
          "z" : {

          }
        }
        """
        #expect(XcodeJSONWriter.string(value) == expected)
    }

    @Test func parserRejectsDuplicateKeysAndAcceptsBOM() throws {
        #expect(throws: JSONParseError.self) { try JSONParser.parse(#"{"a":1,"a":2}"#) }
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(Data(#"{"a":"b"}"#.utf8))
        #expect(try JSONParser.parse(data)["a"]?.stringValue == "b")
    }

    @Test(.enabled(if: TestSupport.hasXcstringstool))
    func serializationMatchesXcstringstool() throws {
        // A minified catalog with tricky content. xcstringstool rewrites it in Xcode's
        // canonical format when syncing a new extracted string into it.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("xcstrings-parity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let messy = #"{"version":"1.0","strings":{"zeta":{"shouldTranslate":false,"localizations":{"en":{"stringUnit":{"value":"Zeta \"q\" \\ / \n\r\t\u0001\b\f\u007f  😀","state":"translated"}}}},"Ápple":{},"apple":{},"Banana":{},"_under":{},"10 things":{},"éx":{},"p":{},"ｚ":{},"😀k":{},"items":{"extractionState":"manual","comment":"c","localizations":{"en":{"variations":{"plural":{"other":{"stringUnit":{"state":"translated","value":"%lld items"}},"one":{"stringUnit":{"state":"translated","value":"%lld item"}}}}},"de":{"substitutions":{"n":{"argNum":1,"formatSpecifier":"lld","variations":{"plural":{"one":{"stringUnit":{"state":"new","value":""}}}}}},"stringUnit":{"state":"needs_review","value":"%#@n@"}}}}},"sourceLanguage":"en"}"#
        let catalogURL = directory.appendingPathComponent("Localizable.xcstrings")
        try messy.write(to: catalogURL, atomically: true, encoding: .utf8)

        let swiftURL = directory.appendingPathComponent("Probe.swift")
        try #"import SwiftUI; struct P: View { var body: some View { Text("zz probe") } }"#.write(to: swiftURL, atomically: true, encoding: .utf8)
        let out = directory.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        // Our expectation: same content plus the probe key, in our serialization.
        var catalog = try StringCatalog.load(catalogURL)
        catalog.setEntry("zz probe", CatalogEntry())
        let ours = String(decoding: catalog.serialized(), as: UTF8.self)

        #expect(TestSupport.shell(["xcrun", "xcstringstool", "extract", swiftURL.path, "--SwiftUI", "-o", out.path]).0 == 0)
        let stringsdata = try FileManager.default.contentsOfDirectory(atPath: out.path).filter { $0.hasSuffix(".stringsdata") }.map { out.appendingPathComponent($0).path }
        #expect(TestSupport.shell(["xcrun", "xcstringstool", "sync", catalogURL.path, "--skip-marking-strings-stale", "--stringsdata"] + stringsdata).0 == 0)
        let xcode = try String(contentsOf: catalogURL, encoding: .utf8)
        #expect(ours == xcode)
    }

    @Test func entryAccessorsAndLeaves() throws {
        let json = TestSupport.catalogJSON([
            "k": [
                "extractionState": "manual",
                "localizations": [
                    "en": ["variations": ["plural": ["one": TestSupport.unit("%lld file"), "other": TestSupport.unit("%lld files")]]],
                    "de": ["variations": ["device": ["iphone": TestSupport.unit("A"), "mac": TestSupport.unit("B", state: "needs_review")]]],
                ],
            ],
        ])
        let catalog = StringCatalog(url: URL(fileURLWithPath: "/tmp/x.xcstrings"), root: try JSONParser.parse(json).objectValue!)
        let entry = try #require(catalog.entry("k"))
        #expect(entry.isManual)
        #expect(entry.localization("en")?.leaves.map(\.label) == ["plural.one", "plural.other"])
        #expect(entry.localization("de")?.leaves.map(\.unit.state) == ["translated", "needs_review"])
        #expect(catalog.locales == ["en", "de"])
    }

    @Test func setUnitCreatesIntermediateObjectsAndKeepsSiblings() {
        var node = LocalizationNode(raw: JSONObject(["substitutions": .object(JSONObject(["n": .object(JSONObject(["argNum": .number("1")]))]))]))
        node.setUnit(StringUnit(state: "needs_review", value: "x"), at: ["substitutions", "n", "variations", "plural", "few"])
        #expect(node.value(at: ["substitutions", "n", "argNum"]) == .number("1"))
        #expect(node.leaves.first?.unit.value == "x")
    }
}

@Suite("Fingerprints")
struct FingerprintTests {
    @Test func fingerprintIgnoresCommentButTracksValues() {
        let a = LocalizationNode(unit: StringUnit(state: "translated", value: "Hello"))
        let b = LocalizationNode(unit: StringUnit(state: "needs_review", value: "Hello"))
        let c = LocalizationNode(unit: StringUnit(state: "translated", value: "Hello!"))
        #expect(FingerprintStore.sourceFingerprint(a) == FingerprintStore.sourceFingerprint(b))
        #expect(FingerprintStore.sourceFingerprint(a) != FingerprintStore.sourceFingerprint(c))
    }

    @Test func savesAndLoads() throws {
        let root = try TestSupport.makeProject([:])
        var store = try FingerprintStore.load(root: root)
        store.set(catalog: "A/Localizable.xcstrings", key: "a.b", locale: "de", fingerprint: "123")
        try store.save()
        let loaded = try FingerprintStore.load(root: root)
        #expect(loaded.fingerprint(catalog: "A/Localizable.xcstrings", key: "a.b", locale: "de") == "123")
    }
}
