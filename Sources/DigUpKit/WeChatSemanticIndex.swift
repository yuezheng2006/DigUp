#if os(macOS)
import Foundation
import CryptoKit

/// Persistent vectors only: chat text stays in the reader/current view. Model and content changes invalidate keys.
public actor WeChatSemanticIndex {
    private let db: Database
    public init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent("wechat-vectors.sqlite")
        db = try Database(path: file.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        try db.execute("CREATE TABLE IF NOT EXISTS vectors (key TEXT NOT NULL, source TEXT NOT NULL, vector BLOB NOT NULL, PRIMARY KEY(key, source))")
    }
    public nonisolated static func key(session: String, message: String, document: String) -> String {
        SHA256.hash(data: Data("\(session)\u{0}\(message)\u{0}\(document)".utf8)).map { String(format: "%02x", $0) }.joined()
    }
    public func cached(keys: [String], source: String) throws -> [String: [Float]] {
        var result: [String: [Float]] = [:]
        for key in keys {
            try db.query("SELECT vector FROM vectors WHERE key=? AND source=?", [.text(key), .text(source)]) { row in
                guard let data = row.blob(0), data.count == Vectors.dimension * 2 else { return }
                let bytes = [UInt8](data)
                result[key] = stride(from: 0, to: bytes.count, by: 2).map { Float(Float16(bitPattern: UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8)) }
            }
        }
        return result
    }
    public func store(_ vectors: [String: [Float]], source: String) throws {
        try db.transaction {
            for (key, vector) in vectors {
                guard vector.count == Vectors.dimension, vector.allSatisfy(\.isFinite) else { throw WeChatReadError.invalidResponse }
                try db.run("INSERT OR REPLACE INTO vectors(key, source, vector) VALUES(?,?,?)", [.text(key), .text(source), .blob(Vectors.half(vector))])
            }
        }
    }
    /// Same per-query semantic standardization and word bonus as DigUp's file search.
    public nonisolated static func rank(messages: [WeChatMessage], vectors: [String: [Float]], query: String, queryVector: [Float]) -> [String] {
        let indexed = messages.filter { vectors[$0.id]?.count == queryVector.count }
        let scores: [Float] = indexed.map { item in zip(vectors[item.id]!, queryVector).reduce(Float(0)) { $0 + $1.0 * $1.1 } }
        let meaning = Searcher.meaning(scores, Array(repeating: .text, count: scores.count))
        var ranks = Dictionary(uniqueKeysWithValues: zip(indexed.map(\.id), meaning).filter { $0.1 >= 2 })
        for item in messages where item.content.localizedCaseInsensitiveContains(query) || item.sender.localizedCaseInsensitiveContains(query) {
            ranks[item.id] = (ranks[item.id] ?? 0) + Searcher.wordWeight
        }
        return ranks.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.map(\.key)
    }
}
#endif
