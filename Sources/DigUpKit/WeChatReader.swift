#if os(macOS)
import Foundation
import Darwin
import ImageIO
import UniformTypeIdentifiers

/// A deliberately small wx protocol adapter. No key acquisition, auto-discovery, or database writes.
public enum WeChatReadError: String, Error, Sendable {
    case executable, timeout, outputLimit, commandFailed, invalidResponse, invalidRange, changedSource
}

public struct WeChatSession: Identifiable, Sendable, Equatable {
    public enum Kind: String, Sendable { case group, person, official, other }
    public let id: String
    public let name: String
    public let kind: Kind
    public let lastMessageTimestamp: TimeInterval?
    public init(id: String, name: String, chatType: String? = nil, lastMessageTimestamp: TimeInterval? = nil) {
        self.id = id; self.name = name
        self.lastMessageTimestamp = lastMessageTimestamp.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        // Official accounts take precedence over unreliable group flags; display names are never classifiers.
        if id.hasPrefix("gh_") || chatType == "official_account" { kind = .official }
        else if id.hasSuffix("@chatroom") { kind = .group }
        else if chatType == "private" || id.hasPrefix("wxid_") { kind = .person }
        else { kind = .other }
    }
}

public struct WeChatMessage: Identifiable, Sendable, Equatable {
    public let id: String
    public let sender: String
    public let timestamp: Double
    public let content: String
    public let type: String
    /// Lossless source record, not an instruction to an agent.
    public let raw: Data
}

public struct WeChatExportResult: Sendable {
    public let messages: Int
    public let images: Int
    public let unavailableImages: Int
    public let stats: WeChatConversationStats
    public init(messages: Int, images: Int, unavailableImages: Int,
                stats: WeChatConversationStats = .empty) {
        self.messages = messages; self.images = images
        self.unavailableImages = unavailableImages; self.stats = stats
    }
}

/// Resolve WeChat 「文件」messages to the local download under `msg/file/YYYY-MM/`.
/// `wx attachments` only covers images; file bodies stay on disk beside `db_storage`.
public enum WeChatFileLocator {
    /// Filename from wx content like `[文件] uuid.txt (314 B, txt)` or DigUp plain `[文件 / File] …`.
    public static func parseFilename(from content: String) -> String? {
        var text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        var matched = false
        for prefix in ["[文件 / File]", "[文件]"] {
            if text.hasPrefix(prefix) {
                text = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                matched = true
                break
            }
        }
        guard matched, !text.isEmpty else { return nil }
        if let range = text.range(of: " (") {
            text = String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !text.isEmpty, !text.contains("/"), !text.contains("\\"),
              text != "." && text != "..", !text.hasPrefix("."),
              text.count <= 240 else { return nil }
        return text
    }

    /// Account root: parent of `db_dir` from `~/.wx-cli/config.json`.
    public static func accountRoot(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        let config = home.appendingPathComponent(".wx-cli/config.json")
        guard let data = try? Data(contentsOf: config),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let dbDir = object["db_dir"] as? String, !dbDir.isEmpty else { return nil }
        return URL(fileURLWithPath: dbDir).deletingLastPathComponent()
    }

    public static func monthKey(_ timestamp: Double, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM"
        return formatter.string(from: Date(timeIntervalSince1970: timestamp))
    }

    /// Prefer `msg/file/<message-month>/<name>`; else same name in nearby months by mtime.
    public static func resolve(
        content: String, timestamp: Double,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        timeZone: TimeZone = .current,
        fileManager: FileManager = .default
    ) -> URL? {
        guard let name = parseFilename(from: content),
              let root = accountRoot(home: home) else { return nil }
        let filesRoot = root.appendingPathComponent("msg/file", isDirectory: true)
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: filesRoot.path, isDirectory: &isDir), isDir.boolValue else { return nil }
        let preferred = filesRoot.appendingPathComponent(monthKey(timestamp, timeZone: timeZone), isDirectory: true)
            .appendingPathComponent(name)
        if fileManager.isReadableFile(atPath: preferred.path) { return preferred }

        let months = (try? fileManager.contentsOfDirectory(at: filesRoot,
            includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        var candidates: [(url: URL, distance: TimeInterval)] = []
        for month in months {
            var dir: ObjCBool = false
            guard fileManager.fileExists(atPath: month.path, isDirectory: &dir), dir.boolValue else { continue }
            let candidate = month.appendingPathComponent(name)
            guard fileManager.isReadableFile(atPath: candidate.path) else { continue }
            let mtime = (try? fileManager.attributesOfItem(atPath: candidate.path)[.modificationDate] as? Date)?
                .timeIntervalSince1970 ?? timestamp
            candidates.append((candidate, abs(mtime - timestamp)))
        }
        return candidates.min(by: { $0.distance < $1.distance })?.url
    }
}

/// AI / 语料友好的结构化导出（MemoTrace JSON 思路；Mac · wx · 不碰解密）。
public enum WeChatCorpusExport {
    public static let schema = "digup-wechat-export/1"

    public static func messageRecord(
        index: Int, timestamp: Double, datetime: String,
        sender: String, senderRaw: String, type: String,
        kind: WeChatExportFormatting.Kind, plain: String,
        content: String, imagePath: String?
    ) -> [String: Any] {
        var row: [String: Any] = [
            "id": index,
            "timestamp": timestamp,
            "datetime": datetime,
            "sender": sender,
            "sender_raw": senderRaw,
            "type": type,
            "kind": kind.rawValue,
            "text": plain,
            "content": content
        ]
        if let imagePath { row["image"] = imagePath }
        return row
    }

    /// One JSON object per line for fine-tune / RAG pipelines.
    public static func jsonlLine(from record: [String: Any], sessionName: String) throws -> Data {
        var line: [String: Any] = [
            "session": sessionName,
            "role": "message",
            "name": record["sender"] as? String ?? "",
            "content": record["text"] as? String ?? "",
            "kind": record["kind"] as? String ?? "other",
            "timestamp": record["timestamp"] as? Double ?? 0,
            "datetime": record["datetime"] as? String ?? ""
        ]
        if let image = record["image"] as? String { line["image"] = image }
        if let file = record["file"] as? String { line["file"] = file }
        var data = try JSONSerialization.data(withJSONObject: line, options: [.sortedKeys])
        data.append(contentsOf: "\n".utf8)
        return data
    }

    public static func document(
        session: WeChatSession, since: String?, until: String?,
        exportedAt: String, messages: [[String: Any]], stats: WeChatConversationStats
    ) -> [String: Any] {
        var statsJSON: [String: Any] = [
            "message_count": stats.messageCount,
            "active_days": stats.activeDays,
            "images_saved": stats.imagesSaved,
            "images_unavailable": stats.imagesUnavailable,
            "by_kind": stats.byKind,
            "top_senders": stats.topSenders.map { ["name": $0.name, "count": $0.count] as [String: Any] }
        ]
        if let first = stats.firstTimestamp { statsJSON["first_timestamp"] = first }
        if let last = stats.lastTimestamp { statsJSON["last_timestamp"] = last }
        return [
            "schema": schema,
            "platform": "macOS",
            "source": "wx",
            "exported_at": exportedAt,
            "session": [
                "id": session.id,
                "name": session.name,
                "kind": session.kind.rawValue
            ] as [String: Any],
            "range": [
                "since": since as Any,
                "until": until as Any
            ] as [String: Any],
            "stats": statsJSON,
            "messages": messages
        ]
    }
}

/// Lightweight range overview (MemoTrace-style summary; Mac / wx history only).
public struct WeChatConversationStats: Sendable, Equatable {
    public struct Sender: Sendable, Equatable {
        public let name: String
        public let count: Int
        public init(name: String, count: Int) { self.name = name; self.count = count }
    }

    public var messageCount: Int
    public var activeDays: Int
    public var firstTimestamp: Double?
    public var lastTimestamp: Double?
    public var byKind: [String: Int]
    /// `yyyy-MM-dd` → count, sorted chronologically when rendered.
    public var byDay: [String: Int]
    public var topSenders: [Sender]
    public var imagesSaved: Int
    public var imagesUnavailable: Int

    public static let empty = WeChatConversationStats(
        messageCount: 0, activeDays: 0, firstTimestamp: nil, lastTimestamp: nil,
        byKind: [:], byDay: [:], topSenders: [], imagesSaved: 0, imagesUnavailable: 0)

    public init(messageCount: Int, activeDays: Int, firstTimestamp: Double?, lastTimestamp: Double?,
                byKind: [String: Int], byDay: [String: Int] = [:], topSenders: [Sender],
                imagesSaved: Int, imagesUnavailable: Int) {
        self.messageCount = messageCount; self.activeDays = activeDays
        self.firstTimestamp = firstTimestamp; self.lastTimestamp = lastTimestamp
        self.byKind = byKind; self.byDay = byDay; self.topSenders = topSenders
        self.imagesSaved = imagesSaved; self.imagesUnavailable = imagesUnavailable
    }
}

public struct WeChatStatsBuilder: Sendable {
    private var byKind: [String: Int] = [:]
    private var byDay: [String: Int] = [:]
    private var senders: [String: Int] = [:]
    private var days = Set<String>()
    private var first: Double?
    private var last: Double?
    private var imagesSaved = 0
    private var imagesUnavailable = 0
    private let dayKey: DateFormatter

    public init(timeZone: TimeZone = .current) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        dayKey = formatter
    }

    public mutating func add(timestamp: Double, senderLabel: String, kind: WeChatExportFormatting.Kind) {
        guard timestamp.isFinite else { return }
        byKind[kind.rawValue, default: 0] += 1
        if kind != .system {
            let name = senderLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { senders[name, default: 0] += 1 }
        }
        let day = dayKey.string(from: Date(timeIntervalSince1970: timestamp))
        days.insert(day)
        byDay[day, default: 0] += 1
        if first == nil || timestamp < first! { first = timestamp }
        if last == nil || timestamp > last! { last = timestamp }
    }

    public mutating func noteImages(saved: Int, unavailable: Int) {
        imagesSaved = saved; imagesUnavailable = unavailable
    }

    public func finish(top: Int = 10) -> WeChatConversationStats {
        let ranked = senders.map { WeChatConversationStats.Sender(name: $0.key, count: $0.value) }
            .sorted { $0.count == $1.count ? $0.name < $1.name : $0.count > $1.count }
        return WeChatConversationStats(
            messageCount: byKind.values.reduce(0, +),
            activeDays: days.count,
            firstTimestamp: first,
            lastTimestamp: last,
            byKind: byKind,
            byDay: byDay,
            topSenders: Array(ranked.prefix(max(0, top))),
            imagesSaved: imagesSaved,
            imagesUnavailable: imagesUnavailable)
    }

    public static func from(messages: [WeChatMessage], timeZone: TimeZone = .current,
                            displayName: (String) -> String = { $0 }) -> WeChatConversationStats {
        var builder = WeChatStatsBuilder(timeZone: timeZone)
        for message in messages {
            let kind = WeChatExportFormatting.parts(type: message.type, content: message.content).kind
            builder.add(timestamp: message.timestamp, senderLabel: displayName(message.sender), kind: kind)
        }
        return builder.finish()
    }

    public static func htmlDocument(stats: WeChatConversationStats, title: String,
                                    timeZone: TimeZone = .current) -> String {
        let escape = WeChatExportFormatting.escape
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX"); stamp.timeZone = timeZone
        stamp.dateFormat = "yyyy-MM-dd HH:mm"
        func when(_ value: Double?) -> String {
            guard let value else { return "—" }
            return stamp.string(from: Date(timeIntervalSince1970: value))
        }
        let kindOrder = ["text", "image", "video", "voice", "sticker", "quote", "link", "file", "applet", "system", "other"]
        let kindLabels: [String: String] = [
            "text": "文本 / Text", "image": "图片 / Image", "video": "视频 / Video", "voice": "语音 / Voice",
            "sticker": "表情 / Sticker", "quote": "引用 / Quote", "link": "链接 / Link", "file": "文件 / File",
            "applet": "小程序 / Mini Program", "system": "系统 / System", "other": "其他 / Other"
        ]
        let maxKind = max(1, stats.byKind.values.max() ?? 1)
        var kindsHTML = ""
        var kindBars = ""
        for key in kindOrder where (stats.byKind[key] ?? 0) > 0 {
            let count = stats.byKind[key]!
            let pct = Int((Double(count) / Double(maxKind) * 100).rounded())
            kindsHTML += "<tr><td>\(escape(kindLabels[key] ?? key))</td><td>\(count)</td></tr>"
            kindBars += "<div class=\"bar-row\"><span>\(escape(kindLabels[key] ?? key))</span>"
                + "<div class=\"bar\"><i style=\"width:\(pct)%\"></i></div><b>\(count)</b></div>"
        }
        var sendersHTML = ""
        let maxSender = max(1, stats.topSenders.map(\.count).max() ?? 1)
        var senderBars = ""
        for (index, sender) in stats.topSenders.enumerated() {
            sendersHTML += "<tr><td>\(index + 1)</td><td>\(escape(sender.name))</td><td>\(sender.count)</td></tr>"
            let pct = Int((Double(sender.count) / Double(maxSender) * 100).rounded())
            senderBars += "<div class=\"bar-row\"><span>\(escape(sender.name))</span>"
                + "<div class=\"bar\"><i style=\"width:\(pct)%\"></i></div><b>\(sender.count)</b></div>"
        }
        if sendersHTML.isEmpty { sendersHTML = "<tr><td colspan=\"3\">—</td></tr>" }
        if kindsHTML.isEmpty { kindsHTML = "<tr><td colspan=\"2\">—</td></tr>" }
        let dayMax = max(1, stats.byDay.values.max() ?? 1)
        var daysHTML = ""
        for day in stats.byDay.keys.sorted() {
            let count = stats.byDay[day] ?? 0
            let pct = Int((Double(count) / Double(dayMax) * 100).rounded())
            daysHTML += "<tr><td><a href=\"index.html#day-\(day)\">\(escape(day))</a></td><td>\(count)</td>"
                + "<td><div class=\"bar mini\"><i style=\"width:\(pct)%\"></i></div></td></tr>"
        }
        if daysHTML.isEmpty { daysHTML = "<tr><td colspan=\"3\">—</td></tr>" }
        return """
        <!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width">\
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline';">\
        <title>\(escape(title)) · overview</title><style>\
        body{max-width:820px;margin:32px auto;padding:16px;font:16px/1.45 system-ui,-apple-system,sans-serif;color:#111}\
        h1{font-size:22px;margin:0 0 8px}h2{font-size:17px;margin:28px 0 10px}nav a{color:#06c}\
        .cards{display:flex;flex-wrap:wrap;gap:12px;margin:20px 0}\
        .card{flex:1 1 120px;padding:14px 16px;background:#f6f6f6;border-radius:10px}\
        .card b{display:block;font-size:22px;margin-top:4px}\
        .card span{color:#666;font-size:13px}\
        table{width:100%;border-collapse:collapse;margin:12px 0 24px}\
        th,td{text-align:left;padding:8px 10px;border-bottom:1px solid #e6e6e6}\
        th{color:#666;font-weight:600;font-size:13px}\
        .bar-row{display:grid;grid-template-columns:minmax(72px,140px) 1fr 40px;gap:8px;align-items:center;margin:6px 0}\
        .bar-row span{font-size:13px;color:#444;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}\
        .bar{height:10px;background:#eee;border-radius:999px;overflow:hidden}\
        .bar.mini{height:8px;min-width:80px}\
        .bar i{display:block;height:100%;background:linear-gradient(90deg,#5b9cff,#3a7bfd);border-radius:999px}\
        .bar-row b{font-size:13px;text-align:right;color:#333}\
        @media print{nav{display:none}.bar i{-webkit-print-color-adjust:exact;print-color-adjust:exact}}\
        </style>\
        <nav><a href="index.html">← 聊天记录 / Messages</a> · <a href="messages.json">messages.json</a> · <a href="corpus.jsonl">corpus.jsonl</a></nav>\
        <h1>\(escape(title))</h1>\
        <p style="color:#666">区间概览 / Range overview · \(escape(when(stats.firstTimestamp))) → \(escape(when(stats.lastTimestamp)))</p>\
        <div class="cards">\
        <div class="card"><span>消息 / Messages</span><b>\(stats.messageCount)</b></div>\
        <div class="card"><span>活跃日 / Active days</span><b>\(stats.activeDays)</b></div>\
        <div class="card"><span>图片已保存 / Images</span><b>\(stats.imagesSaved)</b></div>\
        <div class="card"><span>图片不可用 / Unavailable</span><b>\(stats.imagesUnavailable)</b></div>\
        </div>\
        <h2>类型分布 / Types</h2>\(kindBars.isEmpty ? "<p>—</p>" : kindBars)\
        <table><thead><tr><th>类型</th><th>条数</th></tr></thead><tbody>\(kindsHTML)</tbody></table>\
        <h2>发言 Top / Top senders</h2>\(senderBars.isEmpty ? "<p>—</p>" : senderBars)\
        <table><thead><tr><th>#</th><th>名称</th><th>条数</th></tr></thead><tbody>\(sendersHTML)</tbody></table>\
        <h2>按日活跃 / Daily activity</h2>\
        <table><thead><tr><th>日期</th><th>条数</th><th></th></tr></thead><tbody>\(daysHTML)</tbody></table>
        """
    }

    public static func indexFooter(stats: WeChatConversationStats) -> String {
        var footer = "<section class=\"overview\"><h2>区间概览</h2><ul>"
        footer += "<li>消息 \(stats.messageCount) · 活跃日 \(stats.activeDays)</li>"
        if let top = stats.topSenders.first {
            footer += "<li>最高频：\(WeChatExportFormatting.escape(top.name))（\(top.count)）</li>"
        }
        footer += "<li><a href=\"stats.html\">查看完整概览 / Full overview</a></li></ul></section>"
        return footer
    }
}

/// Stronger HTML chat report (day TOC, bubbles, sticky nav) — no JS; CSP-safe.
public enum WeChatHTMLReport {
    public static let style = """
        :root{--bg:#f3f5f8;--card:#fff;--me:#d8ecff;--them:#fff;--line:#e6e8ec;--muted:#667085;--text:#101828}\
        *{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--text);\
        font:15px/1.5 system-ui,-apple-system,sans-serif}\
        .top{position:sticky;top:0;z-index:5;backdrop-filter:saturate(1.2) blur(8px);\
        background:rgba(243,245,248,.92);border-bottom:1px solid var(--line);padding:10px 16px}\
        .top h1{font-size:17px;margin:0 0 4px}.top .nav{font-size:13px;color:var(--muted)}\
        .top a{color:#175cd3;text-decoration:none;margin-right:10px}\
        .wrap{max-width:860px;margin:0 auto;padding:16px}\
        details.toc{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:10px 14px;margin-bottom:16px}\
        details.toc summary{cursor:pointer;font-weight:600}\
        details.toc .days{display:flex;flex-wrap:wrap;gap:8px;margin-top:10px}\
        details.toc a{font-size:13px;color:#175cd3;background:#eff4ff;padding:4px 8px;border-radius:999px;text-decoration:none}\
        .day{margin:22px 0 8px;text-align:center}\
        .day span{display:inline-block;background:#e8edf5;color:var(--muted);font-size:12px;padding:4px 10px;border-radius:999px}\
        article{display:flex;flex-direction:column;margin:10px 0;max-width:78%}\
        article.me{margin-left:auto;align-items:flex-end}article.them{margin-right:auto;align-items:flex-start}\
        article.system{max-width:100%;align-items:center;margin:14px auto}\
        article header{font-size:12px;color:var(--muted);margin-bottom:4px}\
        .bubble{background:var(--them);border:1px solid var(--line);border-radius:14px;padding:10px 12px;\
        box-shadow:0 1px 0 rgba(16,24,40,.04);overflow-wrap:anywhere;white-space:pre-wrap}\
        article.me .bubble{background:var(--me);border-color:#b6d8f8}\
        article.system .bubble{background:transparent;border:0;box-shadow:none;color:var(--muted);font-size:13px;text-align:center;padding:0}\
        .quote{margin:0;border-left:3px solid #c5d0e0;padding:8px 10px;background:#f8fafc;border-radius:0 8px 8px 0}\
        .quote .quoted{color:#475467;font-size:13px;margin-bottom:6px}.quote .reply{color:var(--text)}\
        .media,.file,.applet,.link,.other{color:#344054}\
        img{max-width:100%;max-height:480px;margin-top:8px;border-radius:8px;display:block}\
        a{color:#175cd3;overflow-wrap:anywhere}\
        .overview{margin-top:28px;padding:16px;background:var(--card);border:1px solid var(--line);border-radius:12px;font-size:14px}\
        .overview ul{padding-left:18px}\
        @media print{.top{position:static;background:#fff}details.toc{display:none}\
        article{max-width:100%;break-inside:avoid}.bubble{box-shadow:none}}
        """

    public static func dayKey(_ timestamp: Double, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date(timeIntervalSince1970: timestamp))
    }

    public static func isSelf(senderRaw: String, selfUsername: String?,
                              selfAliases: Set<String> = []) -> Bool {
        let raw = senderRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return false }
        if let selfUsername, !selfUsername.isEmpty, raw == selfUsername { return true }
        return selfAliases.contains(raw)
    }
}

/// Pure helpers for export folder naming and half-open day bounds (testable without AppKit).
public enum WeChatExportPlan {
    public static func folderName(now: Date = Date(), id: String = UUID().uuidString,
                                  timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return "WeChat-" + formatter.string(from: now) + "-" + String(id.prefix(8))
    }

    /// `until` is exclusive (day after the selected end date). `nil` pair means the whole local history.
    public static func dayBounds(all: Bool, start: Date, end: Date, timeZone: TimeZone = .current,
                                 calendar: Calendar = .current) -> (since: String?, until: String?)? {
        if all { return (nil, nil) }
        var calendar = calendar
        calendar.timeZone = timeZone
        guard calendar.startOfDay(for: start) <= calendar.startOfDay(for: end) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        guard let untilDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: end)) else { return nil }
        return (formatter.string(from: start), formatter.string(from: untilDay))
    }
}

/// Rich-ish plain/HTML bodies for wx history rows (Mac / capability-first; inspired by MemoTrace coverage, not its decrypt path).
public enum WeChatExportFormatting {
    public enum Kind: String, Sendable, Equatable {
        case text, image, video, voice, sticker, quote, link, file, applet, system, other
    }

    public struct Parts: Sendable, Equatable {
        public let kind: Kind
        public let plain: String
        /// Safe HTML fragment: escaped text plus `a` / `blockquote` / `br` / `span` only.
        public let html: String
        public init(kind: Kind, plain: String, html: String) {
            self.kind = kind; self.plain = plain; self.html = html
        }
    }

    public static func escape(_ text: String) -> String {
        var out = String()
        out.reserveCapacity(text.utf8.count + 8)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    /// Autolink http(s) URLs inside already-plain text; returns escaped HTML with `<a>`.
    public static func linkifiedHTML(_ text: String) -> String {
        let pattern = #"https?://[^\s<>"')\]]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return escape(text) }
        let ns = text as NSString
        var result = ""
        var cursor = 0
        let full = NSRange(location: 0, length: ns.length)
        for match in regex.matches(in: text, range: full) {
            let before = NSRange(location: cursor, length: match.range.location - cursor)
            if before.length > 0 { result += escape(ns.substring(with: before)) }
            var url = ns.substring(with: match.range)
            var trailing = ""
            while let last = url.last, ",.;:!?）)".contains(last) {
                trailing = String(last) + trailing
                url.removeLast()
            }
            if url.isEmpty {
                result += escape(ns.substring(with: match.range))
            } else {
                result += "<a href=\"\(escape(url))\">\(escape(url))</a>" + escape(trailing)
            }
            cursor = match.range.location + match.range.length
        }
        if cursor < ns.length { result += escape(ns.substring(from: cursor)) }
        return result.isEmpty ? escape(text) : result
    }

    public static func parts(type: String, content: String) -> Parts {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch key {
        case "text", "文本", "1":
            return Parts(kind: .text, plain: trimmed, html: "<p>\(linkifiedHTML(trimmed))</p>")
        case "image", "图片", "3":
            return Parts(kind: .image, plain: "[图片 / Image]", html: "<p class=\"media\">[图片 / Image]</p>")
        case "video", "视频", "43":
            return Parts(kind: .video, plain: "[视频 / Video]", html: "<p class=\"media\">[视频 / Video]</p>")
        case "voice", "语音", "34":
            return Parts(kind: .voice, plain: "[语音 / Voice]", html: "<p class=\"media\">[语音 / Voice]</p>")
        case "sticker", "表情", "表情包", "47":
            return Parts(kind: .sticker, plain: "[表情 / Sticker]", html: "<p class=\"media\">[表情 / Sticker]</p>")
        case "call", "通话", "voip", "50":
            let detail = trimmed.replacingOccurrences(of: "[通话]", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let plain = detail.isEmpty ? "[通话 / Call]" : "[通话 / Call] \(detail)"
            return Parts(kind: .other, plain: plain, html: "<p class=\"other\">\(escape(plain))</p>")
        case "系统", "system", "10000", "10002":
            return systemParts(trimmed)
        case "链接/文件", "share", "app", "49":
            return shareParts(trimmed)
        default:
            if trimmed.hasPrefix("[引用]") { return quoteParts(trimmed) }
            if trimmed.hasPrefix("[文件]") { return fileParts(trimmed) }
            if trimmed.hasPrefix("[小程序]") { return appletParts(trimmed) }
            if trimmed.hasPrefix("[链接]") { return linkParts(trimmed) }
            if trimmed.hasPrefix("[系统]") { return systemParts(trimmed) }
            let plain = trimmed.isEmpty ? "[附件或其他消息 / Attachment or other message]" : trimmed
            return Parts(kind: .other, plain: plain, html: "<p class=\"other\">\(linkifiedHTML(plain))</p>")
        }
    }

    private static func quoteParts(_ content: String) -> Parts {
        let body = String(content.drop(while: { $0 != "]" }).dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
        // wx shape: "[引用] quoted…\n  ↳ Sender: reply"
        let marker = "\n  ↳ "
        if let range = body.range(of: marker) {
            let quoted = String(body[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            let reply = String(body[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            let plain = "[引用 / Quote]\n\(quoted)\n↳ \(reply)"
            let html = "<blockquote class=\"quote\"><div class=\"quoted\">\(linkifiedHTML(quoted))</div>"
                + "<div class=\"reply\">\(linkifiedHTML(reply))</div></blockquote>"
            return Parts(kind: .quote, plain: plain, html: html)
        }
        let plain = "[引用 / Quote] \(body)"
        return Parts(kind: .quote, plain: plain,
                     html: "<blockquote class=\"quote\">\(linkifiedHTML(body))</blockquote>")
    }

    private static func fileParts(_ content: String) -> Parts {
        let detail = content.replacingOccurrences(of: "[文件]", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        let plain = "[文件 / File] \(detail)"
        return Parts(kind: .file, plain: plain, html: "<p class=\"file\">\(escape(plain))</p>")
    }

    private static func appletParts(_ content: String) -> Parts {
        let detail = content.replacingOccurrences(of: "[小程序]", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        let plain = "[小程序 / Mini Program] \(detail)"
        return Parts(kind: .applet, plain: plain, html: "<p class=\"applet\">\(escape(plain))</p>")
    }

    private static func linkParts(_ content: String) -> Parts {
        let detail = content.replacingOccurrences(of: "[链接]", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        let plain = "[链接 / Link] \(detail)"
        return Parts(kind: .link, plain: plain, html: "<p class=\"link\">\(linkifiedHTML(plain))</p>")
    }

    private static func shareParts(_ content: String) -> Parts {
        if content.hasPrefix("[引用]") { return quoteParts(content) }
        if content.hasPrefix("[文件]") { return fileParts(content) }
        if content.hasPrefix("[小程序]") { return appletParts(content) }
        if content.hasPrefix("[链接]") { return linkParts(content) }
        let plain = content.isEmpty ? "[链接或文件 / Link or file]" : content
        return Parts(kind: .link, plain: plain, html: "<p class=\"link\">\(linkifiedHTML(plain))</p>")
    }

    private static func systemParts(_ content: String) -> Parts {
        // Drop embedded XML/sysmsg noise; keep a one-line human hint when possible.
        var line = content
        if let range = line.range(of: "<") { line = String(line[..<range.lowerBound]) }
        line = line
            .replacingOccurrences(of: "[系统]", with: "")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if line.hasSuffix(":") { line = String(line.dropLast()).trimmingCharacters(in: .whitespaces) }
        let plain = line.isEmpty ? "[系统消息 / System]" : "[系统 / System] \(line)"
        return Parts(kind: .system, plain: plain, html: "<p class=\"system\">\(escape(plain))</p>")
    }
}

public enum WeChatDatePreset: String, CaseIterable, Sendable {
    case week = "Last week", twoWeeks = "Last two weeks", month = "Last month", halfYear = "Last six months"
    public func start(through date: Date, calendar: Calendar = .current) -> Date {
        let end = calendar.startOfDay(for: date)
        switch self {
        case .week: return calendar.date(byAdding: .day, value: -6, to: end)!
        case .twoWeeks: return calendar.date(byAdding: .day, value: -13, to: end)!
        case .month: return calendar.date(byAdding: .month, value: -1, to: end)!
        case .halfYear: return calendar.date(byAdding: .month, value: -6, to: end)!
        }
    }
}

public struct WeChatReadResult: Sendable {
    public let messages: [WeChatMessage]
    public let truncated: Bool
    public let statuses: [String]
    public let queriedAt: Date
}

/// Run only the explicitly selected executable. Arguments are never passed through a shell.
/// Both pipes are drained without blocking; limits also apply to misbehaving helpers.
public enum WeChatProcess {
    public static func run(executable: String, arguments: [String], timeout: Double = 30,
                           maxBytes: Int = 8 * 1024 * 1024) throws -> Data {
        try Task<Never, Never>.checkCancellation()
        guard executable.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: executable) else {
            throw WeChatReadError.executable
        }
        let process = Process(), output = Pipe(), errors = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errors
        var environment = ProcessInfo.processInfo.environment
        // npm's wx entry uses /usr/bin/env node. Finder does not inherit a login shell's PATH.
        environment["PATH"] = URL(fileURLWithPath: executable).deletingLastPathComponent().path
            + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
        process.environment = environment
        do { try process.run() } catch { throw WeChatReadError.executable }
        try? output.fileHandleForWriting.close()
        try? errors.fileHandleForWriting.close()
        let handles = [output.fileHandleForReading, errors.fileHandleForReading]
        for handle in handles { _ = fcntl(handle.fileDescriptor, F_SETFL, O_NONBLOCK) }
        defer {
            if process.isRunning {
                process.terminate()
                let grace = ProcessInfo.processInfo.systemUptime + 0.2
                while process.isRunning && ProcessInfo.processInfo.systemUptime < grace { usleep(10_000) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            process.waitUntilExit()
            for handle in handles { try? handle.close() }
        }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var data = Data(), total = 0
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            try Task<Never, Never>.checkCancellation()
            var received = false
            for (index, handle) in handles.enumerated() {
                let count = Darwin.read(handle.fileDescriptor, &buffer, buffer.count)
                if count > 0 {
                    total += count
                    guard total <= maxBytes else { throw WeChatReadError.outputLimit }
                    if index == 0 { data.append(contentsOf: buffer.prefix(count)) }
                    received = true
                } else if count < 0 && errno != EAGAIN && errno != EINTR {
                    throw WeChatReadError.commandFailed
                }
            }
            if !process.isRunning && !received { break }
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw WeChatReadError.timeout }
            if !received { usleep(10_000) }
        }
        guard process.terminationStatus == 0 else { throw WeChatReadError.commandFailed }
        return data
    }
}

public struct WeChatReader: Sendable {
    public typealias Runner = @Sendable ([String]) throws -> Data
    private let run: Runner
    public init(executable: String) {
        run = { try WeChatProcess.run(executable: executable, arguments: $0) }
    }
    public init(run: @escaping Runner) { self.run = run }

    // wx 0.3 bare arrays and newer named wrappers. Unknown schemas must not look like empty history.
    private static func rows(_ data: Data, key: String, expectedUsername: String? = nil) throws -> ([[String: Any]], [String: Any]) {
        guard data.count <= 8 * 1024 * 1024,
              let value = try? JSONSerialization.jsonObject(with: data) else { throw WeChatReadError.invalidResponse }
        if let rows = value as? [[String: Any]] { return (rows, [:]) }
        guard let object = value as? [String: Any], object["error"] == nil,
              (object["success"] as? Bool) != false,
              let rows = object[key] as? [[String: Any]] else { throw WeChatReadError.invalidResponse }
        if let expectedUsername, let actual = object["username"] as? String, actual != expectedUsername {
            throw WeChatReadError.changedSource
        }
        return (rows, object["meta"] as? [String: Any] ?? [:])
    }

    /// WeChat inserts synthetic rows (brand/service holders, fold placeholders) that `wx history` cannot open.
    public static func isSyntheticSessionID(_ id: String) -> Bool {
        let key = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if key.isEmpty || key.hasPrefix("@placeholder") { return true }
        if key.contains("sessionholder") { return true }
        if key == "notifymessage" || key == "floatbottle" || key == "medianote" { return true }
        return false
    }

    public func sessions() throws -> [WeChatSession] {
        let (rows, _) = try Self.rows(run(["sessions", "--limit", "200", "--json", "--with-meta"]), key: "sessions")
        var seen = Set<String>()
        let sessions: [WeChatSession] = try rows.compactMap { row in
            guard let id = row["username"] as? String, !id.isEmpty, !id.hasPrefix("-"),
                  seen.insert(id).inserted else { throw WeChatReadError.invalidResponse }
            // Folded inboxes / synthetic holders are not readable chat identities.
            if row["chat_type"] as? String == "folded" { return nil }
            if Self.isSyntheticSessionID(id) { return nil }
            var name = row["chat"] as? String ?? row["display_name"] as? String ?? row["name"] as? String ?? row["display"] as? String ?? id
            name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            // Nameless group: keep readable via username, but avoid showing raw id as the only title.
            if name.isEmpty || name == id {
                if id.hasSuffix("@chatroom") {
                    let summary = (row["summary"] as? String)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    name = summary.isEmpty ? "未命名群聊" : String(summary.prefix(28))
                } else if id.hasSuffix("@openim") {
                    name = name.isEmpty || name == id ? "企业微信联系人" : name
                }
            }
            let stamp = row["timestamp"] as? NSNumber
            let session = WeChatSession(id: id, name: name.isEmpty ? id : name, chatType: row["chat_type"] as? String,
                                        lastMessageTimestamp: stamp.flatMap { CFGetTypeID($0) == CFBooleanGetTypeID() ? nil : $0.doubleValue })
            return session.kind == .official ? nil : session
        }
        // Latest message first, independent of the reader's order. Missing timestamps go last;
        // stable identity breaks ties so a refresh does not reshuffle equally recent conversations.
        return sessions.sorted {
            let lhs = $0.lastMessageTimestamp ?? 0, rhs = $1.lastMessageTimestamp ?? 0
            return lhs == rhs ? $0.id < $1.id : lhs > rhs
        }
    }

    /// Group/private roster for resolving history `sender` to WeChat-visible names.
    public func members(session: WeChatSession) throws -> [WeChatMember] {
        guard !session.id.isEmpty, !session.id.hasPrefix("-") else { throw WeChatReadError.invalidRange }
        let data = try run(["members", session.id, "--json"])
        guard data.count <= 8 * 1024 * 1024,
              let value = try? JSONSerialization.jsonObject(with: data) else { throw WeChatReadError.invalidResponse }
        let rows: [[String: Any]]
        if let list = value as? [[String: Any]] { rows = list }
        else if let object = value as? [String: Any], object["error"] == nil,
                let list = object["members"] as? [[String: Any]] { rows = list }
        else { throw WeChatReadError.invalidResponse }
        guard rows.count <= 2000 else { throw WeChatReadError.invalidResponse }
        var seen = Set<String>()
        return try rows.map { row in
            guard let username = row["username"] as? String, !username.isEmpty, !username.hasPrefix("-"),
                  seen.insert(username).inserted else { throw WeChatReadError.invalidResponse }
            return WeChatMember(
                username: username,
                contactDisplay: row["contact_display"] as? String ?? "",
                display: row["display"] as? String ?? "",
                groupNickname: row["group_nickname"] as? String ?? "")
        }
    }

    /// Fetch only the selected message's image, matching both timestamp and local identity.
    public func image(message: WeChatMessage, session: WeChatSession) throws -> Data {
        let raw = try JSONSerialization.jsonObject(with: message.raw) as? [String: Any]
        guard let localID = raw?["local_id"] else { throw WeChatReadError.invalidResponse }
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"; formatter.timeZone = .current
        let date = Date(timeIntervalSince1970: message.timestamp)
        let start = formatter.string(from: date)
        let end = formatter.string(from: Calendar.current.date(byAdding: .day, value: 1, to: date)!)
        var attachment: String?
        for offset in stride(from: 0, to: 1000, by: 200) {
            let (items, _) = try Self.rows(run(["attachments", session.id, "--kind", "image", "--since", start,
                "--until", end, "--limit", "200", "--offset", String(offset), "--json"]),
                key: "attachments", expectedUsername: session.id)
            attachment = items.first {
                String(describing: $0["local_id"] ?? "") == String(describing: localID)
                    && ($0["timestamp"] as? NSNumber)?.doubleValue == message.timestamp
            }?["attachment_id"] as? String
            if attachment != nil || items.count < 200 { break }
        }
        guard let attachment, !attachment.isEmpty, !attachment.hasPrefix("-") else { throw WeChatReadError.invalidResponse }
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: folder) }
        var file = folder.appendingPathComponent("image.bin")
        _ = try run(["extract", attachment, "--output", file.path, "--json"])
        func boundedData(_ url: URL) throws -> Data {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size > 0, size <= 20 * 1024 * 1024 else { throw WeChatReadError.outputLimit }
            return try Data(contentsOf: url)
        }
        let original = try boundedData(file)
        if original.starts(with: Data("wxgf".utf8)) {
            guard let ffmpeg = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
                .first(where: { fm.isExecutableFile(atPath: $0) }) else { throw WeChatReadError.executable }
            let probe = URL(fileURLWithPath: ffmpeg).deletingLastPathComponent().appendingPathComponent("ffprobe").path
            guard fm.isExecutableFile(atPath: probe) else { throw WeChatReadError.executable }
            // Some wxgf images put a grayscale plane before the color frame. Taking frame zero
            // unconditionally produces a valid but nearly white image, not the actual picture.
            let metadata = try WeChatProcess.run(executable: probe, arguments: ["-v", "error", "-f", "hevc",
                "-read_intervals", "%+#2", "-show_frames", "-show_entries", "frame=pix_fmt", "-of", "json", file.path])
            let frames = (try JSONSerialization.jsonObject(with: metadata) as? [String: Any])?["frames"] as? [[String: Any]] ?? []
            let candidates = Array(frames.prefix(2))
            let chosen = candidates.firstIndex { frame in
                guard let format = frame["pix_fmt"] as? String else { return false }
                return !format.hasPrefix("gray")
            } ?? 0
            let pattern = folder.appendingPathComponent("preview-%02d.png")
            _ = try WeChatProcess.run(executable: ffmpeg, arguments: ["-v", "error", "-f", "hevc", "-i", file.path,
                "-frames:v", String(chosen + 1), "-vf", "scale=1600:1600:force_original_aspect_ratio=decrease,format=rgba",
                "-fps_mode", "passthrough", pattern.path])
            file = folder.appendingPathComponent(String(format: "preview-%02d.png", chosen + 1))
        }
        return try boundedData(file)
    }

    /// Streams local messages and linked images to a private staging directory, publishing only on success.
    /// Dates are half-open; nil bounds mean all local history, independent of the reading-page cap.
    /// Writes are buffered; JPEG/PNG payloads are stored as-is (no decode→PNG round-trip).
    /// `progress` is invoked after each page with `(messages, images)` written so far.
    public func exportConversation(session: WeChatSession, to destination: URL, since: String? = nil,
                           until: String? = nil, timeZone: TimeZone = .current,
                           progress: (@Sendable (Int, Int) -> Void)? = nil,
                           displayName: (@Sendable (String) -> String)? = nil,
                           selfUsername: String? = nil,
                           selfAliases: Set<String> = []) throws -> WeChatExportResult {
        let start = since.flatMap { Self.date($0, timeZone: timeZone) }
        let end = until.flatMap { Self.date($0, timeZone: timeZone) }
        guard !session.id.isEmpty, !session.id.hasPrefix("-"),
              since == nil || start != nil, until == nil || end != nil,
              start == nil || end == nil || start! < end! else { throw WeChatReadError.invalidRange }
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw WeChatReadError.commandFailed }
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".digup-export-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: temporary) }
        let media = temporary.appendingPathComponent("images")
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let filesDir = temporary.appendingPathComponent("files")
        try FileManager.default.createDirectory(at: filesDir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        func file(_ name: String) throws -> FileHandle {
            let url = temporary.appendingPathComponent(name)
            guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw WeChatReadError.commandFailed }
            return try FileHandle(forWritingTo: url)
        }
        let output = try file("messages.txt"), jsonl = try file("corpus.jsonl")
        defer { try? output.close(); try? jsonl.close() }
        let escape = WeChatExportFormatting.escape
        let flushBytes = 64 * 1024
        var textBuf = Data(); textBuf.reserveCapacity(flushBytes)
        var jsonlBuf = Data(); jsonlBuf.reserveCapacity(flushBytes)
        var htmlBody = Data(); htmlBody.reserveCapacity(256 * 1024)
        func appendText(_ text: String) { textBuf.append(contentsOf: text.utf8) }
        func appendBody(_ text: String) { htmlBody.append(contentsOf: text.utf8) }
        func appendJSONL(_ data: Data) { jsonlBuf.append(data) }
        func flushBuffers(force: Bool = false) throws {
            if force || textBuf.count >= flushBytes {
                try output.write(contentsOf: textBuf); textBuf.removeAll(keepingCapacity: true)
            }
            if force || jsonlBuf.count >= flushBytes {
                try jsonl.write(contentsOf: jsonlBuf); jsonlBuf.removeAll(keepingCapacity: true)
            }
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        let exportedAt = formatter.string(from: Date())
        func page(_ offset: Int) throws -> [[String: Any]] {
            var args = ["history", session.id, "--limit", "200", "--offset", String(offset), "--with-meta", "--json"]
            if let since { args += ["--since", since] }
            if let until { args += ["--until", until] }
            let (items, meta) = try Self.rows(run(args), key: "messages", expectedUsername: session.id)
            guard items.count <= 200 else { throw WeChatReadError.invalidResponse }
            if let missing = meta["unknown_shards"] as? [Any], !missing.isEmpty { throw WeChatReadError.invalidResponse }
            return items
        }
        appendText(session.name + "\n\n")
        var offset = 0, count = 0, imageCount = 0, unavailable = 0, seen = Set<String>()
        var statsBuilder = WeChatStatsBuilder(timeZone: timeZone)
        var corpusRecords: [[String: Any]] = []
        var dayOrder: [String] = []
        var lastDay: String?
        var first: Data?
        while true {
            try Task<Never, Never>.checkCancellation()
            let items = try page(offset)
            if offset == 0 { first = try JSONSerialization.data(withJSONObject: items, options: [.sortedKeys]) }
            for row in items {
                if let owner = row["chat_username"] as? String, owner != session.id { throw WeChatReadError.changedSource }
                guard let stamp = row["timestamp"] as? NSNumber, CFGetTypeID(stamp) != CFBooleanGetTypeID(),
                      stamp.doubleValue.isFinite, let content = row["content"] as? String,
                      let id = row["local_id"], id is String || id is NSNumber else { throw WeChatReadError.invalidResponse }
                let timestamp = stamp.doubleValue
                guard seen.insert("\(id)@\(timestamp)").inserted else { throw WeChatReadError.changedSource }
                if let start, timestamp < start.timeIntervalSince1970 { continue }
                if let end, timestamp >= end.timeIntervalSince1970 { continue }
                let type = row["type"] as? String ?? "unknown"
                let senderRaw = row["sender"] as? String ?? ""
                let sender = displayName?(senderRaw) ?? senderRaw
                let when = formatter.string(from: Date(timeIntervalSince1970: timestamp))
                var rendered = WeChatExportFormatting.parts(type: type, content: content)
                var imagePath: String?
                var filePath: String?
                if rendered.kind == .image {
                    do {
                        let raw = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
                        let message = WeChatMessage(id: "\(id)@\(timestamp)", sender: senderRaw, timestamp: timestamp, content: content, type: type, raw: raw)
                        let data = try image(message: message, session: session)
                        try Task<Never, Never>.checkCancellation()
                        let path = try Self.writeExportImage(data, index: count + 1, into: temporary)
                        imagePath = path; imageCount += 1
                        rendered = WeChatExportFormatting.Parts(
                            kind: .image, plain: "[图片 / Image: \(path)]",
                            html: "<p class=\"media\">[图片 / Image]</p>")
                    } catch is CancellationError { throw CancellationError() }
                    catch {
                        try Task<Never, Never>.checkCancellation()
                        for ext in ["png", "jpg", "jpeg"] {
                            let failed = temporary.appendingPathComponent("images/message-\(count + 1).\(ext)")
                            if FileManager.default.fileExists(atPath: failed.path) { try FileManager.default.removeItem(at: failed) }
                        }
                        unavailable += 1
                        rendered = WeChatExportFormatting.Parts(
                            kind: .image, plain: "[图片不可用 / Image unavailable]",
                            html: "<p class=\"media\">[图片不可用 / Image unavailable]</p>")
                    }
                } else if rendered.kind == .file {
                    if let local = WeChatFileLocator.resolve(content: content, timestamp: timestamp, timeZone: timeZone),
                       let name = WeChatFileLocator.parseFilename(from: content) {
                        let destName = "message-\(count + 1)-\(name)"
                        let dest = filesDir.appendingPathComponent(destName)
                        do {
                            if FileManager.default.fileExists(atPath: dest.path) {
                                try FileManager.default.removeItem(at: dest)
                            }
                            try FileManager.default.copyItem(at: local, to: dest)
                            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dest.path)
                            filePath = "files/\(destName)"
                            rendered = WeChatExportFormatting.Parts(
                                kind: .file,
                                plain: "[文件 / File] \(name) → \(filePath!)",
                                html: "<p class=\"file\"><a href=\"\(escape(filePath!))\">\(escape(name))</a></p>")
                        } catch {
                            rendered = WeChatExportFormatting.Parts(
                                kind: .file,
                                plain: "[文件 / File] \(name)（本机有缓存但复制失败 / copy failed）",
                                html: "<p class=\"file\">\(escape(name))</p>")
                        }
                    } else if let name = WeChatFileLocator.parseFilename(from: content) {
                        rendered = WeChatExportFormatting.Parts(
                            kind: .file,
                            plain: "[文件 / File] \(name)（本机未找到已下载文件 / not downloaded locally）",
                            html: "<p class=\"file\">\(escape(name)) · 未找到本地文件</p>")
                    }
                }
                statsBuilder.add(timestamp: timestamp, senderLabel: sender, kind: rendered.kind)
                let heading = rendered.kind == .system ? when : "\(when)  \(sender)"
                appendText("\(heading)\n\(rendered.plain)\n\n")
                let day = WeChatHTMLReport.dayKey(timestamp, timeZone: timeZone)
                if day != lastDay {
                    lastDay = day
                    dayOrder.append(day)
                    appendBody("<div class=\"day\" id=\"day-\(day)\"><span>\(escape(day))</span></div>\n")
                }
                let role: String
                if rendered.kind == .system { role = "system" }
                else if WeChatHTMLReport.isSelf(senderRaw: senderRaw, selfUsername: selfUsername,
                                               selfAliases: selfAliases) { role = "me" }
                else { role = "them" }
                appendBody("<article id=\"message-\(count + 1)\" class=\"\(role)\"><header>" + escape(heading) + "</header>")
                appendBody("<div class=\"bubble\">")
                appendBody(rendered.html)
                if let imagePath {
                    appendBody("<a href=\"\(imagePath)\"><img loading=\"lazy\" src=\"\(imagePath)\" alt=\"图片 / Image\"></a>")
                }
                appendBody("</div></article>\n")
                var record = WeChatCorpusExport.messageRecord(
                    index: count + 1, timestamp: timestamp, datetime: when,
                    sender: sender, senderRaw: senderRaw, type: type,
                    kind: rendered.kind, plain: rendered.plain,
                    content: content, imagePath: imagePath)
                if let filePath { record["file"] = filePath }
                corpusRecords.append(record)
                appendJSONL(try WeChatCorpusExport.jsonlLine(from: record, sessionName: session.name))
                count += 1
            }
            try flushBuffers()
            progress?(count, imageCount)
            if items.count < 200 { break }
            offset += items.count
        }
        // Detect a moving pagination head rather than silently delivering a partial export.
        guard try JSONSerialization.data(withJSONObject: page(0), options: [.sortedKeys]) == first else {
            throw WeChatReadError.changedSource
        }
        try Task<Never, Never>.checkCancellation()
        statsBuilder.noteImages(saved: imageCount, unavailable: unavailable)
        let stats = statsBuilder.finish()
        appendBody(WeChatStatsBuilder.indexFooter(stats: stats))
        appendText("\n---\n区间概览：\(stats.messageCount) 条消息，\(stats.activeDays) 个活跃日\n")
        if let top = stats.topSenders.first {
            appendText("最高频发言：\(top.name)（\(top.count)）\n")
        }
        appendText("结构化语料：messages.json · corpus.jsonl\n")
        try flushBuffers(force: true)
        try output.synchronize()
        try output.close()
        try jsonl.synchronize(); try jsonl.close()

        var tocLinks = ""
        for day in dayOrder {
            tocLinks += "<a href=\"#day-\(day)\">\(escape(day))</a>"
        }
        let toc = dayOrder.isEmpty ? "" : """
        <details class="toc" open><summary>按日跳转 / Jump by day（\(dayOrder.count)）</summary>\
        <div class="days">\(tocLinks)</div></details>
        """
        var indexHTML = Data()
        indexHTML.append(contentsOf: """
        <!doctype html><html lang="zh-Hans"><meta charset="utf-8"><meta name="viewport" content="width=device-width">\
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src 'self' data:; style-src 'unsafe-inline';">\
        <title>\(escape(session.name))</title><style>\(WeChatHTMLReport.style)</style>\
        <div class="top"><h1>\(escape(session.name))</h1>\
        <div class="nav"><a href="stats.html">区间概览</a><a href="messages.json">messages.json</a>\
        <a href="corpus.jsonl">corpus.jsonl</a><span>\(stats.messageCount) 条 · \(stats.activeDays) 天</span></div></div>\
        <div class="wrap">\(toc)
        """.utf8)
        indexHTML.append(htmlBody)
        indexHTML.append(contentsOf: "</div>".utf8)
        let indexURL = temporary.appendingPathComponent("index.html")
        try indexHTML.write(to: indexURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: indexURL.path)

        let statsURL = temporary.appendingPathComponent("stats.html")
        try WeChatStatsBuilder.htmlDocument(stats: stats, title: session.name, timeZone: timeZone)
            .write(to: statsURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: statsURL.path)
        let messagesJSON = temporary.appendingPathComponent("messages.json")
        let document = WeChatCorpusExport.document(
            session: session, since: since, until: until,
            exportedAt: exportedAt, messages: corpusRecords, stats: stats)
        let jsonData = try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
        try jsonData.write(to: messagesJSON, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: messagesJSON.path)
        // A new directory only: never overwrite an existing export or user folder.
        try FileManager.default.moveItem(at: temporary, to: destination)
        return WeChatExportResult(messages: count, images: imageCount, unavailableImages: unavailable, stats: stats)
    }

    /// Prefer original JPEG/PNG bytes; fall back to PNG re-encode only when the container is unfamiliar.
    static func writeExportImage(_ data: Data, index: Int, into temporary: URL) throws -> String {
        let images = temporary.appendingPathComponent("images")
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        let pngMagic = Data([0x89, 0x50, 0x4E, 0x47])
        let jpegMagic = Data([0xFF, 0xD8, 0xFF])
        func store(_ name: String, _ bytes: Data) throws -> String {
            let path = "images/\(name)"
            let url = temporary.appendingPathComponent(path)
            try bytes.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return path
        }
        if data.starts(with: pngMagic) { return try store("message-\(index).png", data) }
        if data.starts(with: jpegMagic) { return try store("message-\(index).jpg", data) }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw WeChatReadError.invalidResponse }
        let path = "images/message-\(index).png"
        let url = temporary.appendingPathComponent(path)
        guard let encoder = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw WeChatReadError.commandFailed
        }
        CGImageDestinationAddImage(encoder, decoded, nil)
        guard CGImageDestinationFinalize(encoder) else { throw WeChatReadError.commandFailed }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return path
    }

    public static func date(_ value: String, timeZone: TimeZone) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard value.count == 10, let date = formatter.date(from: value), formatter.string(from: date) == value else { return nil }
        return date
    }

    /// Pages needed so a ~1 month window rarely hits the soft cap (wx page ≤ 200).
    public static func historyPageBudget(since: Date, until: Date, pageSize: Int = 200) -> (pageSize: Int, maxPages: Int) {
        let size = min(200, max(1, pageSize))
        let days = max(1, Calendar.current.dateComponents([.day], from: since, to: until).day ?? 1)
        // ~1 month → allow up to ~6000 rows; short ranges stay small and fast.
        let pages = min(30, max(5, (days * 40 + size - 1) / size))
        return (size, pages)
    }

    /// Read a bounded, half-open local date range. No persistent cursor: every request is explicit.
    public func history(session: WeChatSession, since: String, until: String, timeZone: TimeZone = .current,
                        pageSize: Int = 200, maxPages: Int? = nil) throws -> WeChatReadResult {
        guard let start = Self.date(since, timeZone: timeZone), let end = Self.date(until, timeZone: timeZone),
              end > start,
              !session.id.isEmpty, !session.id.hasPrefix("-") else { throw WeChatReadError.invalidRange }
        let budget = Self.historyPageBudget(since: start, until: end, pageSize: pageSize)
        let pageSize = budget.pageSize
        let maxPages = min(30, max(1, maxPages ?? budget.maxPages))
        guard (1...200).contains(pageSize), (1...30).contains(maxPages) else { throw WeChatReadError.invalidRange }
        func page(_ offset: Int) throws -> ([[String: Any]], [String: Any]) {
            try Self.rows(run(["history", session.id, "--since", since, "--until", until,
                               "--limit", String(pageSize), "--offset", String(offset), "--with-meta", "--json"]), key: "messages", expectedUsername: session.id)
        }
        var messages: [String: WeChatMessage] = [:], statuses = Set<String>()
        var first: Data?, fingerprints = Set<Data>(), truncated = true
        for index in 0..<maxPages {
            let (rows, meta) = try page(index * pageSize)
            guard rows.count <= pageSize else { throw WeChatReadError.invalidResponse }
            if let missing = meta["unknown_shards"] as? [Any], !missing.isEmpty { statuses.insert("unknown_shards") }
            if let status = meta["status"] as? String { statuses.insert(status) }
            else { statuses.insert("unknown") }
            let fingerprint = try JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys])
            if index == 0 { first = fingerprint }
            if !rows.isEmpty, !fingerprints.insert(fingerprint).inserted { throw WeChatReadError.changedSource }
            for row in rows {
                if let owner = row["chat_username"] as? String, owner != session.id { throw WeChatReadError.changedSource }
                guard let stamp = row["timestamp"] as? NSNumber,
                      CFGetTypeID(stamp) != CFBooleanGetTypeID(), stamp.doubleValue.isFinite,
                      let content = row["content"] as? String,
                      let localID = row["local_id"], localID is String || localID is NSNumber else {
                    throw WeChatReadError.invalidResponse
                }
                let timestamp = stamp.doubleValue
                let sender = row["sender"] as? String ?? ""
                let type = row["type"] as? String ?? "unknown"
                let id = "\(localID)@\(timestamp)"
                let raw = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
                let message = WeChatMessage(id: id, sender: sender, timestamp: timestamp, content: content, type: type, raw: raw)
                if let old = messages[id], old != message { throw WeChatReadError.changedSource }
                if timestamp >= start.timeIntervalSince1970 && timestamp < end.timeIntervalSince1970 {
                    messages[id] = message
                }
            }
            if rows.count < pageSize { truncated = false; break }
        }
        // Offset pagination has no snapshot token. Detect a changed head, but do not claim transactional consistency.
        let (again, _) = try page(0)
        guard try JSONSerialization.data(withJSONObject: again, options: [.sortedKeys]) == first else {
            throw WeChatReadError.changedSource
        }
        let sorted = messages.values.sorted { ($0.timestamp, $0.id) < ($1.timestamp, $1.id) }
        return WeChatReadResult(messages: sorted, truncated: truncated, statuses: statuses.sorted(), queriedAt: Date())
    }
}
#endif
