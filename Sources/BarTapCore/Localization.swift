import Foundation

public enum AppLanguage: String, CaseIterable {
    case system, en, zhHans = "zh-Hans"
}

/// English strings are the keys; `ZhHans.table` holds the Simplified Chinese translations.
/// `scripts/check_l10n.py` fails the build if any localized literal lacks a translation.
public enum Loc {
    public static var language: AppLanguage = .system

    public static var isChinese: Bool {
        switch language {
        case .en: return false
        case .zhHans: return true
        case .system: return (Locale.preferredLanguages.first ?? "en").hasPrefix("zh")
        }
    }
}

public func L(_ key: String) -> String {
    Loc.isChinese ? (ZhHans.table[key] ?? key) : key
}

public func L(_ key: String, _ args: CVarArg...) -> String {
    String(format: L(key), arguments: args)
}
