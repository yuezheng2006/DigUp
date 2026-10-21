import Foundation

/// Resolve the complete message before inserting values, so translations can reorder them.
/// Values are never interpreted as format strings or as further placeholders.
nonisolated func L(_ key: String, _ values: Any...) -> String {
    Localization.render(Localization.bundle.localizedString(forKey: key, value: key, table: nil),
                        values: values.map { String(describing: $0) })
}

nonisolated enum Localization {
    // SwiftPM looks beside the executable; a packaged macOS app keeps resources in Contents/Resources.
    static let bundle: Bundle = {
        let packaged = Bundle.main.resourceURL?.appendingPathComponent("DigUp_DigUpApp.bundle")
        let resources = packaged.flatMap { Bundle(url: $0) } ?? Bundle.module
        // Resolve explicitly: an unbundled SwiftPM executable has no main-bundle localizations.
        let language = preferredLanguage(Locale.preferredLanguages)
        let directory = resources.localizations.first { $0.lowercased() == language.lowercased() } ?? "en"
        guard let path = resources.path(forResource: directory, ofType: "lproj"),
              let localized = Bundle(path: path) else { return resources }
        return localized
    }()

    static func preferredLanguage(_ languages: [String]) -> String {
        for language in languages {
            let tag = language.lowercased().replacingOccurrences(of: "_", with: "-")
            if tag == "zh" || tag.hasPrefix("zh-") { return "zh-Hans" }
            if tag == "en" || tag.hasPrefix("en-") { return "en" }
        }
        return "en"
    }

    static func render(_ template: String, values: [String]) -> String {
        let expression = try! NSRegularExpression(pattern: #"\{([0-9]+)\}"#)
        let source = template as NSString
        var output = "", offset = 0
        for match in expression.matches(in: template, range: NSRange(location: 0, length: source.length)) {
            output += source.substring(with: NSRange(location: offset, length: match.range.location - offset))
            let index = Int(source.substring(with: match.range(at: 1)))!
            output += values.indices.contains(index) ? values[index] : source.substring(with: match.range)
            offset = NSMaxRange(match.range)
        }
        return output + source.substring(from: offset)
    }
}
