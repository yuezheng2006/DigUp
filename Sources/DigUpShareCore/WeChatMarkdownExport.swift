import Foundation

/// Markdown note from WeChat merge-forward transcript + relative media links.
/// Drop the folder into Obsidian as-is (links match extracted archive paths).
public enum WeChatMarkdownExport {
    public static let fileName = "聊天记录.md"

    public static func render(
        title: String,
        records: [WeChatTranscriptRecord],
        body: String,
        mediaRelativePaths: [String] = [],
        exportedAt: Date = Date()
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
                lines += ["", "**\(escape(record.sender))** \(time.string(from: record.date))", ""]
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
            lines += ["", "## 其他附件", ""]
            lines += unused.map { "- [\(escape(($0 as NSString).lastPathComponent))](\($0))" }
        }

        return lines.joined(separator: "\n") + "\n"
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
