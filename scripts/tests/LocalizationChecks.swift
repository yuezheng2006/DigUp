// Compile with Localization.swift; no model or private files are needed.
import Foundation

extension Bundle {
    static let module = Bundle(path: CommandLine.arguments[1])!
}

@main
struct LocalizationChecks {
    static func main() throws {
        let root = CommandLine.arguments[1]
        let enURL = URL(fileURLWithPath: root).appendingPathComponent("en.lproj/Localizable.strings")
        let zhURL = URL(fileURLWithPath: root).appendingPathComponent("zh-Hans.lproj/Localizable.strings")
        func messages(_ url: URL) throws -> [String: String] {
            try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as! [String: String]
        }
        let english = try messages(enURL), chinese = try messages(zhURL)
        precondition(Set(english.keys) == Set(chinese.keys), "Catalog keys differ")
        let regex = try NSRegularExpression(pattern: #"\{[0-9]+\}"#)
        func placeholders(_ text: String) -> [String] {
            let source = text as NSString
            return regex.matches(in: text, range: NSRange(location: 0, length: source.length))
                .map { source.substring(with: $0.range) }.sorted()
        }
        for (key, value) in chinese {
            precondition(!value.isEmpty, "Empty translation: \(key)")
            precondition(placeholders(key) == placeholders(value), "Invalid placeholders: \(key)")
        }
        precondition(Localization.render("{1} 中的 {0}", values: ["预算.pdf", "文稿"]) == "文稿 中的 预算.pdf")
        precondition(Localization.render("{0}: {1}", values: ["{1}", "100% 中文"]) == "{1}: 100% 中文")
        precondition(Localization.render("{0} {9}", values: ["文件"]) == "文件 {9}")
        precondition(L("not in the catalog") == "not in the catalog")
        if let expected = CommandLine.arguments.first(where: { $0.hasPrefix("--expect=") }) {
            let chinese = expected == "--expect=zh-Hans"
            precondition(L("Search") == (chinese ? "搜索" : "Search"), "Language selection failed: \(L("Search"))")
            precondition(L("{0} results", 3) == (chinese ? "3 个结果" : "3 results"))
        }
        print("Localization checks passed (\(english.count) messages)")
    }
}
