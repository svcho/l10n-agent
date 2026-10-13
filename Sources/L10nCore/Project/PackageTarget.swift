import Foundation

/// Locates the Swift package target a source file belongs to.
///
/// A file counts as package code only when it lives under `Sources/<Target>/` of a
/// directory with a `Package.swift`, and that directory is not also an Xcode project
/// folder. A root `Package.swift` kept for tooling therefore does not turn app files
/// into package files.
public enum PackageTarget {
    /// The target directory (`…/Sources/<Target>`) containing `file`, if any.
    public static func directory(for file: URL, root: URL) -> URL? {
        guard let manifest = manifest(containing: file, root: root) else { return nil }
        let package = manifest.deletingLastPathComponent()
        let isXcodeFolder = ((try? FileManager.default.contentsOfDirectory(atPath: package.path)) ?? [])
            .contains { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") }
        if isXcodeFolder { return nil }
        let components = file.standardizedFileURL.pathComponents
        let packageComponents = package.standardizedFileURL.pathComponents
        guard components.count > packageComponents.count + 2,
              Array(components.prefix(packageComponents.count)) == packageComponents,
              components[packageComponents.count] == "Sources"
        else { return nil }
        return package.appendingPathComponent("Sources").appendingPathComponent(components[packageComponents.count + 1]).standardizedFileURL
    }

    /// The nearest `Package.swift` in an ancestor directory of `url`, within `root`.
    public static func manifest(containing url: URL, root: URL) -> URL? {
        let rootPath = root.standardizedFileURL.path
        var directory = url.deletingLastPathComponent().standardizedFileURL
        while directory.path == rootPath || directory.path.hasPrefix(rootPath + "/") {
            let candidate = directory.appendingPathComponent("Package.swift")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            if directory.path == rootPath { break }
            directory = directory.deletingLastPathComponent()
        }
        return nil
    }
}
