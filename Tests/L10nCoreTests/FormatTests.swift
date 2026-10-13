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
            .substitution(name: "files"),
        ])
        #expect(FormatSpecifier.withPosition("%.1f", index: 3) == "%3$.1f")
        #expect(FormatSpecifier.stripPosition("%2$lld") == "%lld")
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

    @Test func maskRoundTripKeepsSequentialOrder() throws {
        let masked = MaskedText(source: "Hello %@, you have %lld new messages (100%%)")
        #expect(masked.text == "Hello ⟦1⟧, you have ⟦2⟧ new messages (100⟦%⟧)")
        #expect(try masked.unmask("Hallo ⟦1⟧, du hast ⟦2⟧ neue Nachrichten (100⟦%⟧)") == "Hallo %@, du hast %lld neue Nachrichten (100%%)")
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

    @Test func pluralCategories() {
        #expect(PluralRules.categories(for: "pl") == ["one", "few", "many", "other"])
        #expect(PluralRules.categories(for: "ja") == ["other"])
        #expect(PluralRules.categories(for: "zh-Hans") == ["other"])
        #expect(PluralRules.categories(for: "pt-BR") == ["one", "many", "other"])
        #expect(PluralRules.categories(for: "de") == ["one", "other"])
    }
}
