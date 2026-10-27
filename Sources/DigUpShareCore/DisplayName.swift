import Foundation

public enum DisplayName {
    public static let fallbackBaseName = "共享文件"
    private static let forbidden = CharacterSet(charactersIn: "/:\0")

    public static func sanitize(_ raw: String?, fallbackExtension: String? = nil) -> String {
        var name = (raw as NSString?)?.lastPathComponent ?? ""
        name = String(name.unicodeScalars.map { scalar -> Character in
            if forbidden.contains(scalar) { return "-" }
            if scalar.properties.generalCategory == .control { return " " }
            return Character(scalar)
        })
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name == "." || name == ".." || name.hasPrefix(".") {
            name = fallbackBaseName + name
        }
        if (name as NSString).pathExtension.isEmpty,
           let fallbackExtension, !fallbackExtension.isEmpty {
            name = "\(name).\(fallbackExtension)"
        }
        return truncate(name)
    }

    static func truncate(_ name: String, limit: Int = 200) -> String {
        guard name.utf8.count > limit else { return name }
        let ext = (name as NSString).pathExtension
        let suffix = ext.isEmpty ? "" : ".\(ext)"
        var base = (name as NSString).deletingPathExtension
        let budget = max(1, limit - suffix.utf8.count)
        while base.utf8.count > budget, !base.isEmpty { base.removeLast() }
        if base.isEmpty { base = fallbackBaseName }
        return base + suffix
    }
}
