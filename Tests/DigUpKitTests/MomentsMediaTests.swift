#if os(macOS)
import Foundation
import ImageIO
import SQLite3
import Testing
@testable import DigUpKit

@Suite struct MomentsMediaTests {
    @Test func referenceStreamAndDomainBoundaries() {
        var cipher = MomentsCipher(seed: 0)
        #expect(cipher.next() == 0x9d39247e33776d41)
        #expect(cipher.next() == 0x2af7398005aaa5c7)
        #expect(WeChatMedia.allowed(URL(string: "http://shmmsns.qpic.cn/sns/photo/150")!))
        #expect(!WeChatMedia.allowed(URL(string: "https://qpic.cn.evil.test/photo")!))
        #expect(!WeChatMedia.allowed(URL(string: "file:///etc/passwd")!))
        #expect(!WeChatMedia.allowed(URL(string: "http://127.0.0.1/photo")!))
        #expect(MomentsFilter.suspectedAdvertisement("限时优惠，扫码下单"))
        #expect(!MomentsFilter.suspectedAdvertisement("今天去公司附近看日落"))
    }
    @Test func checkpointedWALContactCacheIsReadWithoutSideEffects() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let cache = home.appendingPathComponent(".wx-cli/cache")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data(#"{"db_dir":"/accounts/wxid_self_123/db_storage"}"#.utf8)
            .write(to: home.appendingPathComponent(".wx-cli/config.json"))
        let file = cache.appendingPathComponent("contacts.db")
        var db: OpaquePointer?
        #expect(sqlite3_open(file.path, &db) == SQLITE_OK)
        #expect(sqlite3_exec(db, "PRAGMA journal_mode=WAL; CREATE TABLE contact(username TEXT, small_head_url TEXT); INSERT INTO contact VALUES('wxid_self','https://qlogo.cn/avatar');", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)
        try? FileManager.default.removeItem(atPath: file.path + "-shm")
        try? FileManager.default.removeItem(atPath: file.path + "-wal")
        let original = try Data(contentsOf: file)
        let profiles = WeChatProfiles.load(home: home)
        #expect(profiles.selfID == "wxid_self")
        #expect(profiles.people.count == 1)
        #expect(try Data(contentsOf: file) == original)
        #expect(!FileManager.default.fileExists(atPath: file.path + "-shm"))
    }
    @Test func realLocalMediaWhenExplicitlyProvided() async throws {
        guard let path = ProcessInfo.processInfo.environment["DIGUP_MOMENTS_SAMPLE"] else { return }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let rows = try WeChatMomentsProvider(run: { _ in data }).moments(query: "", author: "", since: nil, until: nil)
        let media = try #require(rows.first?.media.first)
        let image = try await WeChatMedia.image(url: media.url, media: media)
        #expect(CGImageSourceCreateWithData(image as CFData, nil) != nil)
        let profiles = WeChatProfiles.load()
        let me = try #require(profiles.selfID)
        let executable = try #require(WeChatReaderLocation.detect())
        let own = try WeChatMomentsProvider(executable: executable).moments(query: "", author: me, since: nil, until: nil, limit: 10)
        #expect(!own.isEmpty)
        #expect(own.allSatisfy { $0.authorID == me })
        let person = try #require(rows.first)
        let avatar = try #require(profiles.people[person.authorID]?.avatar)
        let avatarData = try await WeChatMedia.image(url: avatar)
        #expect(CGImageSourceCreateWithData(avatarData as CFData, nil) != nil)
    }
}
#endif
