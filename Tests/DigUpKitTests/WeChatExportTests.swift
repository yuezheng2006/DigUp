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
        #expect(throws: WeChatReadError.commandFailed) {
            try reader.exportConversation(session: session, to: dest, since: "2026-10-20", until: "2026-10-21", timeZone: zone)
        }
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
