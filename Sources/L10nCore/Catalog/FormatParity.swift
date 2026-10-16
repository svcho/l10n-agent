import Foundation

/// Compares format specifiers of a translation against its source by argument index
/// and type. Reordering (`%2$@ … %1$@`) is allowed; that is what positional
/// specifiers are for.
public enum FormatParity {
    /// Why a translation looks like a wrapper around the text rather than the text itself:
    /// a JSON object or array (`{"text":"…"}`) or a Markdown code fence, when the source is
    /// neither. Models and scripts produce these; Xcode shows them verbatim.
    public static func wrapperProblem(source: String, target: String) -> String? {
        func isJSONContainer(_ text: String) -> Bool {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let first = trimmed.first, first == "{" || first == "[" else { return false }
            guard let value = try? JSONParser.parse(trimmed) else { return false }
            if case .object = value { return true }
            if case .array = value { return true }
            return false
        }
        if isJSONContainer(target), !isJSONContainer(source) { return "is a JSON value, not the text itself" }
        if target.contains("```"), !source.contains("```") { return "contains a Markdown code fence" }
        return nil
    }

    private static func family(_ type: FormatToken.ArgumentType) -> String {
        switch type {
        case .integer, .unsigned, .character: return "integer"
        default: return type.rawValue
        }
    }

    /// Returns a description of the mismatch, or `nil` when the translation is compatible.
    /// In plural variation cases a translation may omit arguments (for example "one" →
    /// "One file"), but must not add or retype them.
    public static func problem(source: String, target: String, allowsOmission: Bool = false) -> String? {
        let sourceSignature = FormatSpecifier.argumentSignature(of: source)
        let targetSignature = FormatSpecifier.argumentSignature(of: target)

        for (index, type) in targetSignature.sorted(by: { $0.key < $1.key }) {
            guard let sourceType = sourceSignature[index] else {
                return "argument \(index) does not exist in the source"
            }
            if family(sourceType) != family(type) {
                return "argument \(index) is \(type.rawValue) but the source uses \(sourceType.rawValue)"
            }
        }
        if !allowsOmission {
            let missing = sourceSignature.keys.filter { targetSignature[$0] == nil }.sorted()
            if !missing.isEmpty {
                return "missing argument\(missing.count == 1 ? "" : "s") \(missing.map(String.init).joined(separator: ", "))"
            }
        }

        let sourceSubstitutions = FormatSpecifier.substitutionNames(in: source)
        let targetSubstitutions = FormatSpecifier.substitutionNames(in: target)
        if !targetSubstitutions.isSubset(of: sourceSubstitutions) {
            return "unknown substitution \(targetSubstitutions.subtracting(sourceSubstitutions).sorted().joined(separator: ", "))"
        }
        if !allowsOmission, targetSubstitutions != sourceSubstitutions {
            return "missing substitution \(sourceSubstitutions.subtracting(targetSubstitutions).sorted().joined(separator: ", "))"
        }

        let sourceUsesArg = FormatSpecifier.tokens(in: source).contains { $0.kind == .substitutionArgument }
        let targetUsesArg = FormatSpecifier.tokens(in: target).contains { $0.kind == .substitutionArgument }
        if targetUsesArg, !sourceUsesArg { return "uses %arg outside a substitution" }
        if sourceUsesArg, !targetUsesArg, !allowsOmission { return "missing %arg" }

        // Mixing positional and sequential arguments is undefined behavior in printf.
        let tokens = FormatSpecifier.tokens(in: target).filter { if case .argument = $0.kind { return true } else { return false } }
        if tokens.contains(where: \.isPositional), tokens.contains(where: { !$0.isPositional }) {
            return "mixes positional (%1$@) and sequential (%@) specifiers"
        }
        return nil
    }

    /// Finds the source leaf a target leaf should be compared with. Target plural
    /// categories missing from the source (e.g. Polish `few`) map to the source `other`.
    public static func sourceLeaf(for targetPath: [String], in source: LocalizationNode) -> (leaf: NodeLeafMatch, isPluralCase: Bool)? {
        let leaves = source.leaves
        let isPlural = targetPath.count >= 3 && targetPath[targetPath.count - 3] == "variations" && targetPath[targetPath.count - 2] == "plural"
        if let exact = leaves.first(where: { $0.path == targetPath }) {
            return (NodeLeafMatch(path: exact.path, value: exact.unit.value), isPlural)
        }
        if isPlural {
            var otherPath = targetPath
            otherPath[otherPath.count - 1] = "other"
            if let other = leaves.first(where: { $0.path == otherPath }) {
                return (NodeLeafMatch(path: other.path, value: other.unit.value), true)
            }
        }
        if let top = leaves.first(where: { $0.path.isEmpty }) {
            return (NodeLeafMatch(path: [], value: top.unit.value), isPlural)
        }
        if let other = leaves.first(where: { $0.path.last == "other" }) {
            return (NodeLeafMatch(path: other.path, value: other.unit.value), true)
        }
        return nil
    }

    public struct NodeLeafMatch: Equatable, Sendable {
        public var path: [String]
        public var value: String
    }
}
