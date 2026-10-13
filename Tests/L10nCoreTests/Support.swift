import Foundation
@testable import L10nCore

enum TestSupport {
    static var fixturesURL: URL {
        Bundle.module.resourceURL!.appendingPathComponent("Fixtures")
    }

    /// Copies a fixture project to a fresh temporary directory.
    static func copyFixture(_ name: String) throws -> URL {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("l10n-agent-tests-\(UUID().uuidString)")
            .appendingPathComponent(name)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixturesURL.appendingPathComponent(name), to: destination)
        return destination
    }

    /// Creates a temporary project from file contents.
    static func makeProject(_ files: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("l10n-agent-tests-\(UUID().uuidString)")
        for (path, content) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
        }
        return root
    }

    static func catalogJSON(_ strings: [String: Any], sourceLanguage: String = "en", version: String = "1.1") -> String {
        let object: [String: Any] = ["sourceLanguage": sourceLanguage, "version": version, "strings": strings]
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    static func unit(_ value: String, state: String = "translated") -> [String: Any] {
        ["stringUnit": ["state": state, "value": value]]
    }

    static func manual(_ value: String, comment: String? = "A comment", translations: [String: [String: Any]] = [:]) -> [String: Any] {
        var localizations: [String: Any] = ["en": unit(value)]
        for (locale, node) in translations { localizations[locale] = node }
        var entry: [String: Any] = ["extractionState": "manual", "localizations": localizations]
        if let comment { entry["comment"] = comment }
        return entry
    }

    /// Runs a tool and returns (status, stdout+stderr).
    @discardableResult
    static func shell(_ arguments: [String], cwd: URL? = nil) -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        if let cwd { process.currentDirectoryURL = cwd }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (-1, "\(error)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    static var hasXcstringstool: Bool {
        shell(["xcrun", "--find", "xcstringstool"]).0 == 0
    }

    static var hasIOSSimulatorSDK: Bool {
        shell(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"]).0 == 0
    }
}
