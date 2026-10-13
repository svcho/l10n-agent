import Foundation
@_spi(Compiler) import SwiftParser
import SwiftOperators
import SwiftSyntax

/// Finds strings that reach the UI in Swift source, using syntax only (no type checking).
///
/// Detection is allowlist-based: a literal is reported only when it flows into a known
/// user-facing API, property or name, so logging, identifiers, asset names and similar
/// strings stay quiet.
public struct SwiftScanner {
    public let userFacing: UserFacingAPIs

    public init(userFacing: UserFacingAPIs = UserFacingAPIs()) {
        self.userFacing = userFacing
    }

    public static func isTestFile(path: String, source: String) -> Bool {
        if path.contains("/Tests/") || path.contains("Tests/") && path.hasPrefix("Tests/") { return true }
        if path.hasSuffix("Tests.swift") { return true }
        return source.contains("import XCTest") || source.range(of: #"(?m)^\s*import Testing\s*$"#, options: .regularExpression) != nil
    }

    public func scan(source: String, path: String) -> [StringSite] {
        if Self.isTestFile(path: path, source: source) { return [] }
        let parsed = Parser.parse(source: source)
        let tree = OperatorTable.standardOperators.foldAll(parsed) { _ in }
        let converter = SourceLocationConverter(fileName: path, tree: tree)
        let visitor = ScanVisitor(path: path, converter: converter, userFacing: userFacing)
        visitor.walk(tree)
        return visitor.sites.sorted { ($0.line, $0.column) < ($1.line, $1.column) }
    }
}

private final class ScanVisitor: SyntaxVisitor {
    let path: String
    let converter: SourceLocationConverter
    let userFacing: UserFacingAPIs
    var sites: [StringSite] = []
    private var reportedConcatenations: Set<Int> = []

    init(path: String, converter: SourceLocationConverter, userFacing: UserFacingAPIs) {
        self.path = path
        self.converter = converter
        self.userFacing = userFacing
        super.init(viewMode: .sourceAccurate)
    }

    // MARK: Skipped regions

    override func visit(_ node: IfConfigClauseSyntax) -> SyntaxVisitorContinueKind {
        if let condition = node.condition, node.poundKeyword.tokenKind != .poundElse,
           condition.trimmedDescription.contains("DEBUG"), !condition.trimmedDescription.contains("!DEBUG") {
            return .skipChildren
        }
        return .visitChildren
    }

    override func visit(_ node: MacroExpansionExprSyntax) -> SyntaxVisitorContinueKind {
        node.macroName.text == "Preview" ? .skipChildren : .visitChildren
    }

    override func visit(_ node: MacroExpansionDeclSyntax) -> SyntaxVisitorContinueKind {
        node.macroName.text == "Preview" ? .skipChildren : .visitChildren
    }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        isPreviewProvider(node.inheritanceClause) ? .skipChildren : .visitChildren
    }

    override func visit(_ node: AttributeSyntax) -> SyntaxVisitorContinueKind {
        .skipChildren
    }

    private func isPreviewProvider(_ clause: InheritanceClauseSyntax?) -> Bool {
        clause?.inheritedTypes.contains { $0.type.trimmedDescription.hasSuffix("PreviewProvider") } ?? false
    }

    // MARK: Literals

    override func visit(_ node: StringLiteralExprSyntax) -> SyntaxVisitorContinueKind {
        handle(node)
        return .skipChildren
    }

    private func handle(_ literal: StringLiteralExprSyntax) {
        // Walk outward through wrappers that keep the literal's role.
        var expression = ExprSyntax(literal)
        var concatenationRoot: ExprSyntax?
        while let parent = expression.parent {
            if let tuple = parent.as(LabeledExprSyntax.self), let list = tuple.parent?.as(LabeledExprListSyntax.self),
               let tupleExpr = list.parent?.as(TupleExprSyntax.self), list.count == 1, tuple.label == nil {
                expression = ExprSyntax(tupleExpr)
                continue
            }
            if let ternary = parent.as(TernaryExprSyntax.self), ternary.condition.id != expression.id {
                expression = ExprSyntax(ternary)
                continue
            }
            if let infix = parent.as(InfixOperatorExprSyntax.self), let op = infix.operator.as(BinaryOperatorExprSyntax.self) {
                if op.operator.text == "??", infix.rightOperand.id == expression.id {
                    expression = ExprSyntax(infix)
                    continue
                }
                if op.operator.text == "+" {
                    expression = ExprSyntax(infix)
                    concatenationRoot = expression
                    continue
                }
            }
            break
        }

        guard let context = classify(expression) else { return }

        if let root = concatenationRoot {
            reportConcatenation(root: root, context: context)
            return
        }

        guard let segments = segments(of: literal) else { return }
        let letters = segments.reduce(0) { count, segment in
            if case .text(let text) = segment { return count + text.filter(\.isLetter).count }
            return count
        }
        guard letters >= 2 else { return }

        var kind = context.kind
        var key: String?
        if kind == .localizedText {
            key = Self.xcodeKey(for: segments)
            if !literal.segments.contains(where: { if case .expressionSegment = $0 { return true } else { return false } }),
               let key, KeyPolicy.looksSemantic(key) {
                kind = .localizedKey
            }
        }

        let replaceNode: Syntax = context.replaceWholeCall.map(Syntax.init) ?? Syntax(literal)
        let hasInterpolation = segments.contains { if case .expression = $0 { return true } else { return false } }
        let staticText = segments.compactMap { if case .text(let text) = $0 { return text } else { return nil } }.joined()
        var unfixable: String?
        if literal.openingQuote.tokenKind != .stringQuote || literal.openingPounds != nil {
            unfixable = "multiline or raw string literals need a manual rewrite"
        } else if kind == .formatString {
            unfixable = "String(format:) needs a manual rewrite"
        } else if context.replaceWholeCall != nil, expression.id != ExprSyntax(literal).id {
            // e.g. Text(flag ? "On" : "Off"): replacing the whole call would drop the rest.
            unfixable = "the text is part of a larger expression inside \(context.api); rewrite manually"
        } else if !context.blockingArguments.isEmpty {
            unfixable = "\(context.api) uses \(context.blockingArguments.map { $0 + ":" }.joined(separator: ", ")) which the rewrite cannot keep"
        } else if !hasInterpolation, FormatSpecifier.hasArguments(staticText) {
            unfixable = "the text contains printf-style specifiers; rewrite with interpolation manually"
        }
        sites.append(makeSite(
            node: Syntax(literal),
            replaceNode: replaceNode,
            kind: kind,
            context: context.replacement,
            api: context.api,
            role: context.role,
            segments: segments,
            key: key,
            table: context.table,
            hasDefaultValue: context.hasDefaultValue,
            unfixableReason: unfixable,
            codeComment: context.codeComment
        ))
    }

    private func reportConcatenation(root: ExprSyntax, context: Classification) {
        guard !reportedConcatenations.contains(root.position.utf8Offset) else { return }
        guard context.kind == .unlocalized || context.kind == .localizedText else { return }
        var operands: [ExprSyntax] = []
        flattenConcatenation(root, into: &operands)
        var segments: [LiteralSegment] = []
        for operand in operands {
            if let literal = operand.as(StringLiteralExprSyntax.self), let literalSegments = self.segments(of: literal) {
                segments.append(contentsOf: literalSegments)
            } else {
                segments.append(.expression(operand.trimmedDescription))
            }
        }
        let letters = segments.reduce(0) { count, segment in
            if case .text(let text) = segment { return count + text.filter(\.isLetter).count }
            return count
        }
        guard letters >= 2 else { return }
        reportedConcatenations.insert(root.position.utf8Offset)
        sites.append(makeSite(
            node: Syntax(root),
            replaceNode: Syntax(root),
            kind: .concatenation,
            context: .string,
            api: context.api,
            role: context.role,
            segments: Self.mergeTextSegments(segments),
            key: nil,
            table: nil,
            hasDefaultValue: false,
            unfixableReason: nil,
            codeComment: nil
        ))
    }

    private func flattenConcatenation(_ expression: ExprSyntax, into operands: inout [ExprSyntax]) {
        if let infix = expression.as(InfixOperatorExprSyntax.self),
           infix.operator.as(BinaryOperatorExprSyntax.self)?.operator.text == "+" {
            flattenConcatenation(infix.leftOperand, into: &operands)
            flattenConcatenation(infix.rightOperand, into: &operands)
        } else {
            operands.append(expression)
        }
    }

    private func makeSite(
        node: Syntax, replaceNode: Syntax, kind: SiteKind, context: ReplacementContext, api: String, role: String,
        segments: [LiteralSegment], key: String?, table: String?, hasDefaultValue: Bool, unfixableReason: String?, codeComment: String?
    ) -> StringSite {
        let location = converter.location(for: node.positionAfterSkippingLeadingTrivia)
        let start = replaceNode.positionAfterSkippingLeadingTrivia.utf8Offset
        let end = replaceNode.endPositionBeforeTrailingTrivia.utf8Offset
        return StringSite(
            file: path,
            line: location.line,
            column: location.column,
            kind: kind,
            context: context,
            api: api,
            role: role,
            segments: segments,
            originalCode: replaceNode.trimmedDescription,
            replaceRange: ByteRange(start: start, end: end),
            key: key,
            table: table,
            hasDefaultValue: hasDefaultValue,
            enclosingType: enclosingTypeName(of: node),
            unfixableReason: unfixableReason,
            codeComment: codeComment
        )
    }

    // MARK: Classification

    struct Classification {
        var kind: SiteKind
        var replacement: ReplacementContext
        var api: String
        var role: String
        var table: String?
        var hasDefaultValue = false
        var replaceWholeCall: FunctionCallExprSyntax?
        /// Arguments of a whole-call replacement that would be lost (`bundle:`, `locale:`, …).
        var blockingArguments: [String] = []
        var codeComment: String?
    }

    private func classify(_ expression: ExprSyntax) -> Classification? {
        guard let parent = expression.parent else { return nil }

        if let argument = parent.as(LabeledExprSyntax.self),
           let call = argument.parent?.parent?.as(FunctionCallExprSyntax.self) {
            return classifyArgument(argument, in: call)
        }

        if let infix = parent.as(InfixOperatorExprSyntax.self), infix.operator.is(AssignmentExprSyntax.self),
           infix.rightOperand.id == expression.id {
            let name: String?
            if let member = infix.leftOperand.as(MemberAccessExprSyntax.self) {
                name = member.declName.baseName.text
            } else if let reference = infix.leftOperand.as(DeclReferenceExprSyntax.self) {
                name = reference.baseName.text
            } else {
                name = nil
            }
            guard let name else { return nil }
            if APITables.userFacingProperties.contains(name) || userFacing.properties.contains(name) {
                return Classification(kind: .unlocalized, replacement: .string, api: infix.leftOperand.trimmedDescription, role: roleForName(name))
            }
            return nil
        }

        if let initializer = parent.as(InitializerClauseSyntax.self),
           let binding = initializer.parent?.as(PatternBindingSyntax.self),
           let identifier = binding.pattern.as(IdentifierPatternSyntax.self) {
            return classifyNamedValue(identifier.identifier.text, type: binding.typeAnnotation?.type)
        }

        if let (name, type) = enclosingReturningDeclaration(of: expression) {
            return classifyNamedValue(name, type: type)
        }

        return nil
    }

    private func classifyNamedValue(_ name: String, type: TypeSyntax?) -> Classification? {
        if let type {
            let typeName = type.trimmedDescription
            if typeName == "LocalizedStringKey" || typeName == "LocalizedStringResource" {
                return Classification(kind: .localizedText, replacement: .swiftUIKey, api: name, role: roleForName(name))
            }
            guard ["String", "String?", "String!"].contains(typeName) else { return nil }
        }
        guard APITables.isUserFacingName(name) || userFacing.properties.contains(name) else { return nil }
        return Classification(kind: .unlocalized, replacement: .string, api: name, role: roleForName(name))
    }

    /// For a literal that is the result of a computed property or function
    /// (`var title: String { "Settings" }`, `case .a: return "A"`), returns its name and type.
    private func enclosingReturningDeclaration(of expression: ExprSyntax) -> (String, TypeSyntax?)? {
        var node: Syntax = Syntax(expression)
        var sawReturnPosition = false
        while let parent = node.parent {
            if parent.is(ReturnStmtSyntax.self) {
                sawReturnPosition = true
            } else if let item = parent.as(CodeBlockItemSyntax.self) {
                // Implicit return: the expression must be the only item of its block.
                if let list = item.parent?.as(CodeBlockItemListSyntax.self), list.count == 1 {
                    sawReturnPosition = true
                } else if !sawReturnPosition {
                    return nil
                }
            } else if let binding = parent.as(PatternBindingSyntax.self) {
                guard sawReturnPosition, let identifier = binding.pattern.as(IdentifierPatternSyntax.self) else { return nil }
                return (identifier.identifier.text, binding.typeAnnotation?.type)
            } else if let function = parent.as(FunctionDeclSyntax.self) {
                guard sawReturnPosition else { return nil }
                return (function.name.text, function.signature.returnClause?.type)
            } else if parent.is(ClosureExprSyntax.self) || parent.is(FunctionCallExprSyntax.self)
                        || parent.is(InfixOperatorExprSyntax.self) || parent.is(ArrayExprSyntax.self)
                        || parent.is(DictionaryExprSyntax.self) || parent.is(SubscriptCallExprSyntax.self) {
                return nil
            }
            node = parent
        }
        return nil
    }

    private func classifyArgument(_ argument: LabeledExprSyntax, in call: FunctionCallExprSyntax) -> Classification? {
        guard var classification = classifyArgumentKind(argument, in: call) else { return nil }
        guard classification.replaceWholeCall != nil else { return classification }
        // A whole-call rewrite keeps the table (via the catalog) and the comment (moved to the
        // catalog); anything else would be silently dropped.
        let keptLabels: Set<String> = ["table", "tableName", "comment"]
        var blocking: [String] = []
        for other in call.arguments where other.id != argument.id {
            let label = other.label?.text ?? "_"
            if label == "comment" {
                classification.codeComment = other.expression.as(StringLiteralExprSyntax.self)?.representedLiteralValue
                    .flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
            }
            if !keptLabels.contains(label) { blocking.append(label) }
        }
        if call.trailingClosure != nil { blocking.append("trailing closure") }
        classification.blockingArguments = blocking
        return classification
    }

    private func classifyArgumentKind(_ argument: LabeledExprSyntax, in call: FunctionCallExprSyntax) -> Classification? {
        let label = argument.label?.text ?? "_"
        let callee = calleeName(call.calledExpression)
        let arguments = Array(call.arguments)
        let isFirst = arguments.first?.id == argument.id
        let table = arguments.first { ["table", "tableName"].contains($0.label?.text ?? "") }?
            .expression.as(StringLiteralExprSyntax.self)?.representedLiteralValue

        if APITables.ignoredCallees.contains(callee) { return nil }

        // Localization APIs.
        switch callee {
        case "String" where label == "localized":
            let hasDefault = arguments.contains { $0.label?.text == "defaultValue" }
            return Classification(kind: .localizedText, replacement: .stringLocalizedCall, api: "String(localized:)", role: "text", table: table, hasDefaultValue: hasDefault, replaceWholeCall: call)
        case "String" where label == "format" && isFirst:
            return Classification(kind: .formatString, replacement: .string, api: "String(format:)", role: "text")
        case "AttributedString" where label == "localized":
            return Classification(kind: .localizedText, replacement: .swiftUIKey, api: "AttributedString(localized:)", role: "text", table: table)
        case "LocalizedStringResource" where label == "_" && isFirst:
            let hasDefault = arguments.contains { $0.label?.text == "defaultValue" }
            return Classification(kind: .localizedText, replacement: .resourceCall, api: "LocalizedStringResource", role: "text", table: table, hasDefaultValue: hasDefault, replaceWholeCall: call)
        case "LocalizedStringKey" where isFirst:
            return Classification(kind: .localizedText, replacement: .swiftUIKey, api: "LocalizedStringKey", role: "text")
        case "NSLocalizedString" where isFirst:
            let hasDefault = arguments.contains { $0.label?.text == "value" }
            return Classification(kind: .localizedText, replacement: .nsLocalizedCall, api: "NSLocalizedString", role: "text", table: table, hasDefaultValue: hasDefault, replaceWholeCall: call)
        case "String", "AttributedString", "LocalizedStringResource", "LocalizedStringKey", "NSLocalizedString":
            if callee == "AttributedString", label == "_", isFirst {
                break
            }
            return nil
        case "Text":
            if label == "verbatim" { return nil }
            guard label == "_", isFirst else { return nil }
            return Classification(kind: .localizedText, replacement: .swiftUIText, api: "Text", role: roleForTextCall(call), table: table, replaceWholeCall: call)
        default:
            break
        }

        if let entry = APITables.swiftUIKeyAPIs[callee], entry.labels.contains(label), label != "_" || isFirst {
            return Classification(kind: .localizedText, replacement: .swiftUIKey, api: displayName(callee, call: call), role: entry.role, table: table)
        }
        if let entry = APITables.stringAPIs[callee], entry.labels.contains(label), label != "_" || isFirst {
            let role: String
            switch (entry.role, label) {
            case ("alert", "title"): role = "alertTitle"
            case ("alert", "message"), (_, "message"): role = "alertMessage"
            default: role = entry.role
            }
            return Classification(kind: .unlocalized, replacement: .string, api: "\(displayName(callee, call: call))(\(label == "_" ? "" : label + ":"))", role: role)
        }
        if let custom = userFacing.functions.first(where: { $0.name == callee }), custom.labels.contains(label) {
            return Classification(kind: .unlocalized, replacement: .string, api: "\(callee)(\(label == "_" ? "" : label + ":"))", role: roleForName(label == "_" ? callee : label))
        }
        if label != "_", APITables.userFacingLabels.contains(label) {
            return Classification(kind: .unlocalized, replacement: .string, api: "\(callee)(\(label):)", role: roleForName(label))
        }
        return nil
    }

    private func calleeName(_ expression: ExprSyntax) -> String {
        if let reference = expression.as(DeclReferenceExprSyntax.self) {
            return reference.baseName.text
        }
        if let member = expression.as(MemberAccessExprSyntax.self) {
            let name = member.declName.baseName.text
            if name == "init", let base = member.base {
                return calleeName(base)
            }
            return name
        }
        if let generic = expression.as(GenericSpecializationExprSyntax.self) {
            return calleeName(generic.expression)
        }
        return expression.trimmedDescription
    }

    private func displayName(_ callee: String, call: FunctionCallExprSyntax) -> String {
        call.calledExpression.is(MemberAccessExprSyntax.self) && callee.first?.isLowercase == true ? ".\(callee)" : callee
    }

    /// `Text` inside `Button { Text("…") }` is a button title; elsewhere plain text.
    private func roleForTextCall(_ call: FunctionCallExprSyntax) -> String {
        var node: Syntax? = Syntax(call).parent
        var depth = 0
        while let current = node, depth < 6 {
            if let outer = current.as(FunctionCallExprSyntax.self) {
                let name = calleeName(outer.calledExpression)
                if let entry = APITables.swiftUIKeyAPIs[name], name != "Text" { return entry.role }
                return "text"
            }
            node = current.parent
            depth += 1
        }
        return "text"
    }

    private func roleForName(_ name: String) -> String {
        let word = APITables.lastCamelWord(name)
        switch word {
        case "title", "headline", "heading": return "title"
        case "subtitle": return "subtitle"
        case "message", "body", "informativetext", "messagetext": return "message"
        case "placeholder", "prompt": return "placeholder"
        case "hint": return "hint"
        case "caption": return "caption"
        default:
            if name.hasPrefix("accessibility") { return "a11yLabel" }
            return word.isEmpty ? "text" : "label"
        }
    }

    private func enclosingTypeName(of node: Syntax) -> String? {
        var current = node.parent
        while let candidate = current {
            if let decl = candidate.as(StructDeclSyntax.self) { return decl.name.text }
            if let decl = candidate.as(ClassDeclSyntax.self) { return decl.name.text }
            if let decl = candidate.as(EnumDeclSyntax.self) { return decl.name.text }
            if let decl = candidate.as(ActorDeclSyntax.self) { return decl.name.text }
            if let decl = candidate.as(ExtensionDeclSyntax.self) { return decl.extendedType.trimmedDescription }
            current = candidate.parent
        }
        return nil
    }

    // MARK: Literal decoding

    private func segments(of literal: StringLiteralExprSyntax) -> [LiteralSegment]? {
        guard !literal.hasError, let kind = literal.stringLiteralKind, kind != .singleQuote else { return nil }
        var result: [LiteralSegment] = []
        for segment in literal.segments {
            switch segment {
            case .stringSegment(let text):
                var value = ""
                text.appendUnescapedLiteralValue(stringLiteralKind: kind, delimiterLength: literal.delimiterLength, to: &value)
                result.append(.text(value))
            case .expressionSegment(let interpolation):
                result.append(.expression(interpolation.expressions.trimmedDescription))
            }
        }
        return Self.mergeTextSegments(result)
    }

    static func mergeTextSegments(_ segments: [LiteralSegment]) -> [LiteralSegment] {
        var merged: [LiteralSegment] = []
        for segment in segments {
            if case .text(let text) = segment, case .text(let previous)? = merged.last {
                merged[merged.count - 1] = .text(previous + text)
            } else if case .text(let text) = segment, text.isEmpty {
                continue
            } else {
                merged.append(segment)
            }
        }
        return merged
    }

    /// The key Xcode extracts for a localized literal: interpolations become `%@`/`%lld`.
    static func xcodeKey(for segments: [LiteralSegment]) -> String {
        let interpolated = segments.contains { if case .expression = $0 { return true } else { return false } }
        return segments.map {
            switch $0 {
            case .text(let text): return interpolated ? text.replacingOccurrences(of: "%", with: "%%") : text
            case .expression(let expression): return PlaceholderGuess.guess(expression).specifier
            }
        }.joined()
    }
}

/// Best-effort format specifier for an interpolated expression, from syntax alone.
public enum PlaceholderGuess {
    public struct Guess: Equatable, Sendable {
        public var specifier: String
        /// `false` when the type is inferred from naming only; such fixes need review.
        public var confident: Bool
    }

    public static func guess(_ expression: String) -> Guess {
        let trimmed = expression.trimmingCharacters(in: .whitespaces)
        if Int(trimmed) != nil { return Guess(specifier: "%lld", confident: true) }
        if Double(trimmed) != nil { return Guess(specifier: "%lf", confident: true) }
        if trimmed.hasPrefix("\"") { return Guess(specifier: "%@", confident: true) }
        if trimmed.hasSuffix(".count") || trimmed.hasSuffix(".count)") { return Guess(specifier: "%lld", confident: true) }
        let lastIdentifier = trimmed.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "_" }).last.map(String.init) ?? trimmed
        let word = APITables.lastCamelWord(lastIdentifier)
        if ["count", "total", "number", "index", "quantity", "amount", "n", "num", "size", "age", "days", "hours", "minutes", "seconds"].contains(word) {
            return Guess(specifier: "%lld", confident: false)
        }
        return Guess(specifier: "%@", confident: false)
    }
}
