import Foundation

/// Markdown note from WeChat merge-forward transcript + relative media links.
/// Drop the folder into Obsidian as-is (links match extracted archive paths).
public enum WeChatMarkdownExport {
    public static let fileName = "聊天记录.md"

    public enum Flavor: String, Sendable {
        /// Plain Markdown folder (Downloads / any folder).
        case markdown
        /// Obsidian vault note: tags + cssclass for theming.
        case obsidian
    }

    public static func render(
        title: String,
        records: [WeChatTranscriptRecord],
        body: String,
        mediaRelativePaths: [String] = [],
        exportedAt: Date = Date(),
        flavor: Flavor = .markdown
    ) -> String {
        let day = DateFormatter()
        let time = DateFormatter()
        let stamp = DateFormatter()
        for formatter in [day, time, stamp] {
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = Locale(identifier: "en_US_POSIX")
        }
        day.dateFormat = "yyyy-MM-dd"
        time.dateFormat = "HH:mm"
        stamp.dateFormat = "yyyy-MM-dd HH:mm"

        var lines: [String] = [
            "---",
            "title: \(yamlQuote(title))",
            "source: WeChat",
            "chat: \(yamlQuote(title))",
            "messages: \(records.isEmpty ? 0 : records.count)",
            "exported: \(stamp.string(from: exportedAt))",
            "generator: DigUp Plus",
        ]
        if flavor == .obsidian {
            lines += [
                "tags:",
                "  - wechat",
                "  - digup-plus",
                "cssclasses:",
                "  - digup-wechat",
            ]
        }
        lines += [
            "---",
            "",
            "# \(escape(title))",
        ]

        if records.isEmpty {
            lines += ["", "## 原始记录", ""]
            lines += body.split(separator: "\n", omittingEmptySubsequences: false).map { "    " + $0 }
        } else {
            var currentDay = ""
            for record in records {
                let messageDay = day.string(from: record.date)
                if messageDay != currentDay {
                    currentDay = messageDay
                    lines += ["", "## \(messageDay)"]
                }
                lines += ["", "### \(escape(record.sender)) · \(time.string(from: record.date))", ""]
                for line in record.text.components(separatedBy: "\n") {
                    lines.append(linkify(line, media: mediaRelativePaths))
                }
            }
        }

        let unused = mediaRelativePaths.filter { path in
            !body.contains((path as NSString).lastPathComponent) &&
            !records.contains { $0.text.contains((path as NSString).lastPathComponent) }
        }
        if !unused.isEmpty {
            lines += ["", "## 附件", ""]
            lines += unused.map { "- [\(escape(($0 as NSString).lastPathComponent))](\($0))" }
        }

        return lines.joined(separator: "\n") + "\n"
    }

    /// Extract ZIPs and write one Markdown note under `destination` (created).
    @discardableResult
    public static func writeBundle(
        zipURLs: [URL],
        to destination: URL,
        flavor: Flavor,
        fileManager: FileManager = .default
    ) throws -> (markdownURL: URL, recordCount: Int, mediaCount: Int) {
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        var allRecords: [WeChatTranscriptRecord] = []
        var title = "微信转发合集"
        var media: [String] = []
        for (index, zip) in zipURLs.enumerated() {
            let data = try Data(contentsOf: zip, options: .mappedIfSafe)
            let extract = destination.appendingPathComponent("batch-\(index + 1)", isDirectory: true)
            try fileManager.createDirectory(at: extract, withIntermediateDirectories: true)
            let names = try WeChatForwardZIP.extract(data, to: extract)
            media += names.filter { !$0.lowercased().hasSuffix(".txt") }.map { "batch-\(index + 1)/\($0)" }
            if let transcript = try WeChatForwardZIP.transcript(data) {
                if index == 0 {
                    title = (transcript.path as NSString).deletingPathExtension
                }
                allRecords += transcript.records ?? []
            }
        }
        let md = render(
            title: title,
            records: allRecords,
            body: "",
            mediaRelativePaths: media,
            flavor: flavor
        )
        let mdURL = destination.appendingPathComponent(fileName)
        try md.write(to: mdURL, atomically: true, encoding: .utf8)
        return (mdURL, allRecords.count, media.count)
    }

    private static func linkify(_ line: String, media: [String]) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let byName = Dictionary(grouping: media, by: { ($0 as NSString).lastPathComponent })
        var reference = trimmed
        if trimmed.hasPrefix("["), let close = trimmed.firstIndex(of: "]") {
            let rest = trimmed[trimmed.index(after: close)...].drop { $0 == " " || $0 == "\t" }
            if !rest.isEmpty { reference = String(rest) }
        }
        if media.contains(reference) {
            return mediaLink(reference)
        }
        let base = (reference as NSString).lastPathComponent
        if let candidates = byName[base], candidates.count == 1 {
            return mediaLink(candidates[0])
        }
        return escape(line)
    }

    private static func mediaLink(_ path: String) -> String {
        let name = (path as NSString).lastPathComponent
        let ext = (name as NSString).pathExtension.lowercased()
        let embed = ["jpg", "jpeg", "png", "gif", "webp", "heic", "mp4", "mov", "m4v"].contains(ext)
        let label = escape(name).replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
        return (embed ? "!" : "") + "[\(label)](\(path))"
    }

    private static func escape(_ line: String) -> String {
        line.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "<", with: "\\<")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "`", with: "\\`")
    }

    private static func yamlQuote(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
