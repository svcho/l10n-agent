import Foundation

/// CLDR cardinal plural categories per language, as Xcode's String Catalog editor offers them.
public enum PluralRules {
    static let table: [String: [String]] = [
        "ar": ["zero", "one", "two", "few", "many", "other"],
        "be": ["one", "few", "many", "other"],
        "bs": ["one", "few", "other"],
        "ca": ["one", "many", "other"],
        "cs": ["one", "few", "many", "other"],
        "cy": ["zero", "one", "two", "few", "many", "other"],
        "es": ["one", "many", "other"],
        "fr": ["one", "many", "other"],
        "ga": ["one", "two", "few", "many", "other"],
        "he": ["one", "two", "other"],
        "hr": ["one", "few", "other"],
        "id": ["other"],
        "it": ["one", "many", "other"],
        "ja": ["other"],
        "km": ["other"],
        "ko": ["other"],
        "lo": ["other"],
        "lt": ["one", "few", "many", "other"],
        "lv": ["zero", "one", "other"],
        "ms": ["other"],
        "my": ["other"],
        "pl": ["one", "few", "many", "other"],
        "pt": ["one", "many", "other"],
        "ro": ["one", "few", "other"],
        "ru": ["one", "few", "many", "other"],
        "sk": ["one", "few", "many", "other"],
        "sl": ["one", "two", "few", "other"],
        "sr": ["one", "few", "other"],
        "th": ["other"],
        "uk": ["one", "few", "many", "other"],
        "vi": ["other"],
        "yue": ["other"],
        "zh": ["other"],
    ]

    public static func categories(for locale: String) -> [String] {
        let language = locale.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map { String($0).lowercased() } ?? locale
        return table[language] ?? ["one", "other"]
    }
}

public enum LanguageNames {
    public static func displayName(_ code: String) -> String {
        Locale(identifier: "en").localizedString(forIdentifier: code) ?? code
    }
}
