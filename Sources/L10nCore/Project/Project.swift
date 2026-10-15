import Foundation

/// Settings read from `project.pbxproj` files.
public struct XcodeSettings: Equatable, Sendable {
    public var projectFiles: [URL] = []
    public var knownRegions: [String] = []
    public var developmentRegion: String?
    /// `true` when any build configuration sets `STRING_CATALOG_GENERATE_SYMBOLS = YES`.
    public var generatesSymbols: Bool = false

    public static func read(projects: [URL]) -> XcodeSettings {
        var settings = XcodeSettings()
        settings.projectFiles = projects
        var regions: [String] = []
        for project in projects {
            guard let text = try? String(contentsOf: project.appendingPathComponent("project.pbxproj"), encoding: .utf8) else { continue }
            if let match = text.firstMatch(of: /knownRegions\s*=\s*\(([^)]*)\)/) {
                for region in match.1.split(separator: ",") {
                    let cleaned = region.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"")))
                    if !cleaned.isEmpty, !regions.contains(cleaned) { regions.append(cleaned) }
                }
            }
            if settings.developmentRegion == nil, let match = text.firstMatch(of: /developmentRegion\s*=\s*"?([A-Za-z0-9_-]+)"?\s*;/) {
                settings.developmentRegion = String(match.1)
            }
            if text.contains(/STRING_CATALOG_GENERATE_SYMBOLS\s*=\s*YES/) {
                settings.generatesSymbols = true
            }
        }
        settings.knownRegions = regions
        return settings
    }
}

/// A discovered project: config, catalogs, Swift sources and Xcode settings.
public struct Project: Sendable {
    public let root: URL
    public let config: L10nConfig
    public let catalogURLs: [URL]
    public let swiftFiles: [URL]
    public let xcode: XcodeSettings

    static let skippedDirectories: Set<String> = [
        ".git", ".build", ".swiftpm", "DerivedData", "Pods", "Carthage", "node_modules", "build", ".l10n-agent",
    ]

    public static func discover(root: URL) throws -> Project {
        let root = root.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw L10nError.notFound("Project directory not found: \(root.path)")
        }
        let config = try L10nConfig.load(root: root)
        let includeMatchers = config.include.map(Glob.init)
        let excludeMatchers = config.exclude.map(Glob.init)

        var catalogs: [URL] = []
        var swiftFiles: [URL] = []
        var projects: [URL] = []

        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        )
        while let url = enumerator?.nextObject() as? URL {
            let name = url.lastPathComponent
            let relative = PathUtil.relative(url, to: root)
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir {
                if url.pathExtension == "xcodeproj" {
                    projects.append(url.standardizedFileURL)
                    enumerator?.skipDescendants()
                } else if skippedDirectories.contains(name) || name.hasPrefix(".")
                    || ["xcassets", "xcworkspace", "lproj"].contains(url.pathExtension)
                    || excludeMatchers.contains(where: { $0.matches(relative) || $0.matches(relative + "/") }) {
                    enumerator?.skipDescendants()
                }
                continue
            }
            if excludeMatchers.contains(where: { $0.matches(relative) }) { continue }
            if !includeMatchers.isEmpty, !includeMatchers.contains(where: { $0.matches(relative) }) { continue }
            switch url.pathExtension {
            case "xcstrings": catalogs.append(url.standardizedFileURL)
            case "swift":
                // Package manifests are build configuration, not app code.
                if name == "Package.swift" || (name.hasPrefix("Package@swift-") && name.hasSuffix(".swift")) { continue }
                swiftFiles.append(url.standardizedFileURL)
            default: break
            }
        }

        let sortByPath: (URL, URL) -> Bool = { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }
        return Project(
            root: root,
            config: config,
            catalogURLs: catalogs.sorted(by: sortByPath),
            swiftFiles: swiftFiles.sorted(by: sortByPath),
            xcode: XcodeSettings.read(projects: projects.sorted(by: sortByPath))
        )
    }

    public var sourceLanguage: String {
        if let configured = config.sourceLanguage { return configured }
        if let firstCatalog = catalogURLs.first, let catalog = try? StringCatalog.load(firstCatalog) {
            return catalog.sourceLanguage
        }
        return xcode.developmentRegion ?? "en"
    }

    /// Locales that must be translated: config, then Xcode `knownRegions`, then catalog contents.
    public func targetLocales(catalogs: [StringCatalog]) -> [String] {
        let source = sourceLanguage
        if let configured = config.locales {
            return configured.filter { $0 != source }
        }
        let regions = xcode.knownRegions.filter { $0 != "Base" && $0 != source }
        if !regions.isEmpty { return regions }
        var found = Set<String>()
        for catalog in catalogs { found.formUnion(catalog.locales) }
        found.remove(source)
        return found.sorted()
    }

    public var usesSymbols: Bool {
        switch config.codeStyle {
        case .symbols: return true
        case .literal: return false
        case .auto: return xcode.generatesSymbols
        }
    }

    public func loadCatalogs() throws -> [StringCatalog] {
        let fallback = config.sourceLanguage ?? xcode.developmentRegion ?? "en"
        return try catalogURLs.map { try StringCatalog.load($0, fallbackSourceLanguage: fallback) }
    }

    /// The catalog new keys for `file` go into: the configured catalog, else the
    /// nearest `Localizable.xcstrings` in an ancestor directory, else the only catalog.
    public func defaultCatalogURL(for file: URL?) -> URL? {
        if let configured = config.catalog {
            return root.appendingPathComponent(configured).standardizedFileURL
        }
        let localizable = catalogURLs.filter { $0.lastPathComponent == "Localizable.xcstrings" }
        if let file {
            let filePath = file.standardizedFileURL.path
            let candidates = localizable.filter { filePath.hasPrefix($0.deletingLastPathComponent().path + "/") }
            if let nearest = candidates.max(by: { $0.path.count < $1.path.count }) { return nearest }
        }
        if localizable.count == 1 { return localizable[0] }
        if catalogURLs.count == 1 { return catalogURLs[0] }
        return localizable.first
    }

    /// Catalogs a source file can see for a table. Package targets only see their own
    /// catalogs; app files see the nearest catalog in an ancestor directory. When that is
    /// ambiguous (several candidates, none an ancestor), all candidates are returned.
    public func catalogURLs(forTable table: String, file: URL) -> [URL] {
        let candidates = catalogURLs.filter { $0.deletingPathExtension().lastPathComponent == table }
        if let target = PackageTarget.directory(for: file, root: root) {
            return candidates.filter { $0.path.hasPrefix(target.path + "/") }
        }
        let appCandidates = candidates.filter { PackageTarget.directory(for: $0, root: root) == nil }
        let filePath = file.standardizedFileURL.path
        if let nearest = appCandidates.filter({ filePath.hasPrefix($0.deletingLastPathComponent().path + "/") })
            .max(by: { $0.path.count < $1.path.count }) {
            return [nearest]
        }
        return appCandidates
    }

    public func relativePath(_ url: URL) -> String {
        PathUtil.relative(url, to: root)
    }
}

/// Minimal glob: `**` matches across directories, `*` within a path component, `?` one character.
public struct Glob: Sendable {
    private let regex: NSRegularExpression

    public init(_ pattern: String) {
        var expression = "^"
        var index = pattern.startIndex
        while index < pattern.endIndex {
            let character = pattern[index]
            if character == "*" {
                let next = pattern.index(after: index)
                if next < pattern.endIndex, pattern[next] == "*" {
                    let afterStars = pattern.index(after: next)
                    if afterStars < pattern.endIndex, pattern[afterStars] == "/" {
                        expression += "(?:.*/)?"
                        index = pattern.index(after: afterStars)
                    } else {
                        expression += ".*"
                        index = afterStars
                    }
                    continue
                }
                expression += "[^/]*"
            } else if character == "?" {
                expression += "[^/]"
            } else {
                expression += NSRegularExpression.escapedPattern(for: String(character))
            }
            index = pattern.index(after: index)
        }
        expression += "$"
        regex = try! NSRegularExpression(pattern: expression)
    }

    public func matches(_ path: String) -> Bool {
        regex.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)) != nil
    }
}
