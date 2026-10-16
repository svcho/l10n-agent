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
        checks.append(DoctorCheck(name: "code-style", status: .ok, detail: codeStyleDetail(project)))
        checks.append(DoctorCheck(name: "swift-files", status: .ok, detail: swiftFilesDetail(project)))

        let config = project.config.translator
        do {
            let model = try await ChatModelFactory.make(config)
            let remote = await ChatModelFactory.isRemote(config, model: model.name)
            checks.append(DoctorCheck(name: "translator", status: .ok, detail: translatorDetail(config, model: model.name, remote: remote)))
        } catch {
            checks.append(DoctorCheck(name: "translator", status: .warning, detail: "\(error) (lint and fix still work; translate needs a local model)"))
        }
        return DoctorReport(checks: checks)
    }

    /// Files the scanner reads; tests and generated files are skipped and only counted.
    static func swiftFilesDetail(_ project: Project) -> String {
        let scanned = project.swiftFiles.filter { url in
            guard !project.isTestSource(url), let source = try? String(contentsOf: url, encoding: .utf8) else { return false }
            return !SwiftScanner.isSkipped(path: project.relativePath(url), source: source)
        }.count
        let skipped = project.swiftFiles.count - scanned
        return "\(scanned) Swift file(s) scanned\(skipped > 0 ? " (\(skipped) test or generated file(s) skipped)" : "")"
    }

    static func translatorDetail(_ config: TranslatorConfig, model: String, remote: Bool) -> String {
        let where_ = remote
            ? "runs remotely (allowed by translator.allowRemote and L10N_AGENT_ALLOW_REMOTE=1; strings leave this machine)"
            : "local only"
        return "\(config.provider.rawValue) at \(config.baseURL), model \(model), \(where_)"
    }

    static func codeStyleDetail(_ project: Project) -> String {
        switch project.config.codeStyle {
        case .symbols: return "generated symbols (Text(.key)), set by codeStyle: symbols"
        case .literal: return "String(localized:defaultValue:comment:) literals, set by codeStyle: literal"
        case .auto: break
        }
        var parts: [String] = []
        for projectFile in project.xcode.projectFiles {
            let name = projectFile.lastPathComponent
            switch project.xcode.symbolGeneration[projectFile.path] ?? .disabled {
            case .enabled:
                parts.append("\(name): generated symbols")
            case .mixed:
                let off = project.xcode.symbolsDisabledIn[projectFile.path] ?? []
                parts.append("\(name): literals, because STRING_CATALOG_GENERATE_SYMBOLS = NO in \(off.joined(separator: ", ")); set it to YES there (or codeStyle: symbols) to use symbols")
            case .disabled:
                parts.append("\(name): literals; enable STRING_CATALOG_GENERATE_SYMBOLS (or set codeStyle: symbols) to use symbols")
            }
        }
        if parts.isEmpty { return "String(localized:defaultValue:comment:) literals (no Xcode project found)" }
        return parts.joined(separator: "; ") + ". Swift package targets always use literals."
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
