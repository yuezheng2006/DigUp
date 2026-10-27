#if os(macOS)
import Foundation
import Testing
@testable import DigUpKit

@Suite struct WeChatExportTests {
    let zone = TimeZone(secondsFromGMT: 8 * 3600)!
    let session = WeChatSession(id: "synthetic@chatroom", name: "验收群聊 (模拟)")

    func row(_ id: Int, _ stamp: Double, content: String = "群聊测试：中文检索",
             type: String = "text", sender: String = "模拟发送者") -> [String: Any] {
        ["local_id": id, "timestamp": stamp, "sender": sender, "type": type, "content": content,
         "chat_username": session.id]
    }

    func payload(_ messages: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "username": session.id,
            "messages": messages,
            "meta": ["status": "fixture"]
        ] as [String: Any], options: [.sortedKeys])
    }

    func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("digup-export-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    @Test func folderNameUsesDayAndShortId() {
        let name = WeChatExportPlan.folderName(
            now: WeChatReader.date("2026-10-26", timeZone: zone)!,
            id: "abcdef12-9999-4000-8000-000000000000",
            timeZone: zone)
        #expect(name == "WeChat-2026-10-26-abcdef12")
    }

    @Test func statsBuilderCountsDaysTypesAndTopSenders() {
        var builder = WeChatStatsBuilder(timeZone: zone)
        let day1 = WeChatReader.date("2026-10-20", timeZone: zone)!.timeIntervalSince1970 + 3600
        let day2 = WeChatReader.date("2026-10-21", timeZone: zone)!.timeIntervalSince1970 + 7200
        builder.add(timestamp: day1, senderLabel: "甲", kind: .text)
        builder.add(timestamp: day1 + 10, senderLabel: "甲", kind: .image)
        builder.add(timestamp: day2, senderLabel: "乙", kind: .text)
        builder.add(timestamp: day2 + 1, senderLabel: "", kind: .system)
        builder.noteImages(saved: 1, unavailable: 0)
        let stats = builder.finish(top: 5)
        #expect(stats.messageCount == 4)
        #expect(stats.activeDays == 2)
        #expect(stats.byKind["text"] == 2 && stats.byKind["image"] == 1 && stats.byKind["system"] == 1)
        #expect(stats.byDay["2026-10-20"] == 2 && stats.byDay["2026-10-21"] == 2)
        #expect(stats.topSenders.map(\.name) == ["甲", "乙"])
        #expect(stats.topSenders[0].count == 2)
        let html = WeChatStatsBuilder.htmlDocument(stats: stats, title: "验收群聊", timeZone: zone)
        #expect(html.contains("Active days") || html.contains("活跃日"))
        #expect(html.contains("甲") && html.contains("发言"))
        #expect(html.contains("Daily activity") || html.contains("按日活跃"))
        #expect(html.contains("index.html#day-2026-10-20"))
        #expect(html.contains("class=\"bar\""))
    }

    @Test func formattingMapsWxShareTypesAndQuotes() {
        let quote = WeChatExportFormatting.parts(
            type: "链接/文件",
            content: "[引用] 原话内容\n  ↳ Jacky: 回复正文")
        #expect(quote.kind == .quote)
        #expect(quote.plain.contains("原话内容") && quote.plain.contains("Jacky"))
        #expect(quote.html.contains("<blockquote") && quote.html.contains("reply"))

        let file = WeChatExportFormatting.parts(type: "链接/文件", content: "[文件] 说明.docx (1.2 MB, docx)")
        #expect(file.kind == .file && file.plain.contains("说明.docx"))

        let link = WeChatExportFormatting.parts(type: "链接/文件", content: "[链接] 当前版本不支持展示该内容")
        #expect(link.kind == .link)

        let applet = WeChatExportFormatting.parts(type: "链接/文件", content: "[小程序] 快递信息")
        #expect(applet.kind == .applet)

        let system = WeChatExportFormatting.parts(
            type: "系统",
            content: "[系统] room@chatroom:\n<sysmsg type=\"sysmsgtemplate\">noise</sysmsg>")
        #expect(system.kind == .system)
        #expect(!system.plain.contains("<sysmsg"))
        #expect(system.html.contains("class=\"system\""))

        let text = WeChatExportFormatting.parts(type: "文本", content: "见 https://example.com/a 谢谢")
        #expect(text.kind == .text)
        #expect(text.html.contains("<a href=\"https://example.com/a\">"))
        #expect(WeChatExportFormatting.escape("<&>") == "&lt;&amp;&gt;")
    }

    @Test func dayBoundsAreHalfOpenAndRejectInvertedRange() {
        let start = WeChatReader.date("2026-10-20", timeZone: zone)!
        let end = WeChatReader.date("2026-10-26", timeZone: zone)!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let bounds = WeChatExportPlan.dayBounds(all: false, start: start, end: end, timeZone: zone, calendar: calendar)
        #expect(bounds?.since == "2026-10-20")
        #expect(bounds?.until == "2026-10-27")
        #expect(WeChatExportPlan.dayBounds(all: true, start: start, end: end, timeZone: zone, calendar: calendar)! == (nil, nil))
        #expect(WeChatExportPlan.dayBounds(all: false, start: end, end: start, timeZone: zone, calendar: calendar) == nil)
    }

    @Test func datePresetsSpanInclusiveCalendarDays() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let through = WeChatReader.date("2026-10-26", timeZone: zone)!
        #expect(calendar.startOfDay(for: WeChatDatePreset.week.start(through: through, calendar: calendar))
                == WeChatReader.date("2026-10-20", timeZone: zone)!)
        #expect(calendar.startOfDay(for: WeChatDatePreset.twoWeeks.start(through: through, calendar: calendar))
                == WeChatReader.date("2026-10-13", timeZone: zone)!)
    }

    @Test func exportWritesTextHtmlAndRejectsExistingDestination() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let stamp = WeChatReader.date("2026-10-20", timeZone: zone)!.timeIntervalSince1970 + 3600
        let page = try payload([row(1, stamp), row(2, stamp + 1, content: "第二条", type: "voice")])
        let reader = WeChatReader { args in
            #expect(args[0] == "history")
            #expect(args[1] == session.id)
            #expect(args.contains("--since") && args.contains("2026-10-20"))
            #expect(args.contains("--until") && args.contains("2026-10-21"))
            return page
        }
        let dest = root.appendingPathComponent("out")
        let report = try reader.exportConversation(
            session: session, to: dest, since: "2026-10-20", until: "2026-10-21", timeZone: zone)
        #expect(report.messages == 2)
        #expect(report.images == 0)
        #expect(report.unavailableImages == 0)
        let text = try String(contentsOf: dest.appendingPathComponent("messages.txt"), encoding: .utf8)
        #expect(text.contains("验收群聊 (模拟)"))
        #expect(text.contains("群聊测试：中文检索"))
        #expect(text.contains("[语音 / Voice]"))
        let html = try String(contentsOf: dest.appendingPathComponent("index.html"), encoding: .utf8)
        #expect(html.contains("message-1") && html.contains("群聊测试：中文检索"))
        #expect(html.contains("class=\"media\"") || html.contains("[语音"))
        #expect(throws: WeChatReadError.commandFailed) {
            try reader.exportConversation(session: session, to: dest, since: "2026-10-20", until: "2026-10-21", timeZone: zone)
        }
    }

    @Test func exportRendersQuotesAndSystemWithoutRawXml() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let stamp = WeChatReader.date("2026-10-20", timeZone: zone)!.timeIntervalSince1970 + 100
        let page = try payload([
            row(1, stamp, content: "[引用] 问一句\n  ↳ 模拟发送者: 答一句", type: "链接/文件"),
            row(2, stamp + 1, content: "[系统] room:\n<sysmsg>x</sysmsg>", type: "系统", sender: ""),
            row(3, stamp + 2, content: "看 https://example.org/x", type: "文本")
        ])
        let reader = WeChatReader { _ in page }
        let dest = root.appendingPathComponent("rich")
        let report = try reader.exportConversation(
            session: session, to: dest, since: "2026-10-20", until: "2026-10-21", timeZone: zone)
        #expect(report.messages == 3)
        let text = try String(contentsOf: dest.appendingPathComponent("messages.txt"), encoding: .utf8)
        #expect(text.contains("问一句") && text.contains("答一句"))
        #expect(text.contains("[系统") && !text.contains("<sysmsg"))
        let html = try String(contentsOf: dest.appendingPathComponent("index.html"), encoding: .utf8)
        #expect(html.contains("<blockquote") && html.contains("class=\"quote\""))
        #expect(html.contains("class=\"system\""))
        #expect(html.contains("<a href=\"https://example.org/x\">"))
        #expect(!html.contains("<sysmsg"))
        #expect(html.contains("id=\"day-2026-10-20\""))
        #expect(html.contains("按日跳转") || html.contains("Jump by day"))
        #expect(html.contains("class=\"bubble\"") && html.contains("class=\"them\""))
        #expect(html.contains("class=\"top\"") && html.contains("position:sticky"))
        let statsHTML = try String(contentsOf: dest.appendingPathComponent("stats.html"), encoding: .utf8)
        #expect(statsHTML.contains("区间概览") || statsHTML.contains("Range overview"))
        #expect(FileManager.default.fileExists(atPath: dest.appendingPathComponent("stats.html").path))
        #expect(html.contains("stats.html") && html.contains("class=\"overview\""))
        #expect(html.contains("messages.json") && html.contains("corpus.jsonl"))
        let messagesJSON = try Data(contentsOf: dest.appendingPathComponent("messages.json"))
        let parsed = try JSONSerialization.jsonObject(with: messagesJSON) as? [String: Any]
        #expect(parsed?["schema"] as? String == WeChatCorpusExport.schema)
        let messages = parsed?["messages"] as? [[String: Any]]
        #expect(messages?.count == 3)
        #expect(messages?.contains { ($0["kind"] as? String) == "quote" } == true)
        let jsonl = try String(contentsOf: dest.appendingPathComponent("corpus.jsonl"), encoding: .utf8)
        let lines = jsonl.split(separator: "\n", omittingEmptySubsequences: true)
        #expect(lines.count == 3)
        #expect(lines[0].contains("\"role\":\"message\"") || lines[0].contains("\"role\" : \"message\""))
    }

    @Test func corpusHelpersStableShape() throws {
        let record = WeChatCorpusExport.messageRecord(
            index: 1, timestamp: 1_700_000_000, datetime: "2026-10-20 12:00:00 +0800",
            sender: "甲", senderRaw: "wxid_a", type: "文本", kind: .text,
            plain: "你好", content: "你好", imagePath: nil)
        #expect(record["sender"] as? String == "甲")
        #expect(record["kind"] as? String == "text")
        let line = try WeChatCorpusExport.jsonlLine(from: record, sessionName: "测")
        let obj = try JSONSerialization.jsonObject(with: line) as? [String: Any]
        #expect(obj?["session"] as? String == "测")
        #expect(obj?["content"] as? String == "你好")
        let doc = WeChatCorpusExport.document(
            session: session, since: "2026-10-20", until: "2026-10-21",
            exportedAt: "now", messages: [record], stats: .empty)
        #expect(doc["schema"] as? String == WeChatCorpusExport.schema)
        #expect((doc["session"] as? [String: Any])?["id"] as? String == session.id)
    }

    @Test func exportFiltersHalfOpenBoundsAndLeavesNoPartialOnInvalidRange() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let start = WeChatReader.date("2026-10-20", timeZone: zone)!.timeIntervalSince1970
        let page = try payload([
            row(1, start - 1, content: "before"),
            row(2, start, content: "on start"),
            row(3, start + 86_400, content: "on until")
        ])
        let reader = WeChatReader { _ in page }
        let dest = root.appendingPathComponent("range")
        let report = try reader.exportConversation(
            session: session, to: dest, since: "2026-10-20", until: "2026-10-21", timeZone: zone)
        #expect(report.messages == 1)
        let text = try String(contentsOf: dest.appendingPathComponent("messages.txt"), encoding: .utf8)
        #expect(text.contains("on start"))
        #expect(!text.contains("before") && !text.contains("on until"))
        #expect(throws: WeChatReadError.invalidRange) {
            try reader.exportConversation(session: session, to: root.appendingPathComponent("bad"),
                                          since: "2026-10-21", until: "2026-10-20", timeZone: zone)
        }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("bad").path))
    }

    @Test func exportMarksUnavailableImagesWithoutAborting() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let stamp = WeChatReader.date("2026-10-20", timeZone: zone)!.timeIntervalSince1970 + 10
        let page = try payload([row(1, stamp, content: "[图片]", type: "image")])
        let reader = WeChatReader { args in
            if args[0] == "history" { return page }
            // attachments / extract fail closed → unavailable image label
            return Data(#"{"username":"synthetic@chatroom","attachments":[]}"#.utf8)
        }
        let dest = root.appendingPathComponent("images")
        let report = try reader.exportConversation(
            session: session, to: dest, since: "2026-10-20", until: "2026-10-21", timeZone: zone)
        #expect(report.messages == 1)
        #expect(report.images == 0)
        #expect(report.unavailableImages == 1)
        let text = try String(contentsOf: dest.appendingPathComponent("messages.txt"), encoding: .utf8)
        #expect(text.contains("Image unavailable") || text.contains("图片不可用"))
    }

    @Test func exportDetectsChangedPaginationHead() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let stamp = WeChatReader.date("2026-10-20", timeZone: zone)!.timeIntervalSince1970 + 5
        final class Pages: @unchecked Sendable {
            private let lock = NSLock()
            private var n = 0
            let first: Data
            let second: Data
            init(first: Data, second: Data) { self.first = first; self.second = second }
            func next() -> Data {
                lock.lock(); defer { lock.unlock() }
                defer { n += 1 }
                return n == 0 ? first : second
            }
        }
        let first = try payload([row(1, stamp)])
        let second = try payload([row(2, stamp + 1)])
        let pages = Pages(first: first, second: second)
        let reader = WeChatReader { _ in pages.next() }
        #expect(throws: WeChatReadError.changedSource) {
            try reader.exportConversation(
                session: session, to: root.appendingPathComponent("moved"),
                since: "2026-10-20", until: "2026-10-21", timeZone: zone)
        }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("moved").path))
    }

    @Test func exportCancellationLeavesNoPublishedFolder() async throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let dest = root.appendingPathComponent("cancel-me")
        let reader = WeChatReader { _ in
            while true {
                try Task<Never, Never>.checkCancellation()
                Thread.sleep(forTimeInterval: 0.02)
            }
        }
        let work = Task.detached {
            try reader.exportConversation(
                session: self.session, to: dest, since: "2026-10-20", until: "2026-10-21", timeZone: self.zone)
        }
        try await Task.sleep(for: .milliseconds(80))
        work.cancel()
        do {
            _ = try await work.value
            Issue.record("Expected CancellationError")
        } catch is CancellationError {
            // ok
        }
        #expect(!FileManager.default.fileExists(atPath: dest.path))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(!leftovers.contains { $0.hasPrefix(".digup-export-") })
    }

    final class Box<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: T
        init(_ value: T) { self.value = value }
        func withLock<R>(_ body: (inout T) throws -> R) rethrows -> R {
            lock.lock(); defer { lock.unlock() }
            return try body(&value)
        }
    }

    @Test func exportLargeTextConversationIsFastAndBoundedInReaderCalls() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let stamp = WeChatReader.date("2026-10-20", timeZone: zone)!.timeIntervalSince1970
        let state = Box<(calls: Int, first: Data?)>((0, nil))
        let ticks = Box<[(Int, Int)]>([])
        let total = 2000
        let reader = WeChatReader { args in
            #expect(args[0] == "history")
            let offset = Int(args[args.firstIndex(of: "--offset")! + 1])!
            return try state.withLock { s in
                // Integrity re-read of offset 0 after pages have been fetched.
                if offset == 0, let first = s.first, s.calls > 0 { return first }
                if offset >= total { return try self.payload([]) }
                let rows = (0..<200).map { i in
                    self.row(offset + i, stamp + Double(offset + i), content: "msg-\(offset + i)")
                }
                let page = try self.payload(rows)
                s.calls += 1
                if s.first == nil { s.first = page }
                return page
            }
        }
        let dest = root.appendingPathComponent("large")
        let started = ContinuousClock.now
        let report = try reader.exportConversation(
            session: session, to: dest, since: "2026-10-20", until: "2026-10-21", timeZone: zone,
            progress: { messages, images in ticks.withLock { $0.append((messages, images)) } })
        let elapsed = ContinuousClock.now - started
        #expect(report.messages == total)
        #expect(report.images == 0)
        let callCount = state.withLock { $0.calls }
        #expect(callCount <= 12)
        let progress = ticks.withLock { $0 }
        #expect(progress.count >= 10)
        #expect(progress.last?.0 == total)
        #expect(elapsed < .seconds(3))
        let text = try String(contentsOf: dest.appendingPathComponent("messages.txt"), encoding: .utf8)
        #expect(text.contains("msg-0") && text.contains("msg-1999"))
    }

    @Test func writeExportImagePassesJPEGThroughWithoutReencode() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        var jpeg = Data([0xFF, 0xD8, 0xFF, 0xD9])
        jpeg.append(contentsOf: [UInt8](repeating: 0x11, count: 64))
        let path = try WeChatReader.writeExportImage(jpeg, index: 7, into: root)
        #expect(path == "images/message-7.jpg")
        #expect(try Data(contentsOf: root.appendingPathComponent(path)) == jpeg)

        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) + Data(repeating: 0x22, count: 32)
        let pngPath = try WeChatReader.writeExportImage(png, index: 8, into: root)
        #expect(pngPath == "images/message-8.png")
        #expect(try Data(contentsOf: root.appendingPathComponent(pngPath)) == png)
    }

    @Test func exportProgressReportsAfterEachPage() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let stamp = WeChatReader.date("2026-10-20", timeZone: zone)!.timeIntervalSince1970
        let pages = Box<(first: Data?, ticks: [Int])>((nil, []))
        let reader = WeChatReader { args in
            let offset = Int(args[args.firstIndex(of: "--offset")! + 1])!
            return try pages.withLock { s in
                if offset == 0, let first = s.first { return first }
                if offset >= 400 { return try self.payload([]) }
                let rows = (0..<200).map { i in self.row(offset + i, stamp + Double(offset + i)) }
                let page = try self.payload(rows)
                if offset == 0 { s.first = page }
                return page
            }
        }
        let report = try reader.exportConversation(
            session: session, to: root.appendingPathComponent("prog"),
            since: "2026-10-20", until: "2026-10-21", timeZone: zone,
            progress: { messages, _ in pages.withLock { $0.ticks.append(messages) } })
        #expect(report.messages == 400)
        let ticks = pages.withLock { $0.ticks }
        #expect(ticks.first == 200)
        #expect(ticks.contains(400))
    }
}
#endif
