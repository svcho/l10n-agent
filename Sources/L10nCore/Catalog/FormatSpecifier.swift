import Foundation

/// A printf-style token inside a localized value, as used by String Catalogs.
public struct FormatToken: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// `%%`
        case percentLiteral
        /// `%@`, `%lld`, `%1$.2f`, …
        case argument(index: Int, type: ArgumentType)
        /// `%#@name@`, a reference into the localization's `substitutions`.
        case substitution(name: String)
        /// `%arg`, the argument placeholder inside a substitution's variations.
        case substitutionArgument
    }

    public enum ArgumentType: String, Equatable, Sendable, Codable {
        case object
        case integer
        case unsigned
        case double
        case cString
        case character
        case pointer
    }

    public let kind: Kind
    /// The exact text of the token in the source string.
    public let text: String
    /// Whether the token used an explicit `n$` position.
    public let isPositional: Bool
    /// UTF-16 range of the token in the string.
    public let range: Range<String.Index>
    /// Argument indices consumed by `*` widths/precisions (`%*d`, `%.*f`), always integers.
    public var widthArguments: [Int] = []
}

public enum FormatSpecifier {
    /// Parses printf-style tokens. Sequential (non-positional) arguments are numbered
    /// in order of appearance; positional ones keep their explicit index.
    public static func tokens(in string: String) -> [FormatToken] {
        var tokens: [FormatToken] = []
        var nextSequential = 1
        var cursor = string.startIndex

        while let percent = string[cursor...].firstIndex(of: "%") {
            let afterPercent = string.index(after: percent)
            guard afterPercent < string.endIndex else { break }

            if string[afterPercent] == "%" {
                let end = string.index(after: afterPercent)
                tokens.append(FormatToken(kind: .percentLiteral, text: "%%", isPositional: false, range: percent..<end))
                cursor = end
                continue
            }

            if string[afterPercent...].hasPrefix("arg") {
                let end = string.index(afterPercent, offsetBy: 3)
                if end == string.endIndex || !(string[end].isLetter || string[end].isNumber) {
                    tokens.append(FormatToken(kind: .substitutionArgument, text: "%arg", isPositional: false, range: percent..<end))
                    cursor = end
                    continue
                }
            }

            if string[afterPercent] == "#", let substitution = parseSubstitution(string, from: afterPercent) {
                tokens.append(FormatToken(
                    kind: .substitution(name: substitution.name),
                    text: String(string[percent..<substitution.end]),
                    isPositional: false,
                    range: percent..<substitution.end
                ))
                cursor = substitution.end
                continue
            }

            guard let parsed = parseArgument(string, from: afterPercent) else {
                cursor = afterPercent
                continue
            }

            // Each `*` consumes its own integer argument before the value.
            var widthArguments: [Int] = []
            for star in parsed.stars {
                if let explicit = star {
                    widthArguments.append(explicit)
                } else {
                    widthArguments.append(nextSequential)
                    nextSequential += 1
                }
            }
            let index: Int
            if let position = parsed.position {
                index = position
            } else {
                index = nextSequential
                nextSequential += 1
            }
            tokens.append(FormatToken(
                kind: .argument(index: index, type: parsed.type),
                text: String(string[percent..<parsed.end]),
                isPositional: parsed.position != nil,
                range: percent..<parsed.end,
                widthArguments: widthArguments
            ))
            cursor = parsed.end
        }

        return tokens
    }

    /// Argument signature keyed by argument index. Repeated uses of the same index collapse.
    public static func argumentSignature(of string: String) -> [Int: FormatToken.ArgumentType] {
        var signature: [Int: FormatToken.ArgumentType] = [:]
        for token in tokens(in: string) {
            if case .argument(let index, let type) = token.kind {
                signature[index] = type
                for width in token.widthArguments { signature[width] = .integer }
            }
        }
        return signature
    }

    public static func substitutionNames(in string: String) -> Set<String> {
        Set(tokens(in: string).compactMap {
            if case .substitution(let name) = $0.kind { return name }
            return nil
        })
    }

    public static func hasArguments(_ string: String) -> Bool {
        tokens(in: string).contains {
            switch $0.kind {
            case .argument, .substitution, .substitutionArgument: return true
            case .percentLiteral: return false
            }
        }
    }

    /// Returns the token text with the positional `n$` part removed, e.g. `%2$.1f` → `%.1f`.
    public static func stripPosition(_ text: String) -> String {
        guard let dollar = text.firstIndex(of: "$") else { return text }
        let digits = text[text.index(after: text.startIndex)..<dollar]
        guard !digits.isEmpty, digits.allSatisfy(\.isNumber) else { return text }
        return "%" + text[text.index(after: dollar)...]
    }

    /// Returns the token text with an explicit position, e.g. `%.1f` + 2 → `%2$.1f`.
    public static func withPosition(_ text: String, index: Int) -> String {
        "%\(index)$" + stripPosition(text).dropFirst()
    }

    private static func parseSubstitution(_ string: String, from hashIndex: String.Index) -> (name: String, end: String.Index)? {
        // %#@name@
        let at = string.index(after: hashIndex)
        guard at < string.endIndex, string[at] == "@" else { return nil }
        let nameStart = string.index(after: at)
        guard let close = string[nameStart...].firstIndex(of: "@"), close > nameStart else { return nil }
        let name = String(string[nameStart..<close])
        guard name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { return nil }
        return (name, string.index(after: close))
    }

    private static func parseArgument(_ string: String, from start: String.Index) -> (position: Int?, type: FormatToken.ArgumentType, end: String.Index, stars: [Int?])? {
        var index = start
        var position: Int?

        // Optional n$
        var digits = ""
        var probe = index
        while probe < string.endIndex, string[probe].isASCII, string[probe].isNumber {
            digits.append(string[probe])
            probe = string.index(after: probe)
        }
        if !digits.isEmpty, probe < string.endIndex, string[probe] == "$" {
            position = Int(digits)
            index = string.index(after: probe)
        }

        // Flags
        while index < string.endIndex, "-+#0".contains(string[index]) {
            index = string.index(after: index)
        }
        // Width and precision; `*` (optionally `*n$`) takes the value from an argument.
        var stars: [Int?] = []
        func consumeNumberOrStar() {
            if index < string.endIndex, string[index] == "*" {
                index = string.index(after: index)
                var digits = ""
                var probe = index
                while probe < string.endIndex, string[probe].isASCII, string[probe].isNumber {
                    digits.append(string[probe])
                    probe = string.index(after: probe)
                }
                if !digits.isEmpty, probe < string.endIndex, string[probe] == "$" {
                    stars.append(Int(digits))
                    index = string.index(after: probe)
                } else {
                    stars.append(nil)
                }
                return
            }
            while index < string.endIndex, string[index].isASCII, string[index].isNumber {
                index = string.index(after: index)
            }
        }
        consumeNumberOrStar()
        if index < string.endIndex, string[index] == "." {
            index = string.index(after: index)
            consumeNumberOrStar()
        }
        // Length modifier
        for modifier in ["hh", "ll", "h", "l", "L", "q", "j", "z", "t"] {
            if string[index...].hasPrefix(modifier) {
                index = string.index(index, offsetBy: modifier.count)
                break
            }
        }
        guard index < string.endIndex else { return nil }

        let conversion = string[index]
        let type: FormatToken.ArgumentType
        switch conversion {
        case "@": type = .object
        case "d", "i", "D": type = .integer
        case "u", "U", "x", "X", "o", "O": type = .unsigned
        case "f", "F", "e", "E", "g", "G", "a", "A": type = .double
        case "s", "S": type = .cString
        case "c", "C": type = .character
        case "p": type = .pointer
        default: return nil
        }
        return (position, type, string.index(after: index), stars)
    }
}
