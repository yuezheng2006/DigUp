#if os(macOS)
import Foundation
import Testing
@testable import DigUpKit

@Suite struct WeChatReaderTests {
    @Test func locatesReaderWithoutReadingAccountData() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("wx")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        #expect(WeChatReaderLocation.detect(home: root, path: root.path) == file.path)
    }

    let zone = TimeZone(secondsFromGMT: 8 * 3600)!
    let session = WeChatSession(id: "synthetic@chatroom", name: "Synthetic")
    // All content and identities here are synthetic. No installed reader is called.
    func row(_ id: Int, _ stamp: Double = 1_792_339_200, content: String = "中文 English 🙂") -> [String: Any] {
        ["local_id": id, "timestamp": stamp, "sender": "Synthetic sender", "type": "text", "content": content]
    }
    func data(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) }

    @Test func sessionsAcceptBothSchemasAndKeepDistinctIdentities() throws {
        let rows = [["username": "a", "chat": "Same"], ["username": "b", "chat": "Same"]]
        for input in [try data(rows), try data(["sessions": rows, "meta": ["status": "possibly_stale"]])] {
            let reader = WeChatReader { args in
                #expect(args == ["sessions", "--limit", "200", "--json", "--with-meta"])
                return input
            }
            #expect(try reader.sessions().map(\.id) == ["a", "b"])
            #expect(try reader.sessions().map(\.name) == ["Same", "Same"])
        }
    }
    @Test func malformedIsNotEmpty() throws {
        for text in ["{}", "null", "not json", "{\"sessions\": [{}]}", "{\"error\":\"private\",\"sessions\":[]}"] {
            let input = Data(text.utf8)
            #expect(throws: WeChatReadError.invalidResponse) { try WeChatReader { _ in input }.sessions() }
        }
    }
    @Test func dateValidationAndNoQueryOnBadRange() throws {
        #expect(WeChatReader.date("2026-02-30", timeZone: zone) == nil)
        #expect(WeChatReader.date("2026-1-01", timeZone: zone) == nil)
        let reader = WeChatReader { _ in Issue.record("Must not call reader"); return Data() }
        #expect(throws: WeChatReadError.invalidRange) {
            try reader.history(session: session, since: "2026-10-21", until: "2026-10-20", timeZone: zone)
        }
    }
    @Test func newestPageFirstIsReturnedChronologicallyAndOriginalPreserved() throws {
        let start = WeChatReader.date("2026-10-20", timeZone: zone)!.timeIntervalSince1970
        let newest = try data(["messages": [row(3, start + 3), row(4, start + 4)], "meta": ["status": "possibly_stale"]])
        let older = try data([row(1, start + 1), row(2, start + 2)])
        let reader = WeChatReader { args in
            #expect(args[0] == "history" && args[1] == "synthetic@chatroom")
            let offset = args[args.firstIndex(of: "--offset")! + 1]
            return offset == "0" ? newest : offset == "2" ? older : Data("[]".utf8)
        }
        let result = try reader.history(session: session, since: "2026-10-20", until: "2026-10-21", timeZone: zone, pageSize: 2)
        #expect(result.messages.map(\.timestamp) == [start + 1, start + 2, start + 3, start + 4])
        #expect(result.messages.first?.content == "中文 English 🙂")
        #expect(result.messages.first?.raw == (try data(row(1, start + 1))))
        #expect(!result.truncated)
        #expect(result.statuses.contains("possibly_stale"))
    }
    @Test func boundaryFilteringAndMediaRemainUninterpreted() throws {
        let start = WeChatReader.date("2026-10-20", timeZone: zone)!.timeIntervalSince1970
        var media = row(2, start, content: "[语音]"); media["type"] = "voice"
        let input = try data([row(1, start - 1), media, row(3, start + 86400)])
        let result = try WeChatReader { _ in input }.history(session: session, since: "2026-10-20", until: "2026-10-21", timeZone: zone)
        #expect(result.messages.count == 1)
        #expect(result.messages[0].type == "voice")
        #expect(result.messages[0].content == "[语音]")
    }
    @Test func duplicatePagesFailAndLimitIsExplicit() throws {
        let input = try data([row(1)])
        let reader = WeChatReader { _ in input }
        #expect(throws: WeChatReadError.changedSource) {
            try reader.history(session: session, since: "2026-10-20", until: "2026-10-21", timeZone: zone, pageSize: 1)
        }
        #expect(try reader.history(session: session, since: "2026-10-20", until: "2026-10-21", timeZone: zone, pageSize: 1, maxPages: 1).truncated)
    }
    @Test func wrongChatAndMalformedMessagesFailClosed() throws {
        var wrong = row(1); wrong["chat_username"] = "another@chatroom"
        for (object, expected) in [(wrong, WeChatReadError.changedSource), (["content": "missing identity"], .invalidResponse)] {
            let input = try data([object])
            #expect(throws: expected) {
                try WeChatReader { _ in input }.history(session: session, since: "2026-10-20", until: "2026-10-21", timeZone: zone)
            }
        }
    }
    @Test func changedHeadRejectsPreviouslyReadMessages() throws {
        final class Replies: @unchecked Sendable {
            private let lock = NSLock()
            private var index = 0
            let values: [Data]
            init(_ values: [Data]) { self.values = values }
            func next() -> Data {
                lock.lock(); defer { lock.unlock() }
                defer { index += 1 }
                return values[min(index, values.count - 1)]
            }
        }
        let replies = Replies([try data([row(1)]), try data([row(2)])])
        #expect(throws: WeChatReadError.changedSource) {
            try WeChatReader { _ in replies.next() }.history(session: session, since: "2026-10-20", until: "2026-10-21", timeZone: zone)
        }
    }
    @Test func oversizedAndDuplicateSessionsAreRejected() throws {
        let input = try data([["username": "a"], ["username": "a"]])
        #expect(throws: WeChatReadError.invalidResponse) { try WeChatReader { _ in input }.sessions() }
        let huge = Data(repeating: 32, count: 8 * 1024 * 1024 + 1)
        #expect(throws: WeChatReadError.invalidResponse) { try WeChatReader { _ in huge }.sessions() }
    }
    @Test func wrongResolvedConversationFailsEvenForEmptyResponse() throws {
        let input = try data(["username": "another@chatroom", "messages": []] as [String: Any])
        #expect(throws: WeChatReadError.changedSource) {
            try WeChatReader { _ in input }.history(session: session, since: "2026-10-20", until: "2026-10-21", timeZone: zone)
        }
    }
    @Test func emptyHistoryIsUnknownFreshness() throws {
        let result = try WeChatReader { _ in Data("[]".utf8) }.history(session: session, since: "2026-10-20", until: "2026-10-21", timeZone: zone)
        #expect(result.messages.isEmpty && !result.truncated)
        #expect(result.statuses == ["unknown"])
    }
    @Test func processDrainsBothPipesAndReturnsOnlyStdout() throws {
        let data = try WeChatProcess.run(executable: "/bin/sh", arguments: ["-c", "printf '[]'; printf 'private diagnostic' >&2"])
        #expect(String(decoding: data, as: UTF8.self) == "[]")
        #expect(throws: WeChatReadError.commandFailed) {
            try WeChatProcess.run(executable: "/bin/sh", arguments: ["-c", "printf 'private' >&2; exit 1"])
        }
    }
    @Test func cancellationStopsOnlyTheRunningChild() async throws {
        let work = Task.detached {
            try WeChatProcess.run(executable: "/bin/sh", arguments: ["-c", "while :; do :; done"], timeout: 10)
        }
        try await Task.sleep(for: .milliseconds(50))
        work.cancel()
        do {
            _ = try await work.value
            Issue.record("Cancelled read should fail")
        } catch is CancellationError {
            // Expected; run() reaps its child before returning.
        }
    }
    @Test func executableToReaderIntegration() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let executable = folder.appendingPathComponent("synthetic reader")
        let script = """
        #!/bin/sh
        case "$1" in
        sessions) printf '%s' '{"sessions":[{"username":"synthetic@chatroom","chat":"Synthetic"}]}';;
        history) printf '%s' '{"username":"synthetic@chatroom","messages":[],"meta":{"status":"possibly_stale"}}';;
        *) exit 1;;
        esac
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let reader = WeChatReader(executable: executable.path)
        let found = try reader.sessions()
        #expect(found == [session])
        let result = try reader.history(session: found[0], since: "2026-10-20", until: "2026-10-21", timeZone: zone)
        #expect(result.messages.isEmpty)
        #expect(result.statuses == ["possibly_stale"])
    }
    @Test func groupAndIndividualWithSameNameStayIsolated() throws {
        let timestamp = WeChatReader.date("2026-10-20", timeZone: zone)!.timeIntervalSince1970 + 60
        let reader = WeChatReader { args in
            if args[0] == "sessions" {
                return Data(#"{"sessions":[{"username":"group@chatroom","chat":"Same"},{"username":"wxid_person","chat":"Same"}]}"#.utf8)
            }
            let id = args[1]
            return try JSONSerialization.data(withJSONObject: [
                "username": id,
                "messages": [["local_id": 1, "timestamp": timestamp,
                              "sender": "Synthetic", "content": id, "type": "text"]]
            ])
        }
        let sessions = try reader.sessions()
        #expect(sessions.count == 2)
        for session in sessions {
            let result = try reader.history(session: session, since: "2026-10-20", until: "2026-10-21", timeZone: zone)
            #expect(result.messages.count == 1)
            #expect(result.messages.first?.content == session.id)
        }
    }
    @Test func processBoundsOutputAndTime() throws {
        #expect(throws: WeChatReadError.outputLimit) {
            try WeChatProcess.run(executable: "/bin/sh", arguments: ["-c", "while :; do printf '1234567890'; done"], maxBytes: 100)
        }
        #expect(throws: WeChatReadError.timeout) {
            try WeChatProcess.run(executable: "/bin/sh", arguments: ["-c", "while :; do :; done"], timeout: 0.1)
        }
    }
}
#endif
