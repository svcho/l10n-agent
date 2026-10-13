import Foundation

public struct DoctorCheck: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable { case ok, warning, error }
    public var name: String
    public var status: Status
    public var detail: String
}

public struct DoctorReport: Codable, Equatable, Sendable {
    public var checks: [DoctorCheck]
    public var ok: Bool { !checks.contains { $0.status == .error } }
}

public enum DoctorCommand {
    public static func run(project: Project) async -> DoctorReport {
        var checks: [DoctorCheck] = []

        if let version = Shell.run("/usr/bin/xcrun", ["xcodebuild", "-version"])?.split(separator: "\n").first {
            checks.append(DoctorCheck(name: "xcode", status: .ok, detail: String(version)))
        } else {
            checks.append(DoctorCheck(name: "xcode", status: .warning, detail: "Xcode not found; symbol name verification is unavailable"))
        }
        if Shell.run("/usr/bin/xcrun", ["--find", "xcstringstool"]) != nil {
            checks.append(DoctorCheck(name: "xcstringstool", status: .ok, detail: "available"))
        } else {
            checks.append(DoctorCheck(name: "xcstringstool", status: .warning, detail: "not found (needs Xcode 15+)"))
        }

        if project.catalogURLs.isEmpty {
            checks.append(DoctorCheck(name: "catalogs", status: .warning, detail: "No .xcstrings found. Create one in Xcode (File > New > File > String Catalog) or let `fix` create Localizable.xcstrings."))
        } else {
            var problems: [String] = []
            for url in project.catalogURLs {
                do { _ = try StringCatalog.load(url) } catch { problems.append("\(error)") }
            }
            checks.append(DoctorCheck(
                name: "catalogs",
                status: problems.isEmpty ? .ok : .error,
                detail: problems.isEmpty ? project.catalogURLs.map(project.relativePath).joined(separator: ", ") : problems.joined(separator: "; ")
            ))
        }

        let catalogs = (try? project.loadCatalogs()) ?? []
        let locales = project.targetLocales(catalogs: catalogs)
        checks.append(DoctorCheck(name: "locales", status: locales.isEmpty ? .warning : .ok, detail: locales.isEmpty ? "No target locales. Add languages in Xcode (Project > Info > Localizations) or set `locales:` in \(L10nConfig.fileName)." : "source \(project.sourceLanguage) → \(locales.joined(separator: ", "))"))
        checks.append(DoctorCheck(name: "code-style", status: .ok, detail: project.usesSymbols ? "generated symbols (Text(.key))" : "String(localized:defaultValue:comment:) literals; enable STRING_CATALOG_GENERATE_SYMBOLS or set codeStyle: symbols for symbols"))
        checks.append(DoctorCheck(name: "swift-files", status: .ok, detail: "\(project.swiftFiles.count) Swift file(s) in scope"))

        let config = project.config.translator
        do {
            let model = try await ChatModelFactory.make(config)
            checks.append(DoctorCheck(name: "translator", status: .ok, detail: "\(config.provider.rawValue) at \(config.baseURL), model \(model.name)\(HTTP.isLocal(URL(string: config.baseURL) ?? URL(fileURLWithPath: "/")) ? ", local only" : " (remote endpoint)")"))
        } catch {
            checks.append(DoctorCheck(name: "translator", status: .warning, detail: "\(error) (lint and fix still work; translate needs a local model)"))
        }
        return DoctorReport(checks: checks)
    }

    public static func text(_ report: DoctorReport) -> String {
        report.checks.map { check in
            let mark: String
            switch check.status {
            case .ok: mark = "ok  "
            case .warning: mark = "warn"
            case .error: mark = "FAIL"
            }
            return "[\(mark)] \(check.name): \(check.detail)"
        }.joined(separator: "\n")
    }
}

enum Shell {
    /// Runs a tool and returns stdout, or nil when it fails.
    static func run(_ executable: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
