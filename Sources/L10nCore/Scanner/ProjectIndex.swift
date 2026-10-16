import Foundation
import SwiftParser
import SwiftSyntax

/// Facts gathered from every Swift file of the project before scanning a single file,
/// so per-file decisions can use declarations and references elsewhere in the project.
public struct ProjectIndex: Sendable, Equatable {
    /// Function or type name → argument labels whose parameter is declared
    /// `LocalizedStringKey` or `LocalizedStringResource` (`func alert(title: LocalizedStringKey)`).
    /// Literals passed there are localization lookups, not plain text.
    /// Values are label → `LocalizedStringKey` or `LocalizedStringResource`.
    public var localizedParameters: [String: [String: String]] = [:]
    /// Properties and functions whose every reference is an argument of a logging call
    /// (`logger.warning(issue.warningMessage)`); their text is not user-facing.
    public var logOnlyNames: Set<String> = []
    /// Every complete string literal value (no interpolation), byte-exact.
    public var literals: Set<ByteKey> = []
    /// Text before the first interpolation of interpolated literals (`"settings.\(name)"` → `settings.`).
    public var literalPrefixes: Set<String> = []
    /// Every identifier used in an expression (decl references and member names).
    public var identifiers: Set<String> = []
    /// The same literal, prefix and identifier sets per file (standardized path), so key
    /// usage can be checked for the files of one target.
    public var files: [String: References] = [:]

    public struct References: Sendable, Equatable {
        public var literals: Set<ByteKey> = []
        public var literalPrefixes: Set<String> = []
        public var identifiers: Set<String> = []
    }

    public init() {}

    public static func build(files: [URL]) -> ProjectIndex {
        build(named: files.compactMap { url in (try? String(contentsOf: url, encoding: .utf8)).map { (url.standardizedFileURL.path, $0) } })
    }

    /// Builds an index from in-memory sources.
    public static func build(sources: [String]) -> ProjectIndex {
        build(named: sources.enumerated().map { ("source\($0.offset)", $0.element) })
    }

    static func build(named sources: [(path: String, source: String)]) -> ProjectIndex {
        var index = ProjectIndex()
        var references: [String: (total: Int, logging: Int)] = [:]
        var parameters: [String: [String: String]] = [:]
        for (path, source) in sources { index.add(source: source, path: path, references: &references, parameters: &parameters) }
        index.logOnlyNames = Set(references.compactMap { name, counts in
            counts.total > 0 && counts.total == counts.logging ? name : nil
        })
        // Keep a parameter only when every declaration with that name and label is localized
        // (`A.show(title: LocalizedStringKey)` next to `B.show(title: String)` stays plain text).
        index.localizedParameters = parameters.compactMapValues { labels in
            let localized = labels.filter { IndexVisitor.localizedType($0.value) != nil }
            return localized.isEmpty ? nil : localized
        }
        return index
    }

    static func mergeParameter(_ type: String, name: String, label: String, into parameters: inout [String: [String: String]]) {
        if let existing = parameters[name]?[label], existing != type {
            parameters[name]?[label] = "conflict"
        } else {
            parameters[name, default: [:]][label] = type
        }
    }

    private mutating func add(source: String, path: String, references: inout [String: (total: Int, logging: Int)], parameters: inout [String: [String: String]]) {
        let visitor = IndexVisitor()
        visitor.walk(Parser.parse(source: source))
        for (name, labels) in visitor.parameters {
            for (label, type) in labels { Self.mergeParameter(type, name: name, label: label, into: &parameters) }
        }
        literals.formUnion(visitor.literals)
        literalPrefixes.formUnion(visitor.literalPrefixes)
        identifiers.formUnion(visitor.identifiers)
        files[path] = References(literals: visitor.literals, literalPrefixes: visitor.literalPrefixes, identifiers: visitor.identifiers)
        for (name, counts) in visitor.references {
            let existing = references[name] ?? (0, 0)
            references[name] = (existing.total + counts.total, existing.logging + counts.logging)
        }
    }

    /// Implicit member references (`.macSettingsHotkeyTitle`, `.Settings.title`) by enclosing
    /// type (`""` at top level): the generated-symbol uses of a file.
    public static func implicitMembers(in source: String) -> [String: [String]] {
        final class Visitor: SyntaxVisitor {
            var result: [String: [String]] = [:]
            override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
                // `.name`, or `.Table.name` for a namespaced table.
                let isImplicit = node.base == nil || node.base?.as(MemberAccessExprSyntax.self)?.base == nil
                if isImplicit, node.parent?.as(MemberAccessExprSyntax.self) == nil {
                    result[IndexVisitor.enclosingTypeName(of: Syntax(node)) ?? "", default: []].append(node.declName.baseName.text)
                }
                return .visitChildren
            }
        }
        let visitor = Visitor(viewMode: .sourceAccurate)
        visitor.walk(Parser.parse(source: source))
        return visitor.result
    }

    /// Member calls that log rather than show text (`logger.warning(...)`, `os.log(...)`).
    static let loggingMethods: Set<String> = ["debug", "info", "notice", "warning", "error", "fault", "critical", "trace", "log"]
    /// Free functions that log or trap.
    static let loggingFunctions: Set<String> = [
        "print", "debugPrint", "NSLog", "os_log", "dump", "assert", "assertionFailure", "precondition",
        "preconditionFailure", "fatalError",
    ]

    /// Words in a receiver's name that mark it as a logger (`logger`, `PangiLogger.accounts`, `os.log`).
    static let loggerWords: Set<String> = ["log", "logger", "logging", "oslog", "signposter"]

    /// Whether `call` is a logging call: a logging free function, or `debug/info/…(…)` on a
    /// receiver whose name says it is a logger (`toast.info(…)` and `hud.error(…)` are UI).
    static func isLoggingCall(_ call: FunctionCallExprSyntax) -> Bool {
        if let reference = call.calledExpression.as(DeclReferenceExprSyntax.self) {
            return loggingFunctions.contains(reference.baseName.text)
        }
        if let member = call.calledExpression.as(MemberAccessExprSyntax.self), let base = member.base,
           loggingMethods.contains(member.declName.baseName.text) {
            return looksLikeLogger(base)
        }
        return false
    }

    static func looksLikeLogger(_ expression: ExprSyntax) -> Bool {
        var names: [String] = []
        var current: ExprSyntax? = expression
        while let node = current {
            if let member = node.as(MemberAccessExprSyntax.self) {
                names.append(member.declName.baseName.text)
                current = member.base
            } else if let reference = node.as(DeclReferenceExprSyntax.self) {
                names.append(reference.baseName.text)
                current = nil
            } else {
                current = nil
            }
        }
        return names.contains { name in
            name == "os" || KeySuggester.splitCamel(name.trimmingCharacters(in: CharacterSet(charactersIn: "_"))).contains { loggerWords.contains($0.lowercased()) }
        }
    }
}

private final class IndexVisitor: SyntaxVisitor {
    /// Function or type name → label → `LocalizedStringKey`, `LocalizedStringResource`, `plain` or `conflict`.
    var parameters: [String: [String: String]] = [:]
    var literals: Set<ByteKey> = []
    var literalPrefixes: Set<String> = []
    var identifiers: Set<String> = []
    var references: [String: (total: Int, logging: Int)] = [:]

    init() { super.init(viewMode: .sourceAccurate) }

    static func localizedType(_ type: String) -> String? {
        let base = type.hasSuffix("?") ? String(type.dropLast()) : type
        return ["LocalizedStringKey", "LocalizedStringResource"].contains(base) ? base : nil
    }

    private func record(parameters: FunctionParameterListSyntax, as name: String) {
        for parameter in parameters {
            let type = Self.localizedType(parameter.type.trimmedDescription) ?? "plain"
            ProjectIndex.mergeParameter(type, name: name, label: parameter.firstName.text, into: &self.parameters)
        }
    }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        record(parameters: node.signature.parameterClause.parameters, as: node.name.text)
        return .visitChildren
    }

    override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        if let type = Self.enclosingTypeName(of: Syntax(node)) {
            record(parameters: node.signature.parameterClause.parameters, as: type)
        }
        return .visitChildren
    }

    /// Memberwise initializers: stored `let`/`var` properties typed as localized strings.
    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        for member in node.memberBlock.members {
            guard let variable = member.decl.as(VariableDeclSyntax.self),
                  !variable.modifiers.contains(where: { $0.name.text == "static" })
            else { continue }
            for binding in variable.bindings where binding.accessorBlock == nil {
                guard let identifier = binding.pattern.as(IdentifierPatternSyntax.self), let annotation = binding.typeAnnotation else { continue }
                let type = Self.localizedType(annotation.type.trimmedDescription) ?? "plain"
                ProjectIndex.mergeParameter(type, name: node.name.text, label: identifier.identifier.text, into: &parameters)
            }
        }
        return .visitChildren
    }

    override func visit(_ node: StringLiteralExprSyntax) -> SyntaxVisitorContinueKind {
        var text = ""
        var interpolated = false
        for segment in node.segments {
            switch segment {
            case .stringSegment(let part):
                if !interpolated { text += part.content.text }
            case .expressionSegment:
                if !interpolated, !text.isEmpty { literalPrefixes.insert(text) }
                interpolated = true
            }
        }
        if !interpolated, let value = node.representedLiteralValue {
            literals.insert(ByteKey(value))
        }
        return .visitChildren
    }

    override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
        noteReference(node.baseName.text, node: Syntax(node))
        return .visitChildren
    }

    override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
        noteReference(node.declName.baseName.text, node: Syntax(node))
        return .visitChildren
    }

    private func noteReference(_ name: String, node: Syntax) {
        identifiers.insert(name)
        if let member = node.parent?.as(MemberAccessExprSyntax.self), member.base?.id == node.id {
            // `issue.warningMessage`: count the member, not the base.
            return
        }
        // A called function (`warningMessage()`) is used where its call is.
        var use = node
        if let call = node.parent?.as(FunctionCallExprSyntax.self), call.calledExpression.id == node.id { use = Syntax(call) }
        var counts = references[name] ?? (0, 0)
        counts.total += 1
        if Self.isInsideLoggingArgument(use) { counts.logging += 1 }
        references[name] = counts
    }

    /// Whether the expression is (part of) an argument of a logging call within the same statement.
    static func isInsideLoggingArgument(_ node: Syntax) -> Bool {
        var current = node
        while let parent = current.parent {
            if parent.is(CodeBlockItemSyntax.self) || parent.is(ClosureExprSyntax.self) || parent.is(MemberBlockItemSyntax.self) {
                return false
            }
            if let argument = parent.as(LabeledExprSyntax.self),
               let call = argument.parent?.parent?.as(FunctionCallExprSyntax.self), ProjectIndex.isLoggingCall(call) {
                return true
            }
            current = parent
        }
        return false
    }

    static func enclosingTypeName(of node: Syntax) -> String? {
        var current = node.parent
        while let candidate = current {
            if let decl = candidate.as(StructDeclSyntax.self) { return decl.name.text }
            if let decl = candidate.as(ClassDeclSyntax.self) { return decl.name.text }
            if let decl = candidate.as(EnumDeclSyntax.self) { return decl.name.text }
            if let decl = candidate.as(ActorDeclSyntax.self) { return decl.name.text }
            if let decl = candidate.as(ExtensionDeclSyntax.self) {
                return decl.extendedType.trimmedDescription.split(separator: ".").last.map(String.init)
            }
            current = candidate.parent
        }
        return nil
    }
}
