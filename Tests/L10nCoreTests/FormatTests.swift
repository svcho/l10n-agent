import Foundation
import Testing
@testable import L10nCore

@Suite("Format specifiers, parity and masking")
struct FormatTests {
    @Test func parsesSpecifiers() {
        let tokens = FormatSpecifier.tokens(in: "%@ has %lld items (%.1f%%) %2$@ %#@files@ 100% sure")
        let kinds = tokens.map(\.kind)
        #expect(kinds == [
            .argument(index: 1, type: .object),
            .argument(index: 2, type: .integer),
            .argument(index: 3, type: .double),
            .percentLiteral,
            .argument(index: 2, type: .object),
            .substitution(name: "files", index: nil),
        ])
        #expect(FormatSpecifier.withPosition("%.1f", index: 3) == "%3$.1f")
        #expect(FormatSpecifier.stripPosition("%2$lld") == "%lld")
    }

    @Test func parsesPositionalNamedSubstitutions() throws {
        let positional = FormatSpecifier.tokens(in: "%1$#@COUNT@")
        #expect(positional.count == 1)
        let positionalToken = try #require(positional.first)
        #expect(positionalToken.kind == .substitution(name: "COUNT", index: 1))
        #expect(positionalToken.text == "%1$#@COUNT@")
        #expect(positionalToken.isPositional)

        let sequential = FormatSpecifier.tokens(in: "%#@COUNT@")
        #expect(sequential.count == 1)
        let sequentialToken = try #require(sequential.first)
        #expect(sequentialToken.kind == .substitution(name: "COUNT", index: nil))
        #expect(sequentialToken.text == "%#@COUNT@")
        #expect(!sequentialToken.isPositional)

        #expect(!FormatSpecifier.hasText("%1$#@COUNT@"))
        #expect(!FormatSpecifier.hasText("%lld %1$#@COUNT@"))
        #expect(FormatSpecifier.hasText("%1$#@COUNT@ items"))
        #expect(FormatSpecifier.hasText("%%1$#@COUNT@"))
        #expect(!FormatSpecifier.hasText("%arg%1$#@COUNT@123"))
        #expect(FormatSpecifier.substitutionNames(in: "%1$#@COUNT@") == ["COUNT"])
        #expect(FormatSpecifier.substitutionPositions(in: "%#@COUNT@ %2$#@COUNT@ %3$#@COUNT@ %#@OTHER@") == ["COUNT": 2])

        let positionalArgument = FormatSpecifier.tokens(in: "%1$lld")
        #expect(positionalArgument.count == 1)
        let argument = try #require(positionalArgument.first)
        #expect(argument.kind == .argument(index: 1, type: .integer))
        #expect(argument.isPositional)

        let unsigned = FormatSpecifier.tokens(in: "%#x")
        #expect(unsigned.count == 1)
        let unsignedToken = try #require(unsigned.first)
        #expect(unsignedToken.kind == .argument(index: 1, type: .unsigned))
        #expect(!unsignedToken.isPositional)
    }

    @Test func malformedNamedSubstitutionsFallBackToArgumentTokens() {
        func check(_ string: String, texts: [String], positional: [Bool], hasText: Bool) {
            let tokens = FormatSpecifier.tokens(in: string)
            #expect(tokens.map(\.text) == texts)
            #expect(tokens.map(\.kind) == Array(repeating: FormatToken.Kind.argument(index: 1, type: .object), count: texts.count))
            #expect(tokens.map(\.isPositional) == positional)
            #expect(FormatSpecifier.substitutionNames(in: string).isEmpty)
            #expect(FormatSpecifier.hasText(string) == hasText)
        }
        check("%1$#@@", texts: ["%1$#@"], positional: [true], hasText: false)
        check("%1$#@COUNT", texts: ["%1$#@"], positional: [true], hasText: true)
        check("%#@bad-name@", texts: ["%#@"], positional: [false], hasText: true)
        check("%1$#@COUNT%@@", texts: ["%1$#@", "%@"], positional: [true, false], hasText: true)
    }

    @Test func parityAllowsReorderingButNotRetyping() {
        #expect(FormatParity.problem(source: "%1$@ shared %2$lld files", target: "%2$lld Dateien von %1$@") == nil)
        #expect(FormatParity.problem(source: "%@ shared %lld files", target: "%2$lld Dateien von %1$@") == nil)
        #expect(FormatParity.problem(source: "%1$@ shared %2$lld files", target: "%@ hat %@ geteilt") != nil)
        #expect(FormatParity.problem(source: "Hello %@", target: "Hallo") != nil)
        #expect(FormatParity.problem(source: "Hello %@", target: "Hallo %1$@ %1$@") == nil, "repeating the same argument is fine")
        #expect(FormatParity.problem(source: "Hello %@", target: "Hallo %@ %@") != nil, "a second sequential %@ is a second argument")
        #expect(FormatParity.problem(source: "Hello %@", target: "Hallo %2$@") != nil)
        #expect(FormatParity.problem(source: "%@ %lld", target: "%2$lld %@") != nil, "mixing positional and sequential")
        #expect(FormatParity.problem(source: "%lld files", target: "One file", allowsOmission: true) == nil)
        #expect(FormatParity.problem(source: "%#@n@ left", target: "noch %#@n@") == nil)
        #expect(FormatParity.problem(source: "%#@n@ left", target: "noch %#@m@") != nil)
        #expect(FormatParity.problem(source: "%d", target: "%lld") == nil, "integer widths are compatible")
    }

    @Test func parityChecksExplicitNamedSubstitutionIndices() {
        let source = "%1$@ has %2$#@COUNT@"
        #expect(FormatParity.problem(source: source, target: "%1$@ hat %3$#@COUNT@") == "substitution COUNT uses argument 3 but the source uses 2")
        #expect(FormatParity.problem(source: source, target: "%2$#@COUNT@ hat %1$@") == nil, "reordering keeps the index")
        #expect(FormatParity.problem(source: source, target: "%1$@ hat %#@COUNT@") == nil, "the index may be omitted")
        #expect(FormatParity.problem(source: "%1$@ has %#@COUNT@", target: "%1$@ hat %3$#@COUNT@") == "substitution COUNT uses argument 3 but the source has no explicit index")
        #expect(FormatParity.problem(source: "%2$#@COUNT@", target: "%3$#@COUNT@", allowsOmission: true) == "substitution COUNT uses argument 3 but the source uses 2")
        #expect(FormatParity.problem(source: "%2$#@COUNT@", target: "Dateien", allowsOmission: true) == nil)
    }

    @Test func maskRoundTripKeepsSequentialOrder() throws {
        let masked = MaskedText(source: "Hello %@, you have %lld new messages (100%%)")
        #expect(masked.text == "Hello ⟦1⟧, you have ⟦2⟧ new messages (100⟦%⟧)")
        #expect(try masked.unmask("Hallo ⟦1⟧, du hast ⟦2⟧ neue Nachrichten (100⟦%⟧)") == "Hallo %@, du hast %lld neue Nachrichten (100%%)")
    }

    @Test func maskRoundTripKeepsPositionalSubstitutions() throws {
        let masked = MaskedText(source: "%1$@ has %2$#@COUNT@")
        #expect(masked.text == "⟦1⟧ has ⟦@COUNT⟧")
        #expect(try masked.unmask(masked.text) == "%1$@ has %2$#@COUNT@")
        #expect(try masked.unmask("⟦1⟧ hat ⟦@COUNT⟧") == "%1$@ hat %2$#@COUNT@")

        let sequential = MaskedText(source: "%#@COUNT@")
        #expect(sequential.text == "⟦@COUNT⟧")
        #expect(try sequential.unmask(sequential.text) == "%#@COUNT@")

        let repeated = MaskedText(source: "%1$#@COUNT@ and %#@COUNT@")
        #expect(repeated.text == "⟦@COUNT⟧ and ⟦@COUNT⟧")
        #expect(try repeated.unmask("⟦@COUNT⟧ and ⟦@COUNT⟧") == "%1$#@COUNT@ and %1$#@COUNT@")
    }

    @Test func unmaskUsesPositionsWhenReordered() throws {
        let masked = MaskedText(source: "%@ shared %lld files")
        #expect(try masked.unmask("⟦2⟧ Dateien von ⟦1⟧") == "%2$lld Dateien von %1$@")
    }

    @Test func unmaskEscapesRawPercentAndRejectsUnknownTokens() throws {
        let masked = MaskedText(source: "%lld%% done")
        #expect(try masked.unmask("⟦1⟧ % erledigt") == "%lld %% erledigt")
        #expect(throws: MaskedText.UnmaskError.self) { try masked.unmask("⟦3⟧ erledigt") }
        #expect(throws: MaskedText.UnmaskError.self) { try masked.unmask("⟦1 erledigt") }
        // Strings without arguments are never formatted; their % stays literal.
        #expect(try MaskedText(source: "100% secure").unmask("100 % sicher") == "100 % sicher")
    }

    @Test func lintChecksExplicitNamedSubstitutionIndices() throws {
        func report(german: String) throws -> LintReport {
            let root = try TestSupport.makeProject([
                ".l10n-agent.yml": "locales: [de]\n",
                "Localizable.xcstrings": """
                {
                  "sourceLanguage": "en",
                  "strings": {
                    "inventory.summary": {
                      "extractionState": "manual",
                      "localizations": {
                        "en": {
                          "stringUnit": {"state": "translated", "value": "%1$@ has %2$#@COUNT@"},
                          "substitutions": {
                            "COUNT": {
                              "argNum": 2,
                              "formatSpecifier": "lld",
                              "variations": {"plural": {
                                "one": {"stringUnit": {"state": "translated", "value": "%arg"}},
                                "other": {"stringUnit": {"state": "translated", "value": "%arg"}}
                              }}
                            }
                          }
                        },
                        "de": {
                          "stringUnit": {"state": "translated", "value": "\(german)"},
                          "substitutions": {
                            "COUNT": {
                              "argNum": 2,
                              "formatSpecifier": "lld",
                              "variations": {"plural": {
                                "one": {"stringUnit": {"state": "translated", "value": "%arg"}},
                                "other": {"stringUnit": {"state": "translated", "value": "%arg"}}
                              }}
                            }
                          }
                        }
                      }
                    }
                  },
                  "version": "1.0"
                }
                """,
            ])
            return try Linter(project: try Project.discover(root: root)).run(LintOptions(rules: ["L10N104"], code: false, catalogs: true))
        }

        let mismatch = try report(german: "%1$@ hat %3$#@COUNT@")
        #expect(mismatch.diagnostics.count == 1)
        let diagnostic = try #require(mismatch.diagnostics.first)
        #expect(diagnostic.rule == "L10N104")
        #expect(diagnostic.severity == .error)
        #expect(diagnostic.key == "inventory.summary")
        #expect(diagnostic.locales == ["de"])
        #expect(diagnostic.message == "Translation de of \"inventory.summary\": substitution COUNT uses argument 3 but the source uses 2")
        #expect(mismatch.exitCode(failOn: .error) == 1)

        let reordered = try report(german: "%2$#@COUNT@ hat %1$@")
        #expect(reordered.diagnostics.isEmpty)
        #expect(reordered.exitCode(failOn: .error) == 0)
    }

    @Test func pluralCategories() {
        #expect(PluralRules.categories(for: "pl") == ["one", "few", "many", "other"])
        #expect(PluralRules.categories(for: "ja") == ["other"])
        #expect(PluralRules.categories(for: "zh-Hans") == ["other"])
        #expect(PluralRules.categories(for: "pt-BR") == ["one", "many", "other"])
        #expect(PluralRules.categories(for: "de") == ["one", "other"])
    }
}
