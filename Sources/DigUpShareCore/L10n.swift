import Foundation

/// Tiny localization shim for DigUpShareCore (share extension + inbox).
/// Strings are Chinese-first to match DigUp Plus WeChat UX; English falls back to the same text.
public enum L10n {
    public static func text(_ value: String) -> String { value }
    public static func format(_ format: String, _ args: CVarArg...) -> String {
        String(format: format, locale: Locale(identifier: "zh_CN"), arguments: args)
    }
}
