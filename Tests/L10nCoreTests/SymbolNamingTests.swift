import Foundation
import Testing
@testable import L10nCore

@Suite("Generated symbol naming")
struct SymbolNamingTests {
    /// Observed from `xcstringstool generate-symbols` (Xcode 27).
    static let expectations: [(String, String)] = [
        ("onboarding.welcome.title", "onboardingWelcomeTitle"),
        ("greeting.full", "greetingFull"),
        ("settings.dark_mode", "settingsDarkMode"),
        ("Settings-Title", "settingsTitle"),
        ("123start", "_123Start"),
        ("default", "`default`"),
        ("init", "`init`"),
        ("Any", "`Any`"),
        (".leading", "leading"),
        ("ALLCAPS", "allcaps"),
        ("HTTPSConnection", "httpsconnection"),
        ("URL.title", "urlTitle"),
        ("a..b", "aB"),
        ("abc123def", "abc123Def"),
        ("is_on", "isOn"),
        ("myURL.path", "myURLPath"),
        ("onboarding.welcomeTitle", "onboardingWelcomeTitle"),
        ("settings.2fa.enable", "settings2FaEnable"),
        ("snake_Case.Mixed", "snakeCaseMixed"),
        ("sp ace  dbl", "spAceDbl"),
        ("trailing.", "trailing"),
        ("v2_0", "v20"),
        ("x2y.z", "x2YZ"),
        ("été", "été"),
        ("über.title", "überTitle"),
        ("中文.key", "中文Key"),
        ("1.2.3", "_123"),
        ("HelloThere.x", "helloThereX"),
        ("IDCard", "idcard"),
        ("Self.x", "selfX"),
        ("URLs", "urls"),
        ("__a", "_A"),
        ("_private.key", "_PrivateKey"),
        ("aBCDef.gHI", "aBCDefGHI"),
        ("fooBAR.baz", "fooBARBaz"),
        ("get.URL", "getUrl"),
        ("mixed_UPPER", "mixedUpper"),
        ("x.yZ", "xYZ"),
        ("ÄBC.dEF", "äbcDEF"),
        ("Über", "über"),
        ("type", "type"),
        ("some", "some"),
        ("let.x", "letX"),
    ]

    @Test func matchesObservedXcodeNames() {
        for (key, expected) in Self.expectations {
            #expect(SymbolNaming.symbol(for: key) == .name(expected), "key \(key)")
        }
    }

    @Test func reservedAndCollisions() {
        #expect(SymbolNaming.symbol(for: "self") == .reserved)
        #expect(SymbolNaming.symbol(for: "Type") == .reserved)
        #expect(SymbolNaming.symbol(for: "Protocol") == .reserved)
        let groups = SymbolNaming.collisions(among: ["a.b_c", "a_b.c", "a_b_c", "dup.x", "dupX", "x.YZ", "x.Yz", "ok.key"])
        #expect(groups.contains(["a.b_c", "a_b.c", "a_b_c"]))
        #expect(groups.contains(["dup.x", "dupX"]))
        #expect(groups.contains(["x.YZ", "x.Yz"]))
        #expect(groups.count == 3)
    }

    @Test func tableNamespaces() {
        #expect(SymbolNaming.tableNamespace("Localizable") == nil)
        #expect(SymbolNaming.tableNamespace("Settings") == "Settings")
        #expect(SymbolNaming.tableNamespace("my-strings") == "MyStrings")
        #expect(SymbolNaming.tableNamespace("feature_flags") == "FeatureFlags")
        #expect(SymbolNaming.tableNamespace("InfoPlist") == "InfoPlist")
        #expect(SymbolNaming.tableNamespace("123abc") == "_123Abc")
        #expect(SymbolNaming.reference(for: "a.b", table: "Settings", arguments: ["x"]) == ".Settings.aB(x)")
    }

    @Test(.enabled(if: TestSupport.hasXcstringstool))
    func agreesWithXcstringstool() throws {
        // Keys whose symbols collide make Xcode refuse the whole catalog, so keep one per symbol.
        var seenSymbols: Set<String> = []
        let keys = (Self.expectations.map(\.0) + ["hello.world", "user.profile.editButton", "Hello World 2", "a-B.c_D", "Ölçü.ünïcode"]).filter { key in
            guard let name = SymbolNaming.bareName(for: key) else { return false }
            return seenSymbols.insert(name).inserted
        }
        var strings: [String: Any] = [:]
        for key in keys { strings[key] = TestSupport.manual("v") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("symbols-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let catalog = directory.appendingPathComponent("Localizable.xcstrings")
        try TestSupport.catalogJSON(strings).write(to: catalog, atomically: true, encoding: .utf8)
        let (status, output) = TestSupport.shell(["xcrun", "xcstringstool", "generate-symbols", catalog.path, "-o", directory.path, "-l", "swift"])
        #expect(status == 0, "\(output)")

        let generated = try String(contentsOf: directory.appendingPathComponent("GeneratedStringSymbols_Localizable.swift"), encoding: .utf8)
        var observed: [String: String] = [:]
        var pendingKey: String?
        for line in generated.split(separator: "\n") {
            if let match = line.firstMatch(of: /key “(.*)” in table/) {
                pendingKey = String(match.1)
            } else if let key = pendingKey, let match = line.firstMatch(of: /static (?:var|func) ([^:(]+)/) {
                observed[key] = String(match.1)
                pendingKey = nil
            }
        }
        for key in keys {
            #expect(SymbolNaming.symbol(for: key) == .name(observed[key] ?? "<missing>"), "key \(key)")
        }
    }
}
