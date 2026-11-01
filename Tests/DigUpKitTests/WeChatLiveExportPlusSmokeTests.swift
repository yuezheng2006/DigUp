#if os(macOS)
import Foundation
import Testing
@testable import DigUpKit

/// Live smoke for DigUp Plus export: OCR + HTML search + incremental + avatars.
@Suite struct WeChatLiveExportPlusSmokeTests {
    @Test func exportOCRSearchAndIncrementalFlow() throws {
        guard let wx = WeChatReaderLocation.detect() else {
            Issue.record("wx not installed"); return
        }
        let zone = TimeZone.current
        let session = WeChatSession(id: "wxid_1a1gwd3n68pq22", name: "何继成", chatType: "private")
        let suite = "digup-live-export-plus-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("digup-live-export-plus-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let end = calendar.startOfDay(for: Date())
        // Short window to keep OCR CPU bounded.
        let start = calendar.date(byAdding: .day, value: -2, to: end)!
        let until = calendar.date(byAdding: .day, value: 1, to: end)!
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = "yyyy-MM-dd"
        let since = formatter.string(from: start)
        let untilStr = formatter.string(from: until)

        let profiles = WeChatProfiles.load()
        let names = WeChatNameDirectory.build(members: [], profiles: profiles)
        let reader = WeChatReader(executable: wx)
        let dest1 = root.appendingPathComponent("pass1")
        let report1 = try reader.exportConversation(
            session: session, to: dest1, since: since, until: untilStr, timeZone: zone,
            displayName: { sender in
                let key = sender.trimmingCharacters(in: .whitespacesAndNewlines)
                if key.isEmpty { return session.name }
                return profiles.people[key]?.preferredName ?? names.displayName(for: key)
            },
            selfUsername: profiles.selfID,
            selfAliases: profiles.selfAliases,
            recognizeImageText: true,
            avatarURL: { sender in
                let key = sender.trimmingCharacters(in: .whitespacesAndNewlines)
                if key.isEmpty { return profiles.people[session.id]?.avatar }
                return names.avatarURL(for: key, in: profiles)
                    ?? profiles.people[key]?.avatar
                    ?? profiles.people[session.id]?.avatar
            })

        #expect(report1.messages > 0)
        let html = try String(contentsOf: dest1.appendingPathComponent("index.html"), encoding: .utf8)
        #expect(html.contains("id=\"q\""))
        #expect(html.contains("script-src 'unsafe-inline'"))
        #expect(html.contains("placeholder=\"搜索\"") || html.contains("id=\"q\""))
        #expect(html.contains("class=\"me\"") && html.contains("class=\"them\""))
        #expect(html.contains("class=\"avatar\""), "message rows should render avatar slots")
        let avatarCount = (try? FileManager.default.contentsOfDirectory(
            atPath: dest1.appendingPathComponent("avatars").path))?.count ?? 0
        if profiles.people[session.id]?.avatar != nil
            || profiles.selfID.flatMap({ profiles.people[$0]?.avatar }) != nil {
            #expect(avatarCount >= 1 || html.contains("avatar blank"))
        }

        let corpus = try String(contentsOf: dest1.appendingPathComponent("corpus.jsonl"), encoding: .utf8)
        let ocrInCorpus = corpus.contains("\"ocr\"")
        if report1.ocrImages > 0 {
            #expect(ocrInCorpus)
            #expect(html.contains("class=\"ocr\"") || html.contains("<pre class=\"ocr\""))
        }

        guard let watermark = report1.lastTimestamp else {
            Issue.record("missing lastTimestamp"); return
        }
        WeChatExportCursor.setLastTimestamp(watermark, for: session.id, defaults: defaults)
        #expect(WeChatExportCursor.lastTimestamp(for: session.id, defaults: defaults) == watermark)

        // Incremental pass: same range + watermark at newest → expect 0 new messages.
        let dest2 = root.appendingPathComponent("pass2")
        let report2 = try reader.exportConversation(
            session: session, to: dest2, since: since, until: untilStr, timeZone: zone,
            displayName: { sender in
                let key = sender.trimmingCharacters(in: .whitespacesAndNewlines)
                if key.isEmpty { return session.name }
                return profiles.people[key]?.preferredName ?? key
            },
            selfUsername: profiles.selfID,
            selfAliases: profiles.selfAliases,
            recognizeImageText: false,
            afterTimestamp: watermark)
        #expect(report2.messages == 0)

        let out = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Documents/github/tmp-digup-export-plus-smoke")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.copyItem(at: dest1, to: out)
        print("LIVE_EXPORT_PLUS_OK messages=\(report1.messages) images=\(report1.images) ocr=\(report1.ocrImages) avatars=\(avatarCount) watermark=\(watermark) path=\(out.path)")
    }
}
#endif
