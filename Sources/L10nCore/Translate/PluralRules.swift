import Foundation

/// CLDR cardinal plural categories per language (CLDR 46 `plurals.xml`), as Xcode's
/// String Catalog editor offers them.
public enum PluralRules {
    public static let allCategories: [String] = ["zero", "one", "two", "few", "many", "other"]

    private static let groups: [([String], [String])] = [
        (["other"], [
            "bm", "bo", "dz", "hnj", "id", "ig", "ii", "in", "ja", "jbo", "jv", "jw", "kde", "kea", "km", "ko",
            "lkt", "lo", "ms", "my", "nqo", "osa", "sah", "ses", "sg", "su", "th", "to", "tpi", "vi", "wo", "yo",
            "yue", "zh",
        ]),
        (["one", "other"], [
            "af", "ak", "am", "an", "as", "asa", "ast", "az", "bal", "bem", "bez", "bg", "bho", "bn", "brx", "ce",
            "ceb", "cgg", "chr", "ckb", "da", "de", "doi", "dv", "ee", "el", "en", "eo", "et", "eu", "fa", "ff",
            "fi", "fil", "fo", "fur", "fy", "gl", "gsw", "gu", "guw", "ha", "haw", "hi", "hu", "hy", "ia", "io",
            "is", "ji", "jgo", "jmc", "ka", "kab", "kaj", "kcg", "kk", "kkj", "kl", "kn", "ks", "ksb", "ku", "ky",
            "lb", "lg", "lij", "ln", "mas", "mg", "mgo", "mk", "ml", "mn", "mr", "nah", "nb", "nd", "ne", "nl",
            "nn", "nnh", "no", "nr", "nso", "ny", "nyn", "om", "or", "os", "pa", "pap", "pcm", "ps", "rm", "rof",
            "rwk", "saq", "sc", "sd", "sdh", "seh", "si", "sn", "so", "sq", "ss", "ssy", "st", "sv", "sw", "syr",
            "ta", "te", "teo", "ti", "tig", "tk", "tl", "tn", "tr", "ts", "tzm", "ug", "ur", "uz", "ve", "vo",
            "vun", "wa", "wae", "xh", "xog", "yi", "zu",
        ]),
        (["zero", "one", "other"], ["blo", "ksh", "lag", "lv", "prg"]),
        (["one", "two", "other"], ["he", "iu", "naq", "sat", "se", "sma", "smi", "smj", "smn", "sms"]),
        (["one", "few", "other"], ["bs", "hr", "mo", "ro", "sh", "shi", "sr"]),
        (["one", "two", "few", "other"], ["dsb", "gd", "hsb", "sl"]),
        (["one", "few", "many", "other"], ["be", "cs", "lt", "pl", "ru", "sk", "uk"]),
        (["one", "many", "other"], ["ca", "es", "fr", "it", "lld", "pt", "scn", "vec"]),
        (["one", "two", "few", "many", "other"], ["br", "ga", "gv", "mt"]),
        (["zero", "one", "two", "few", "many", "other"], ["ar", "ars", "cy", "kw"]),
    ]

    private static let table: [String: [String]] = {
        var table: [String: [String]] = [:]
        for (categories, languages) in groups {
            for language in languages { table[language] = categories }
        }
        return table
    }()

    /// Categories for a locale such as `pt-BR` or `zh-Hans`, or `nil` when the language is
    /// unknown. `overrides` (from `pluralCategories:` in the config) take precedence and
    /// may name a full locale or its language.
    public static func categories(for locale: String, overrides: [String: [String]] = [:]) -> [String]? {
        if let override = overrides[locale] { return override }
        let language = locale.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map { String($0).lowercased() } ?? locale
        return overrides[language] ?? table[language]
    }

    /// Validates a config override: known category names, always including `other`.
    static func validate(_ categories: [String]) -> Bool {
        categories.contains("other") && categories.allSatisfy(allCategories.contains) && Set(categories).count == categories.count
    }
}

public enum LanguageNames {
    public static func displayName(_ code: String) -> String {
        Locale(identifier: "en").localizedString(forIdentifier: code) ?? code
    }
}
