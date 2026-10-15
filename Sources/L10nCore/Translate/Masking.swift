import Foundation

/// Replaces format specifiers with opaque tokens before text goes to a model and
/// restores them afterwards:
/// `%@` → `⟦1⟧`, `%2$lld` → `⟦2⟧`, `%%` → `⟦%⟧`, `%#@files@` → `⟦@files⟧`.
public struct MaskedText: Equatable, Sendable {
    public var text: String
    /// Argument index → specifier without position, e.g. 2 → `%lld`.
    var arguments: [Int: String]
    var substitutions: Set<String>
    var hasPercentLiteral: Bool
    var hasSubstitutionArgument: Bool
    /// Value argument indices in source order when `*` widths are present; such strings
    /// cannot be reordered because positional `*` forms are not generated.
    var dynamicWidthOrder: [Int]?
    /// Whether the source used `n$` positions.
    var positional: Bool

    public static let open: Character = "⟦"
    public static let close: Character = "⟧"

    public init(source: String) {
        var text = ""
        var arguments: [Int: String] = [:]
        var substitutions: Set<String> = []
        var hasPercentLiteral = false
        var hasSubstitutionArgument = false
        var positional = false
        var valueOrder: [Int] = []
        var hasDynamicWidth = false
        var cursor = source.startIndex
        for token in FormatSpecifier.tokens(in: source) {
            text += source[cursor..<token.range.lowerBound]
            switch token.kind {
            case .percentLiteral:
                text += "⟦%⟧"
                hasPercentLiteral = true
            case .argument(let index, _):
                text += "⟦\(index)⟧"
                if arguments[index] == nil { arguments[index] = FormatSpecifier.stripPosition(token.text) }
                valueOrder.append(index)
                hasDynamicWidth = hasDynamicWidth || !token.widthArguments.isEmpty
                positional = positional || token.isPositional
            case .substitution(let name):
                text += "⟦@\(name)⟧"
                substitutions.insert(name)
            case .substitutionArgument:
                text += "⟦arg⟧"
                hasSubstitutionArgument = true
            }
            cursor = token.range.upperBound
        }
        text += source[cursor...]
        self.text = text
        self.arguments = arguments
        self.substitutions = substitutions
        self.hasPercentLiteral = hasPercentLiteral
        self.hasSubstitutionArgument = hasSubstitutionArgument
        self.dynamicWidthOrder = hasDynamicWidth ? valueOrder : nil
        self.positional = positional
    }

    public var hasTokens: Bool { !arguments.isEmpty || !substitutions.isEmpty || hasPercentLiteral || hasSubstitutionArgument }

    public enum UnmaskError: Error, Equatable, CustomStringConvertible {
        case unknownToken(String)
        case unbalanced
        case reorderedDynamicWidth

        public var description: String {
            switch self {
            case .unknownToken(let token): return "unknown placeholder ⟦\(token)⟧"
            case .unbalanced: return "broken placeholder brackets"
            case .reorderedDynamicWidth: return "placeholders with a dynamic width (%*d) must keep their original order"
            }
        }
    }

    /// Restores specifiers in a translated text. Arguments that end up out of order are
    /// written with explicit positions (`%2$@ … %1$@`).
    public func unmask(_ translated: String) throws -> String {
        // Split into literal text and token names.
        var parts: [(isToken: Bool, value: String)] = []
        var buffer = ""
        var index = translated.startIndex
        while index < translated.endIndex {
            let character = translated[index]
            if character == Self.open {
                guard let close = translated[index...].firstIndex(of: Self.close) else { throw UnmaskError.unbalanced }
                if !buffer.isEmpty { parts.append((false, buffer)); buffer = "" }
                parts.append((true, String(translated[translated.index(after: index)..<close])))
                index = translated.index(after: close)
                continue
            }
            if character == Self.close { throw UnmaskError.unbalanced }
            buffer.append(character)
            index = translated.index(after: index)
        }
        if !buffer.isEmpty { parts.append((false, buffer)) }

        let argumentOrder = parts.compactMap { $0.isToken ? Int($0.value) : nil }
        var seen: [Int] = []
        for argument in argumentOrder where !seen.contains(argument) { seen.append(argument) }
        if let dynamicWidthOrder {
            guard argumentOrder == dynamicWidthOrder else { throw UnmaskError.reorderedDynamicWidth }
        }
        let contiguousInOrder = seen.isEmpty || seen == Array(1...seen.count)
        let usePositions = dynamicWidthOrder == nil
            ? (positional || !contiguousInOrder || argumentOrder.count != seen.count)
            : positional

        let escapeRawPercent = hasTokens
        var output = ""
        for part in parts {
            if !part.isToken {
                output += escapeRawPercent ? Self.escapePercents(part.value) : part.value
                continue
            }
            let name = part.value.trimmingCharacters(in: .whitespaces)
            if name == "%" {
                output += "%%"
            } else if name == "arg", hasSubstitutionArgument {
                output += "%arg"
            } else if name.hasPrefix("@") {
                let substitution = String(name.dropFirst())
                guard substitutions.contains(substitution) else { throw UnmaskError.unknownToken(name) }
                output += "%#@\(substitution)@"
            } else if let number = Int(name), let specifier = arguments[number] {
                output += usePositions ? FormatSpecifier.withPosition(specifier, index: number) : specifier
            } else {
                throw UnmaskError.unknownToken(name)
            }
        }
        return output
    }

    /// Escapes raw `%` written by the model outside placeholder tokens.
    static func escapePercents(_ text: String) -> String {
        text.replacingOccurrences(of: "%", with: "%%")
    }
}
