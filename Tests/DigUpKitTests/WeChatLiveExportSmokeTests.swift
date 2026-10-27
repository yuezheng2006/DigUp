#if os(macOS)
import Foundation
import Testing
@testable import DigUpKit

/// Live smoke: exports a real 1:1 chat to verify HTML report artifacts.
@Suite struct WeChatLiveExportSmokeTests {
    @Test func exportHeJichengHTMLReport() throws {
        guard let wx = WeChatReaderLocation.detect() else {
            Issue.record("wx not installed"); return
        }
        let zone = TimeZone.current
        let session = WeChatSession(id: "wxid_1a1gwd3n68pq22", name: "何继成", chatType: "private")
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("digup-live-export-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let dest = root.appendingPathComponent(WeChatExportPlan.folderName(timeZone: zone))
        // Last ~7 days half-open
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let end = calendar.startOfDay(for: Date())
        let start = calendar.date(byAdding: .day, value: -6, to: end)!
        let until = calendar.date(byAdding: .day, value: 1, to: end)!
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = "yyyy-MM-dd"
        let since = formatter.string(from: start)
        let untilStr = formatter.string(from: until)
        let profiles = WeChatProfiles.load()
        let reader = WeChatReader(executable: wx)
        let report = try reader.exportConversation(
            session: session, to: dest, since: since, until: untilStr, timeZone: zone,
            displayName: { sender in
                let key = sender.trimmingCharacters(in: .whitespacesAndNewlines)
                if key.isEmpty { return session.name }
                return profiles.people[key]?.preferredName ?? key
            },
            selfUsername: profiles.selfID,
            selfAliases: profiles.selfAliases)

        let index = dest.appendingPathComponent("index.html")
        let stats = dest.appendingPathComponent("stats.html")
        let messagesJSON = dest.appendingPathComponent("messages.json")
        let corpus = dest.appendingPathComponent("corpus.jsonl")
        let text = dest.appendingPathComponent("messages.txt")
        for url in [index, stats, messagesJSON, corpus, text] {
            #expect(FileManager.default.fileExists(atPath: url.path), "missing \(url.lastPathComponent)")
        }
        let html = try String(contentsOf: index, encoding: .utf8)
        #expect(html.contains("class=\"top\""))
        #expect(html.contains("按日跳转") || html.contains("Jump by day"))
        #expect(html.contains("class=\"bubble\""))
        #expect(html.contains("class=\"me\""), "self bubbles should use nick/alias aliases")
        #expect(html.contains("class=\"them\""))
        #expect(html.contains("stats.html"))
        let statsHTML = try String(contentsOf: stats, encoding: .utf8)
        #expect(statsHTML.contains("按日活跃") || statsHTML.contains("Daily activity"))
        #expect(statsHTML.contains("class=\"bar\""))
        #expect(report.messages > 0)
        // Stable path for the agent to collect artifacts
        let out = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Documents/github/tmp-digup-export-smoke")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.copyItem(at: dest, to: out)
        print("LIVE_EXPORT_OK messages=\(report.messages) images=\(report.images) path=\(out.path)")
    }
}
#endif
