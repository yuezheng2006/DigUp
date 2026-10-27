#if os(macOS)
import Foundation
import Testing
@testable import DigUpKit

@Suite struct WeChatFileLocatorTests {
    let zone = TimeZone(secondsFromGMT: 8 * 3600)!

    func tempHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("digup-file-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    @Test func parseFilenameFromWxAndDigUpLabels() {
        #expect(WeChatFileLocator.parseFilename(from: "[文件] uuid.txt (314 B, txt)") == "uuid.txt")
        #expect(WeChatFileLocator.parseFilename(from: "[文件 / File] uuid.txt (314 B, txt)") == "uuid.txt")
        #expect(WeChatFileLocator.parseFilename(from: "[文件] 方案评估.docx (1.2 MB, docx)") == "方案评估.docx")
        #expect(WeChatFileLocator.parseFilename(from: "[文件] ../etc/passwd (1 B, txt)") == nil)
        #expect(WeChatFileLocator.parseFilename(from: "普通文本") == nil)
    }

    @Test func resolvePrefersMessageMonthUnderAccountRoot() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let account = home.appendingPathComponent("xwechat_files/acct_demo")
        let month = account.appendingPathComponent("msg/file/2026-10", isDirectory: true)
        try FileManager.default.createDirectory(at: month, withIntermediateDirectories: true)
        let file = month.appendingPathComponent("uuid.txt")
        try Data("hello".utf8).write(to: file)
        let dbDir = account.appendingPathComponent("db_storage", isDirectory: true)
        try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
        let wx = home.appendingPathComponent(".wx-cli")
        try FileManager.default.createDirectory(at: wx, withIntermediateDirectories: true)
        let config: [String: Any] = ["db_dir": dbDir.path]
        try JSONSerialization.data(withJSONObject: config).write(to: wx.appendingPathComponent("config.json"))

        let stamp = WeChatReader.date("2026-10-27", timeZone: zone)!.timeIntervalSince1970 + 12 * 3600
        let resolved = WeChatFileLocator.resolve(
            content: "[文件] uuid.txt (314 B, txt)",
            timestamp: stamp, home: home, timeZone: zone)
        #expect(resolved?.path == file.path)
    }

    @Test func resolveFallsBackToNearestMonthByMtime() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let account = home.appendingPathComponent("xwechat_files/acct_demo")
        let sep = account.appendingPathComponent("msg/file/2026-09", isDirectory: true)
        try FileManager.default.createDirectory(at: sep, withIntermediateDirectories: true)
        let file = sep.appendingPathComponent("note.txt")
        try Data("x".utf8).write(to: file)
        let dbDir = account.appendingPathComponent("db_storage", isDirectory: true)
        try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
        let wx = home.appendingPathComponent(".wx-cli")
        try FileManager.default.createDirectory(at: wx, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["db_dir": dbDir.path])
            .write(to: wx.appendingPathComponent("config.json"))

        let stamp = WeChatReader.date("2026-10-01", timeZone: zone)!.timeIntervalSince1970
        let resolved = WeChatFileLocator.resolve(
            content: "[文件] note.txt (1 B, txt)",
            timestamp: stamp, home: home, timeZone: zone)
        #expect(resolved?.lastPathComponent == "note.txt")
    }
}
#endif
