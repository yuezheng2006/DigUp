#if os(macOS)
import Foundation

public struct WeChatMoment: Identifiable, Sendable {
    public let id: String
    public let author: String
    public let content: String
    public let timestamp: Double
    public let mediaCount: Int
}

/// Host-independent read interface; neither the app nor a skill needs database/key details.
public protocol WeChatMomentsProviding: Sendable {
    func moments(query: String, author: String, since: String?, until: String?, limit: Int) throws -> [WeChatMoment]
}

public struct WeChatMomentsProvider: WeChatMomentsProviding {
    private let run: WeChatReader.Runner
    public init(executable: String) {
        run = { try WeChatProcess.run(executable: executable, arguments: $0) }
    }
    public init(run: @escaping WeChatReader.Runner) { self.run = run }
    public func moments(query: String, author: String, since: String?, until: String?, limit: Int = 100) throws -> [WeChatMoment] {
        guard (1...200).contains(limit), !query.hasPrefix("-"), !author.hasPrefix("-") else { throw WeChatReadError.invalidRange }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"; formatter.isLenient = false
        for date in [since, until].compactMap({ $0 }) {
            guard let parsed = formatter.date(from: date), formatter.string(from: parsed) == date else { throw WeChatReadError.invalidRange }
        }
        if let since, let until, since >= until { throw WeChatReadError.invalidRange }
        var args = query.isEmpty ? ["sns-feed"] : ["sns-search", query]
        args += ["--json", "--with-meta", "--limit", String(limit)]
        if !author.isEmpty { args += ["--user", author] }
        if let since { args += ["--since", since] }
        if let until { args += ["--until", until] }
        let data = try run(args)
        guard data.count <= 8 * 1024 * 1024,
              let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw WeChatReadError.invalidResponse }
        var seen = Set<String>()
        return try rows.map { row in
            guard let tid = row["tid"] as? NSNumber, CFGetTypeID(tid) != CFBooleanGetTypeID(),
                  let stamp = row["timestamp"] as? NSNumber, CFGetTypeID(stamp) != CFBooleanGetTypeID(),
                  stamp.doubleValue.isFinite, stamp.doubleValue > 0,
                  let author = row["author"] as? String, let content = row["content"] as? String,
                  seen.insert(tid.stringValue).inserted else { throw WeChatReadError.invalidResponse }
            return WeChatMoment(id: tid.stringValue, author: author, content: content,
                                timestamp: stamp.doubleValue, mediaCount: max(0, (row["media"] as? [Any])?.count ?? 0))
        }.sorted { $0.timestamp == $1.timestamp ? $0.id < $1.id : $0.timestamp > $1.timestamp }
    }
}
#endif
