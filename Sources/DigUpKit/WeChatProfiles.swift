#if os(macOS)
import Foundation
import SQLite3

public struct WeChatProfile: Sendable {
    public let username: String
    public let avatar: URL?
    public let isEnterprise: Bool
}
public struct WeChatProfiles: Sendable {
    public init() {}
    public var people: [String: WeChatProfile] = [:]
    public var selfID: String?
    /// Read existing wx metadata only; never open encrypted databases or acquire keys.
    public static func load(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Self {
        var result = Self()
        let config = home.appendingPathComponent(".wx-cli/config.json")
        guard let data = try? Data(contentsOf: config),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let dbDir = object["db_dir"] as? String else { return result }
        let account = URL(fileURLWithPath: dbDir).deletingLastPathComponent().lastPathComponent
        let files = (try? FileManager.default.contentsOfDirectory(at: home.appendingPathComponent(".wx-cli/cache"), includingPropertiesForKeys: nil)) ?? []
        let snapshot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        guard (try? FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])) != nil else { return result }
        defer { try? FileManager.default.removeItem(at: snapshot) }
        for file in files where file.pathExtension == "db" {
            // wx produces decrypted snapshots whose WAL header may remain set without a WAL.
            // Copy stable, checkpointed files privately; immutable reads never create SHM in wx's cache.
            let wal = file.path + "-wal"
            let fm = FileManager.default
            let before = try? fm.attributesOfItem(atPath: file.path)
            guard ((try? fm.attributesOfItem(atPath: wal)[.size] as? NSNumber)?.intValue ?? 0) == 0,
                  let size = before?[.size] as? NSNumber, size.intValue <= 64 * 1024 * 1024 else { continue }
            let copy = snapshot.appendingPathComponent(file.lastPathComponent)
            guard (try? fm.copyItem(at: file, to: copy)) != nil else { continue }
            let after = try? fm.attributesOfItem(atPath: file.path)
            guard before?[.modificationDate] as? Date == after?[.modificationDate] as? Date,
                  ((try? fm.attributesOfItem(atPath: wal)[.size] as? NSNumber)?.intValue ?? 0) == 0 else { continue }
            var uri = URLComponents(url: copy, resolvingAgainstBaseURL: false)!
            uri.queryItems = [URLQueryItem(name: "immutable", value: "1")]
            var db: OpaquePointer?
            guard sqlite3_open_v2(uri.string!, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else { sqlite3_close(db); continue }
            defer { sqlite3_close(db) }
            sqlite3_busy_timeout(db, 5000)
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT username, small_head_url FROM contact LIMIT 50000", -1, &stmt, nil) == SQLITE_OK else { continue }
            defer { sqlite3_finalize(stmt) }
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let raw = sqlite3_column_text(stmt, 0) else { continue }
                let id = String(cString: raw)
                let avatar = sqlite3_column_text(stmt, 1).flatMap { URL(string: String(cString: $0)) }
                result.people[id] = WeChatProfile(username: id, avatar: avatar, isEnterprise: id.hasSuffix("@openim"))
                if account == id || account.hasPrefix(id + "_") {
                    if id.count > (result.selfID?.count ?? 0) { result.selfID = id }
                }
            }
        }
        return result
    }
}
#endif
