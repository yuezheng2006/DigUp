#if os(macOS)
import Foundation

/// Downloads contact avatars into the export folder so HTML can use `img-src 'self'`
/// (WeChat CDN URLs are blocked by the report CSP).
public struct WeChatExportAvatarStore: Sendable {
    private let root: URL
    private var cache: [String: String] = [:]

    public init(root: URL) {
        self.root = root
    }

    /// Relative path under the export root (`avatars/…`), or nil when unavailable.
    public mutating func relativePath(for remote: URL?, cacheKey: String) -> String? {
        let key = sanitize(cacheKey)
        guard !key.isEmpty else { return nil }
        if let hit = cache[key] { return hit }
        guard let remote else {
            cache[key] = ""
            return nil
        }
        let folder = root.appendingPathComponent("avatars", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let ext = preferredExtension(remote)
        let file = folder.appendingPathComponent("\(key).\(ext)")
        let relative = "avatars/\(key).\(ext)"
        do {
            if remote.isFileURL {
                if FileManager.default.fileExists(atPath: file.path) {
                    try FileManager.default.removeItem(at: file)
                }
                try FileManager.default.copyItem(at: remote, to: file)
            } else {
                guard let data = Self.fetch(remote), !data.isEmpty else {
                    cache[key] = ""
                    return nil
                }
                try data.write(to: file, options: .atomic)
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            cache[key] = relative
            return relative
        } catch {
            cache[key] = ""
            return nil
        }
    }

    public static func htmlTag(path: String?, alt: String) -> String {
        let escape = WeChatExportFormatting.escape
        if let path, !path.isEmpty {
            return "<img class=\"avatar\" src=\"\(escape(path))\" alt=\"\" width=\"32\" height=\"32\" loading=\"lazy\">"
        }
        let initial = alt.trimmingCharacters(in: .whitespacesAndNewlines).first.map(String.init) ?? ""
        return "<span class=\"avatar blank\" aria-hidden=\"true\">\(escape(initial))</span>"
    }

    private static func fetch(_ url: URL) -> Data? {
        let host = (url.host ?? "").lowercased()
        // WeChat head images live on these CDN hosts; refuse unrelated URLs.
        let allowed = host.contains("qlogo.cn") || host.contains("qpic.cn")
            || host.contains("wx.qq.com") || host.hasSuffix("weixin.qq.com")
        guard allowed, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https"
        else { return nil }

        var request = URLRequest(url: url, timeoutInterval: 6)
        request.setValue("DigUpPlus/1.0", forHTTPHeaderField: "User-Agent")
        let semaphore = DispatchSemaphore(value: 0)
        var result: Data?
        let task = URLSession.shared.dataTask(with: request) { data, response, _ in
            defer { semaphore.signal() }
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let data, !data.isEmpty, data.count <= 2_000_000 else { return }
            result = data
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + 7)
        return result
    }

    private func sanitize(_ key: String) -> String {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let mapped = trimmed.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) { return Character(scalar) }
            return "_"
        }
        let joined = String(mapped).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return String(joined.prefix(64))
    }

    private func preferredExtension(_ url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        if ["jpg", "jpeg", "png", "webp", "gif"].contains(ext) { return ext == "jpeg" ? "jpg" : ext }
        return "jpg"
    }
}
#endif
