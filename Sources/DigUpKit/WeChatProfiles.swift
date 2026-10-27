#if os(macOS)
import Foundation
import SQLite3

public struct WeChatProfile: Sendable {
    public let username: String
    public let alias: String
    public let remark: String
    public let nickName: String
    public let avatar: URL?
    public let isEnterprise: Bool

    /// WeChat UI order: 备注 → 昵称 → 微信号/alias → username.
    public var preferredName: String {
        let remark = remark.trimmingCharacters(in: .whitespacesAndNewlines)
        if !remark.isEmpty { return remark }
        let nick = nickName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !nick.isEmpty { return nick }
        let alias = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        if !alias.isEmpty { return alias }
        return username
    }
}

public struct WeChatProfiles: Sendable {
    public init() {}
    public var people: [String: WeChatProfile] = [:]
    public var selfID: String?

    /// Usernames / nick / alias / remark that should count as "me" in exports and UI.
    public var selfAliases: Set<String> {
        guard let id = selfID else { return [] }
        var keys: Set<String> = [id]
        if let profile = people[id] {
            for value in [profile.alias, profile.remark, profile.nickName, profile.preferredName] {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { keys.insert(trimmed) }
            }
        }
        return keys
    }

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
            // Prefer small_head_url; some rows only keep big_head_url (rare for rooms).
            let rich = """
                SELECT username, alias, remark, nick_name,
                       COALESCE(NULLIF(small_head_url, ''), NULLIF(big_head_url, ''))
                FROM contact LIMIT 50000
                """
            let basic = """
                SELECT username,
                       COALESCE(NULLIF(small_head_url, ''), NULLIF(big_head_url, ''))
                FROM contact LIMIT 50000
                """
            let richOK = sqlite3_prepare_v2(db, rich, -1, &stmt, nil) == SQLITE_OK
            if !richOK {
                stmt = nil
                guard sqlite3_prepare_v2(db, basic, -1, &stmt, nil) == SQLITE_OK else { continue }
            }
            defer { sqlite3_finalize(stmt) }
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let raw = sqlite3_column_text(stmt, 0) else { continue }
                let id = String(cString: raw)
                func col(_ i: Int32) -> String {
                    sqlite3_column_text(stmt, i).map { String(cString: $0) } ?? ""
                }
                let alias: String, remark: String, nick: String, avatar: URL?
                if richOK {
                    alias = col(1); remark = col(2); nick = col(3)
                    avatar = URL(string: col(4))
                } else {
                    alias = ""; remark = ""; nick = ""
                    avatar = URL(string: col(1))
                }
                result.people[id] = WeChatProfile(
                    username: id, alias: alias, remark: remark, nickName: nick,
                    avatar: avatar, isEnterprise: id.hasSuffix("@openim"))
                if account == id || account.hasPrefix(id + "_") {
                    if id.count > (result.selfID?.count ?? 0) { result.selfID = id }
                }
            }
        }
        return result
    }
}

public struct WeChatMember: Sendable, Equatable {
    public let username: String
    public let contactDisplay: String
    public let display: String
    public let groupNickname: String
    public init(username: String, contactDisplay: String, display: String, groupNickname: String) {
        self.username = username; self.contactDisplay = contactDisplay
        self.display = display; self.groupNickname = groupNickname
    }
}

/// Maps raw history `sender` strings (wxid / alias / nick) to WeChat-visible names (备注优先)
/// and back to a canonical username for avatar lookup.
public struct WeChatNameDirectory: Sendable {
    private let labels: [String: String]
    /// Soft keys (nick / alias / group nick) → unique username when unambiguous.
    private let ids: [String: String]
    public init(labels: [String: String] = [:], ids: [String: String] = [:]) {
        self.labels = labels; self.ids = ids
    }

    public func displayName(for sender: String) -> String {
        let key = sender.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return sender }
        if let name = labels[key], !name.isEmpty { return name }
        if key.hasPrefix("wxid_") { return key } // unresolved id — UI may soften this
        return sender
    }

    /// Canonical contact/group username for avatar / profile lookup.
    public func username(for sender: String) -> String? {
        let key = sender.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        if let id = ids[key] { return id }
        if labels[key] != nil { return key }
        return nil
    }

    public func avatarURL(for sender: String, in profiles: WeChatProfiles) -> URL? {
        if let id = username(for: sender) { return profiles.people[id]?.avatar }
        return profiles.people[sender]?.avatar
    }

    /// Room members + contact profile. Never indexes a group_nickname shared by many rows (wx quirk).
    public static func build(members: [WeChatMember], profiles: WeChatProfiles) -> WeChatNameDirectory {
        var labels: [String: String] = [:]
        var soft: [String: [(name: String, id: String)]] = [:]
        func prefer(_ username: String, contactDisplay: String, display: String) -> String {
            if let profile = profiles.people[username] { return profile.preferredName }
            let contact = contactDisplay.trimmingCharacters(in: .whitespacesAndNewlines)
            if !contact.isEmpty { return contact }
            let shown = display.trimmingCharacters(in: .whitespacesAndNewlines)
            return shown.isEmpty ? username : shown
        }
        let usernames = Set(members.map(\.username))
        for member in members {
            let name = prefer(member.username, contactDisplay: member.contactDisplay, display: member.display)
            labels[member.username] = name
            // History often sends 备注/展示名 as `sender` — reverse-map when unique.
            if !name.isEmpty, name != member.username {
                soft[name, default: []].append((name, member.username))
            }
            for key in [member.contactDisplay, member.display] {
                let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty, trimmed != member.username {
                    soft[trimmed, default: []].append((name, member.username))
                }
            }
            if let profile = profiles.people[member.username] {
                for key in [profile.alias, profile.nickName, profile.remark] where !key.isEmpty {
                    soft[key, default: []].append((name, member.username))
                }
            }
            let group = member.groupNickname.trimmingCharacters(in: .whitespacesAndNewlines)
            // Skip nicknames that collide with another member's username (observed wx bug).
            if !group.isEmpty, !usernames.contains(group) {
                soft[group, default: []].append((name, member.username))
            }
        }
        var ids: [String: String] = [:]
        for (key, values) in soft {
            let uniqueNames = Set(values.map(\.name))
            let uniqueIDs = Set(values.map(\.id))
            if uniqueNames.count == 1, labels[key] == nil {
                labels[key] = values[0].name
            }
            if uniqueIDs.count == 1, ids[key] == nil {
                ids[key] = values[0].id
            }
        }
        // Global profile usernames fill gaps (1:1 chats without members list).
        var globalSoft: [String: [(name: String, id: String)]] = [:]
        for (id, profile) in profiles.people {
            if labels[id] == nil { labels[id] = profile.preferredName }
            if members.isEmpty {
                let preferred = profile.preferredName
                for key in [profile.alias, profile.nickName, profile.remark, preferred] where !key.isEmpty {
                    globalSoft[key, default: []].append((preferred, id))
                }
            }
        }
        if members.isEmpty {
            for (key, values) in globalSoft {
                let uniqueNames = Set(values.map(\.name))
                let uniqueIDs = Set(values.map(\.id))
                if uniqueNames.count == 1, labels[key] == nil { labels[key] = values[0].name }
                if uniqueIDs.count == 1, ids[key] == nil { ids[key] = values[0].id }
            }
        }
        return WeChatNameDirectory(labels: labels, ids: ids)
    }
}
#endif
