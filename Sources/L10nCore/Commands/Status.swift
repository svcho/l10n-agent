import Foundation

public struct LocaleStatus: Codable, Equatable, Sendable {
    public var locale: String
    public var approved = 0
    public var needsReview = 0
    public var missing = 0
    public var stale = 0
    public var total = 0

    public var percentComplete: Int {
        total == 0 ? 100 : Int((Double(approved + needsReview) / Double(total) * 100).rounded(.down))
    }
}

public struct CatalogStatus: Codable, Equatable, Sendable {
    public var catalog: String
    public var sourceLanguage: String
    public var keys: Int
    public var manualKeys: Int
    public var locales: [LocaleStatus]
}

public struct StatusReport: Codable, Equatable, Sendable {
    public var sourceLanguage: String
    public var targetLocales: [String]
    public var codeStyle: String
    public var catalogs: [CatalogStatus]
}

public enum StatusCommand {
    public static func run(project: Project) throws -> StatusReport {
        let catalogs = try project.loadCatalogs()
        let locales = project.targetLocales(catalogs: catalogs)
        let fingerprints = try FingerprintStore.load(root: project.root)
        var result: [CatalogStatus] = []
        for catalog in catalogs {
            let path = project.relativePath(catalog.url)
            var perLocale = Dictionary(uniqueKeysWithValues: locales.map { ($0, LocaleStatus(locale: $0)) })
            var keyCount = 0
            var manual = 0
            for (key, entry) in catalog.entries {
                keyCount += 1
                if entry.isManual { manual += 1 }
                guard entry.shouldTranslate, !entry.isStale else { continue }
                let sourceNode = entry.sourceNode(key: key, sourceLanguage: catalog.sourceLanguage)
                // Like lint: values without letters ("%lld", "•") need no translation.
                guard FormatSpecifier.hasText(sourceNode.leaves.first?.unit.value ?? key) else { continue }
                let fingerprint = FingerprintStore.sourceFingerprint(sourceNode)
                for locale in locales {
                    perLocale[locale]!.total += 1
                    guard TranslationEngine.isComplete(entry.localization(locale), source: sourceNode, locale: locale, overrides: project.config.pluralCategories),
                          let leaves = entry.localization(locale)?.leaves else {
                        perLocale[locale]!.missing += 1
                        continue
                    }
                    if let recorded = fingerprints.fingerprint(catalog: path, key: key, locale: locale), recorded != fingerprint {
                        perLocale[locale]!.stale += 1
                    }
                    if leaves.allSatisfy(\.unit.isApproved) {
                        perLocale[locale]!.approved += 1
                    } else {
                        perLocale[locale]!.needsReview += 1
                    }
                }
            }
            result.append(CatalogStatus(catalog: path, sourceLanguage: catalog.sourceLanguage, keys: keyCount, manualKeys: manual, locales: locales.compactMap { perLocale[$0] }))
        }
        return StatusReport(sourceLanguage: project.sourceLanguage, targetLocales: locales, codeStyle: project.usesSymbols ? "symbols" : "literal", catalogs: result)
    }

    /// `catalog locale percent%` for every catalog/locale below `percent`. With
    /// `approvedOnly`, translations waiting for review do not count.
    public static func below(_ report: StatusReport, percent: Int, approvedOnly: Bool = false) -> [String] {
        report.catalogs.flatMap { catalog in
            catalog.locales.compactMap { locale -> String? in
                let value = approvedOnly
                    ? (locale.total == 0 ? 100 : Int((Double(locale.approved) / Double(locale.total) * 100).rounded(.down)))
                    : locale.percentComplete
                return value < percent ? "\(catalog.catalog) \(locale.locale) \(value)%" : nil
            }
        }
    }

    public static func text(_ report: StatusReport) -> String {
        var lines = ["Source language: \(report.sourceLanguage)", "Target locales: \(report.targetLocales.isEmpty ? "(none)" : report.targetLocales.joined(separator: ", "))", "Code style: \(report.codeStyle)"]
        if report.catalogs.isEmpty {
            lines.append("No String Catalogs (.xcstrings) found.")
        }
        for catalog in report.catalogs {
            lines.append("")
            lines.append("\(catalog.catalog)  (\(catalog.keys) keys, \(catalog.manualKeys) manual)")
            for locale in catalog.locales {
                let name = locale.locale.padding(toLength: 8, withPad: " ", startingAt: 0)
                lines.append("  \(name) \(String(locale.percentComplete).leftPad(3))%  approved \(locale.approved), needs review \(locale.needsReview), missing \(locale.missing), stale \(locale.stale)")
            }
        }
        return lines.joined(separator: "\n")
    }
}

extension String {
    func leftPad(_ length: Int) -> String {
        count >= length ? self : String(repeating: " ", count: length - count) + self
    }
}
