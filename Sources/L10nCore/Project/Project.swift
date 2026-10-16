import Foundation

/// Settings read from `project.pbxproj` files.
public struct XcodeSettings: Equatable, Sendable {
    public var projectFiles: [URL] = []
    public var knownRegions: [String] = []
    public var developmentRegion: String?
    /// `true` when any project generates String Catalog symbols.
    public var generatesSymbols: Bool { symbolGeneration.values.contains(.enabled) }
    /// Per `.xcodeproj` (keyed by its path): whether symbol generation is on for every
    /// build configuration that sets it. Mixed projects count as disabled for rewrites.
    public var symbolGeneration: [String: SymbolGeneration] = [:]
    /// Per `.xcodeproj`: the build configurations (`Target/Debug`) that set
    /// `STRING_CATALOG_GENERATE_SYMBOLS = NO`. Unit and UI test bundles are ignored.
    public var symbolsDisabledIn: [String: [String]] = [:]

    public enum SymbolGeneration: String, Equatable, Sendable {
        case enabled
        case disabled
        case mixed
    }

    /// The setting of the project that owns `file`: the `.xcodeproj` whose folder is the
    /// nearest ancestor of the file, or the only project.
    public func symbolGeneration(for file: URL) -> SymbolGeneration {
        owningProject(for: file).flatMap { symbolGeneration[$0.path] } ?? .disabled
    }

    /// The `.xcodeproj` whose folder is the nearest ancestor of `file`, or the only project.
    /// `nil` when several projects sit in the same nearest folder and ownership cannot be told.
    public func owningProject(for file: URL) -> URL? {
        let filePath = file.standardizedFileURL.path
        let owners = projectFiles.filter { filePath.hasPrefix($0.deletingLastPathComponent().path + "/") }
        guard let deepest = owners.map({ $0.deletingLastPathComponent().path.count }).max() else {
            return projectFiles.count == 1 ? projectFiles[0] : nil
        }
        let nearest = owners.filter { $0.deletingLastPathComponent().path.count == deepest }
        return nearest.count == 1 ? nearest[0] : nil
    }

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
            let (enabled, disabled) = symbolSettings(pbxproj: text)
            settings.symbolGeneration[project.path] = !enabled.isEmpty ? (!disabled.isEmpty ? .mixed : .enabled) : .disabled
            if !disabled.isEmpty { settings.symbolsDisabledIn[project.path] = disabled }
        }
        settings.knownRegions = regions
        return settings
    }

    /// Build configurations that set `STRING_CATALOG_GENERATE_SYMBOLS` to YES and to NO,
    /// named `Target/Configuration` (`Project/Configuration` for project-level settings).
    /// Unit and UI test bundles never contain app strings, so their settings are ignored.
    static func symbolSettings(pbxproj text: String) -> (enabled: [String], disabled: [String]) {
        guard let plist = try? PropertyListSerialization.propertyList(from: Data(text.utf8), format: nil) as? [String: Any],
              let objects = plist["objects"] as? [String: [String: Any]]
        else {
            // Not a property list (or a stub): count the settings textually.
            let enabled = text.matches(of: /STRING_CATALOG_GENERATE_SYMBOLS\s*=\s*"?YES"?/).map { _ in "?" }
            let disabled = text.matches(of: /STRING_CATALOG_GENERATE_SYMBOLS\s*=\s*"?NO"?/).map { _ in "?" }
            return (enabled, disabled)
        }
        var owners: [String: (name: String, isTest: Bool)] = [:]   // configuration id → owner
        for object in objects.values {
            guard let isa = object["isa"] as? String, let listID = object["buildConfigurationList"] as? String,
                  let list = objects[listID], let configurations = list["buildConfigurations"] as? [String]
            else { continue }
            let owner: (String, Bool)
            switch isa {
            case "PBXNativeTarget", "PBXAggregateTarget", "PBXLegacyTarget":
                let productType = object["productType"] as? String ?? ""
                owner = (object["name"] as? String ?? "target", productType.contains("unit-test") || productType.contains("ui-testing"))
            case "PBXProject":
                owner = ("Project", false)
            default:
                continue
            }
            for configuration in configurations { owners[configuration] = owner }
        }
        var enabled: [String] = []
        var disabled: [String] = []
        for (id, object) in objects where object["isa"] as? String == "XCBuildConfiguration" {
            guard let settings = object["buildSettings"] as? [String: Any],
                  let value = settings["STRING_CATALOG_GENERATE_SYMBOLS"] as? String
            else { continue }
            let owner = owners[id] ?? ("?", false)
            if owner.isTest { continue }
            let name = "\(owner.name)/\(object["name"] as? String ?? "?")"
            if value == "YES" { enabled.append(name) } else if value == "NO" { disabled.append(name) }
        }
        return (enabled.sorted(), disabled.sorted())
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
        let resolvedRoot = root.resolvingSymlinksInPath().path
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
            // Symlinked files must resolve inside the project; nothing outside it is read.
            guard ["swift", "xcstrings"].contains(url.pathExtension),
                  url.resolvingSymlinksInPath().path.hasPrefix(resolvedRoot + "/")
            else { continue }
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

    /// Whether any code in the project may use generated symbols (used for symbol
    /// collision checks and reporting).
    public var usesSymbols: Bool {
        switch config.codeStyle {
        case .symbols: return true
        case .literal: return false
        case .auto: return xcode.generatesSymbols
        }
    }

    /// Whether rewrites in `file` may reference generated symbols. With `codeStyle: auto`
    /// this requires the owning Xcode project to enable symbol generation in every
    /// configuration; Swift package targets use literals.
    public func usesSymbols(for file: URL) -> Bool {
        switch config.codeStyle {
        case .symbols: return true
        case .literal: return false
        case .auto:
            if PackageTarget.directory(for: file, root: root) != nil { return false }
            return xcode.symbolGeneration(for: file) == .enabled
        }
    }

    /// Code style summary for a set of files: `symbols`, `literal` or `mixed`.
    public func codeStyleSummary(files: [URL]) -> String {
        let styles = Set(files.map { usesSymbols(for: $0) })
        if styles.isEmpty { return usesSymbols ? CodeStyle.symbols.rawValue : CodeStyle.literal.rawValue }
        if styles.count > 1 { return "mixed" }
        return styles.first! ? CodeStyle.symbols.rawValue : CodeStyle.literal.rawValue
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
        if let routed = routedCatalogDirectory(for: file) {
            return candidates.filter { $0.deletingLastPathComponent().standardizedFileURL.path == routed.path }
        }
        if let target = PackageTarget.directory(for: file, root: root) {
            return candidates.filter { $0.path.hasPrefix(target.path + "/") }
        }
        let appCandidates = candidates.filter { PackageTarget.directory(for: $0, root: root) == nil }
        let filePath = file.standardizedFileURL.path
        if let nearest = appCandidates.filter({ filePath.hasPrefix($0.deletingLastPathComponent().path + "/") })
            .max(by: { $0.path.count < $1.path.count }) {
            return [nearest]
        }
        // Catalogs in sibling folders (App/Resources next to App/Sources): use the ones of
        // the Xcode project that owns the file before treating the lookup as ambiguous.
        // A file owned by a project only sees that project's catalogs.
        let ownerFolders = xcode.projectFiles.map { $0.deletingLastPathComponent().path + "/" }
        if let owner = ownerFolders.filter({ filePath.hasPrefix($0) }).max(by: { $0.count < $1.count }) {
            // Several targets can share one project folder (FeatureA/Sources + FeatureA/Resources):
            // keep the catalogs whose folder shares the longest path prefix with the file.
            let owned = appCandidates.filter { $0.path.hasPrefix(owner) }
            let fileComponents = file.standardizedFileURL.deletingLastPathComponent().pathComponents
            let fileNames = Set(fileComponents).subtracting(Self.genericFolderNames)
            // Rank by shared path prefix, then by matching folder names
            // (Sources/FeatureA ↔ Resources/FeatureA). Remaining ties stay ambiguous.
            let scored = owned.map { catalog -> (URL, Int, Int) in
                let components = catalog.deletingLastPathComponent().pathComponents
                let prefix = zip(components, fileComponents).prefix { $0 == $1 }.count
                let overlap = Set(components.dropFirst(prefix)).intersection(fileNames).count
                return (catalog, prefix, overlap)
            }
            guard let best = scored.map({ ($0.1, $0.2) }).max(by: { $0 < $1 }) else { return [] }
            return scored.filter { ($0.1, $0.2) == best }.map(\.0)
        }
        return appCandidates
    }

    static let genericFolderNames: Set<String> = [
        "Sources", "Source", "Resources", "Resource", "src", "res", "Shared", "Localization", "Localizations", "Supporting Files",
    ]

    /// The catalog folder an explicit `catalogRoutes` entry assigns to `file`, if any.
    public func routedCatalogDirectory(for file: URL) -> URL? {
        let relative = relativePath(file)
        guard let route = config.catalogRoutes.first(where: { Glob($0.files).matches(relative) }) else { return nil }
        return root.appendingPathComponent(route.catalog).deletingLastPathComponent().standardizedFileURL
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
