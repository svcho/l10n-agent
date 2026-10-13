import Foundation

public enum OutputFormat: String, CaseIterable, Sendable {
    case text
    /// `path:line:column: warning: message [L10N001]`, shown inline by Xcode build phases.
    case xcode
    case json
    case sarif
}

public enum Reporter {
    public static func render(_ report: LintReport, format: OutputFormat, root: URL) -> String {
        switch format {
        case .text: return text(report)
        case .xcode: return xcode(report, root: root)
        case .json: return JSONOutput.encode(report)
        case .sarif: return sarif(report)
        }
    }

    static func text(_ report: LintReport) -> String {
        var lines: [String] = []
        var currentFile: String?
        for diagnostic in report.diagnostics {
            if diagnostic.file != currentFile {
                if currentFile != nil { lines.append("") }
                lines.append(diagnostic.file)
                currentFile = diagnostic.file
            }
            let location = diagnostic.line.map { "\($0)" + (diagnostic.column.map { ":\($0)" } ?? "") } ?? "-"
            let fix = diagnostic.fixable ? " (fixable)" : ""
            lines.append("  \(location.padding(toLength: 8, withPad: " ", startingAt: 0)) \(diagnostic.severity.rawValue.padding(toLength: 7, withPad: " ", startingAt: 0)) \(diagnostic.rule) \(diagnostic.message)\(fix)")
        }
        let summary = report.summary
        if !lines.isEmpty { lines.append("") }
        lines.append("\(summary.errors) error\(summary.errors == 1 ? "" : "s"), \(summary.warnings) warning\(summary.warnings == 1 ? "" : "s"), \(summary.infos) info in \(summary.swiftFiles) Swift file\(summary.swiftFiles == 1 ? "" : "s") and \(summary.catalogs) catalog\(summary.catalogs == 1 ? "" : "s")")
        return lines.joined(separator: "\n")
    }

    static func xcode(_ report: LintReport, root: URL) -> String {
        report.diagnostics.map { diagnostic in
            let path = root.appendingPathComponent(diagnostic.file).path
            let level: String
            switch diagnostic.severity {
            case .error: level = "error"
            case .warning: level = "warning"
            default: level = "note"
            }
            return "\(path):\(diagnostic.line ?? 1):\(diagnostic.column ?? 1): \(level): \(diagnostic.message) [\(diagnostic.rule)]"
        }.joined(separator: "\n")
    }

    static func sarif(_ report: LintReport) -> String {
        let rules: [JSONValue] = Rules.all.map { rule in
            .object(JSONObject([
                "id": .string(rule.id),
                "name": .string(rule.name),
                "shortDescription": .object(JSONObject(["text": .string(rule.summary)])),
            ]))
        }
        let results: [JSONValue] = report.diagnostics.map { diagnostic in
            let level: String
            switch diagnostic.severity {
            case .error: level = "error"
            case .warning: level = "warning"
            default: level = "note"
            }
            var region = JSONObject(["startLine": .number(String(diagnostic.line ?? 1))])
            if let column = diagnostic.column { region["startColumn"] = .number(String(column)) }
            return .object(JSONObject([
                "ruleId": .string(diagnostic.rule),
                "level": .string(level),
                "message": .object(JSONObject(["text": .string(diagnostic.message)])),
                "locations": .array([.object(JSONObject([
                    "physicalLocation": .object(JSONObject([
                        "artifactLocation": .object(JSONObject(["uri": .string(diagnostic.file)])),
                        "region": .object(region),
                    ])),
                ]))]),
            ]))
        }
        let document = JSONValue.object(JSONObject([
            "$schema": .string("https://json.schemastore.org/sarif-2.1.0.json"),
            "version": .string("2.1.0"),
            "runs": .array([.object(JSONObject([
                "tool": .object(JSONObject(["driver": .object(JSONObject([
                    "name": .string("l10n-agent"),
                    "informationUri": .string("https://github.com/svcho/l10n-agent"),
                    "rules": .array(rules),
                ]))])),
                "results": .array(results),
            ]))]),
        ]))
        return XcodeJSONWriter.string(document)
    }
}

public enum JSONOutput {
    public static func encode<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }
}
