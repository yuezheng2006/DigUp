#if os(macOS)
import Foundation
import Darwin
import ImageIO
import UniformTypeIdentifiers

/// A deliberately small wx protocol adapter. No key acquisition, auto-discovery, or database writes.
public enum WeChatReadError: String, Error, Sendable {
    case executable, timeout, outputLimit, commandFailed, invalidResponse, invalidRange, changedSource
}

public struct WeChatSession: Identifiable, Sendable, Equatable {
    public enum Kind: String, Sendable { case group, person, official, other }
    public let id: String
    public let name: String
    public let kind: Kind
    public let lastMessageTimestamp: TimeInterval?
    public init(id: String, name: String, chatType: String? = nil, lastMessageTimestamp: TimeInterval? = nil) {
        self.id = id; self.name = name
        self.lastMessageTimestamp = lastMessageTimestamp.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        // Official accounts take precedence over unreliable group flags; display names are never classifiers.
        if id.hasPrefix("gh_") || chatType == "official_account" { kind = .official }
        else if id.hasSuffix("@chatroom") { kind = .group }
        else if chatType == "private" || id.hasPrefix("wxid_") { kind = .person }
        else { kind = .other }
    }
}

public struct WeChatMessage: Identifiable, Sendable, Equatable {
    public let id: String
    public let sender: String
    public let timestamp: Double
    public let content: String
    public let type: String
    /// Lossless source record, not an instruction to an agent.
    public let raw: Data
}

public struct WeChatExportResult: Sendable {
    public let messages: Int
    public let images: Int
    public let unavailableImages: Int
}

public enum WeChatDatePreset: String, CaseIterable, Sendable {
    case week = "Last week", twoWeeks = "Last two weeks", month = "Last month", halfYear = "Last six months"
    public func start(through date: Date, calendar: Calendar = .current) -> Date {
        let end = calendar.startOfDay(for: date)
        switch self {
        case .week: return calendar.date(byAdding: .day, value: -6, to: end)!
        case .twoWeeks: return calendar.date(byAdding: .day, value: -13, to: end)!
        case .month: return calendar.date(byAdding: .month, value: -1, to: end)!
        case .halfYear: return calendar.date(byAdding: .month, value: -6, to: end)!
        }
    }
}

public struct WeChatReadResult: Sendable {
    public let messages: [WeChatMessage]
    public let truncated: Bool
    public let statuses: [String]
    public let queriedAt: Date
}

/// Run only the explicitly selected executable. Arguments are never passed through a shell.
/// Both pipes are drained without blocking; limits also apply to misbehaving helpers.
public enum WeChatProcess {
    public static func run(executable: String, arguments: [String], timeout: Double = 30,
                           maxBytes: Int = 8 * 1024 * 1024) throws -> Data {
        try Task<Never, Never>.checkCancellation()
        guard executable.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: executable) else {
            throw WeChatReadError.executable
        }
        let process = Process(), output = Pipe(), errors = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errors
        var environment = ProcessInfo.processInfo.environment
        // npm's wx entry uses /usr/bin/env node. Finder does not inherit a login shell's PATH.
        environment["PATH"] = URL(fileURLWithPath: executable).deletingLastPathComponent().path
            + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
        process.environment = environment
        do { try process.run() } catch { throw WeChatReadError.executable }
        try? output.fileHandleForWriting.close()
        try? errors.fileHandleForWriting.close()
        let handles = [output.fileHandleForReading, errors.fileHandleForReading]
        for handle in handles { _ = fcntl(handle.fileDescriptor, F_SETFL, O_NONBLOCK) }
        defer {
            if process.isRunning {
                process.terminate()
                let grace = ProcessInfo.processInfo.systemUptime + 0.2
                while process.isRunning && ProcessInfo.processInfo.systemUptime < grace { usleep(10_000) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            process.waitUntilExit()
            for handle in handles { try? handle.close() }
        }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var data = Data(), total = 0
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            try Task<Never, Never>.checkCancellation()
            var received = false
            for (index, handle) in handles.enumerated() {
                let count = Darwin.read(handle.fileDescriptor, &buffer, buffer.count)
                if count > 0 {
                    total += count
                    guard total <= maxBytes else { throw WeChatReadError.outputLimit }
                    if index == 0 { data.append(contentsOf: buffer.prefix(count)) }
                    received = true
                } else if count < 0 && errno != EAGAIN && errno != EINTR {
                    throw WeChatReadError.commandFailed
                }
            }
            if !process.isRunning && !received { break }
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw WeChatReadError.timeout }
            if !received { usleep(10_000) }
        }
        guard process.terminationStatus == 0 else { throw WeChatReadError.commandFailed }
        return data
    }
}

public struct WeChatReader: Sendable {
    public typealias Runner = @Sendable ([String]) throws -> Data
    private let run: Runner
    public init(executable: String) {
        run = { try WeChatProcess.run(executable: executable, arguments: $0) }
    }
    public init(run: @escaping Runner) { self.run = run }

    // wx 0.3 bare arrays and newer named wrappers. Unknown schemas must not look like empty history.
    private static func rows(_ data: Data, key: String, expectedUsername: String? = nil) throws -> ([[String: Any]], [String: Any]) {
        guard data.count <= 8 * 1024 * 1024,
              let value = try? JSONSerialization.jsonObject(with: data) else { throw WeChatReadError.invalidResponse }
        if let rows = value as? [[String: Any]] { return (rows, [:]) }
        guard let object = value as? [String: Any], object["error"] == nil,
              (object["success"] as? Bool) != false,
              let rows = object[key] as? [[String: Any]] else { throw WeChatReadError.invalidResponse }
        if let expectedUsername, let actual = object["username"] as? String, actual != expectedUsername {
            throw WeChatReadError.changedSource
        }
        return (rows, object["meta"] as? [String: Any] ?? [:])
    }

    public func sessions() throws -> [WeChatSession] {
        let (rows, _) = try Self.rows(run(["sessions", "--limit", "200", "--json", "--with-meta"]), key: "sessions")
        var seen = Set<String>()
        let sessions: [WeChatSession] = try rows.compactMap { row in
            guard let id = row["username"] as? String, !id.isEmpty, !id.hasPrefix("-"),
                  seen.insert(id).inserted else { throw WeChatReadError.invalidResponse }
            let name = row["chat"] as? String ?? row["display_name"] as? String ?? row["name"] as? String ?? row["display"] as? String ?? id
            // Folded inboxes aggregate other conversations; they are not readable chat identities.
            if row["chat_type"] as? String == "folded" { return nil }
            let stamp = row["timestamp"] as? NSNumber
            let session = WeChatSession(id: id, name: name, chatType: row["chat_type"] as? String,
                                        lastMessageTimestamp: stamp.flatMap { CFGetTypeID($0) == CFBooleanGetTypeID() ? nil : $0.doubleValue })
            return session.kind == .official ? nil : session
        }
        // Latest message first, independent of the reader's order. Missing timestamps go last;
        // stable identity breaks ties so a refresh does not reshuffle equally recent conversations.
        return sessions.sorted {
            let lhs = $0.lastMessageTimestamp ?? 0, rhs = $1.lastMessageTimestamp ?? 0
            return lhs == rhs ? $0.id < $1.id : lhs > rhs
        }
    }

    /// Fetch only the selected message's image, matching both timestamp and local identity.
    public func image(message: WeChatMessage, session: WeChatSession) throws -> Data {
        let raw = try JSONSerialization.jsonObject(with: message.raw) as? [String: Any]
        guard let localID = raw?["local_id"] else { throw WeChatReadError.invalidResponse }
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"; formatter.timeZone = .current
        let date = Date(timeIntervalSince1970: message.timestamp)
        let start = formatter.string(from: date)
        let end = formatter.string(from: Calendar.current.date(byAdding: .day, value: 1, to: date)!)
        var attachment: String?
        for offset in stride(from: 0, to: 1000, by: 200) {
            let (items, _) = try Self.rows(run(["attachments", session.id, "--kind", "image", "--since", start,
                "--until", end, "--limit", "200", "--offset", String(offset), "--json"]),
                key: "attachments", expectedUsername: session.id)
            attachment = items.first {
                String(describing: $0["local_id"] ?? "") == String(describing: localID)
                    && ($0["timestamp"] as? NSNumber)?.doubleValue == message.timestamp
            }?["attachment_id"] as? String
            if attachment != nil || items.count < 200 { break }
        }
        guard let attachment, !attachment.isEmpty, !attachment.hasPrefix("-") else { throw WeChatReadError.invalidResponse }
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: folder) }
        var file = folder.appendingPathComponent("image.bin")
        _ = try run(["extract", attachment, "--output", file.path, "--json"])
        func boundedData(_ url: URL) throws -> Data {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size > 0, size <= 20 * 1024 * 1024 else { throw WeChatReadError.outputLimit }
            return try Data(contentsOf: url)
        }
        let original = try boundedData(file)
        if original.starts(with: Data("wxgf".utf8)) {
            guard let ffmpeg = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
                .first(where: { fm.isExecutableFile(atPath: $0) }) else { throw WeChatReadError.executable }
            let probe = URL(fileURLWithPath: ffmpeg).deletingLastPathComponent().appendingPathComponent("ffprobe").path
            guard fm.isExecutableFile(atPath: probe) else { throw WeChatReadError.executable }
            // Some wxgf images put a grayscale plane before the color frame. Taking frame zero
            // unconditionally produces a valid but nearly white image, not the actual picture.
            let metadata = try WeChatProcess.run(executable: probe, arguments: ["-v", "error", "-f", "hevc",
                "-read_intervals", "%+#2", "-show_frames", "-show_entries", "frame=pix_fmt", "-of", "json", file.path])
            let frames = (try JSONSerialization.jsonObject(with: metadata) as? [String: Any])?["frames"] as? [[String: Any]] ?? []
            let candidates = Array(frames.prefix(2))
            let chosen = candidates.firstIndex { frame in
                guard let format = frame["pix_fmt"] as? String else { return false }
                return !format.hasPrefix("gray")
            } ?? 0
            let pattern = folder.appendingPathComponent("preview-%02d.png")
            _ = try WeChatProcess.run(executable: ffmpeg, arguments: ["-v", "error", "-f", "hevc", "-i", file.path,
                "-frames:v", String(chosen + 1), "-vf", "scale=1600:1600:force_original_aspect_ratio=decrease,format=rgba",
                "-fps_mode", "passthrough", pattern.path])
            file = folder.appendingPathComponent(String(format: "preview-%02d.png", chosen + 1))
        }
        return try boundedData(file)
    }

    /// Streams local messages and linked images to a private staging directory, publishing only on success.
    /// Dates are half-open; nil bounds mean all local history, independent of the reading-page cap.
    public func exportConversation(session: WeChatSession, to destination: URL, since: String? = nil,
                           until: String? = nil, timeZone: TimeZone = .current) throws -> WeChatExportResult {
        let start = since.flatMap { Self.date($0, timeZone: timeZone) }
        let end = until.flatMap { Self.date($0, timeZone: timeZone) }
        guard !session.id.isEmpty, !session.id.hasPrefix("-"),
              since == nil || start != nil, until == nil || end != nil,
              start == nil || end == nil || start! < end! else { throw WeChatReadError.invalidRange }
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw WeChatReadError.commandFailed }
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".digup-export-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: temporary) }
        let media = temporary.appendingPathComponent("images")
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        func file(_ name: String) throws -> FileHandle {
            let url = temporary.appendingPathComponent(name)
            guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw WeChatReadError.commandFailed }
            return try FileHandle(forWritingTo: url)
        }
        let output = try file("messages.txt"), html = try file("index.html")
        defer { try? output.close(); try? html.close() }
        func escape(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        func writeHTML(_ text: String) throws { try html.write(contentsOf: Data(text.utf8)) }
        try writeHTML("<!doctype html><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width\"><meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; img-src 'self' data:; style-src 'unsafe-inline'\"><title>WeChat</title><style>body{max-width:900px;margin:32px auto;padding:16px;font:16px system-ui}article{border-bottom:1px solid #ddd;padding:16px 0}pre{white-space:pre-wrap;overflow-wrap:anywhere;font:inherit}img{max-width:100%;max-height:600px}header{color:#666}</style><h1>" + escape(session.name) + "</h1>")
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        func write(_ text: String) throws { try output.write(contentsOf: Data(text.utf8)) }
        func page(_ offset: Int) throws -> [[String: Any]] {
            var args = ["history", session.id, "--limit", "200", "--offset", String(offset), "--with-meta", "--json"]
            if let since { args += ["--since", since] }
            if let until { args += ["--until", until] }
            let (items, meta) = try Self.rows(run(args), key: "messages", expectedUsername: session.id)
            guard items.count <= 200 else { throw WeChatReadError.invalidResponse }
            if let missing = meta["unknown_shards"] as? [Any], !missing.isEmpty { throw WeChatReadError.invalidResponse }
            return items
        }
        try write(session.name + "\n\n")
        var offset = 0, count = 0, imageCount = 0, unavailable = 0, seen = Set<String>()
        var first: Data?
        while true {
            try Task<Never, Never>.checkCancellation()
            let items = try page(offset)
            if offset == 0 { first = try JSONSerialization.data(withJSONObject: items, options: [.sortedKeys]) }
            for row in items {
                if let owner = row["chat_username"] as? String, owner != session.id { throw WeChatReadError.changedSource }
                guard let stamp = row["timestamp"] as? NSNumber, CFGetTypeID(stamp) != CFBooleanGetTypeID(),
                      stamp.doubleValue.isFinite, let content = row["content"] as? String,
                      let id = row["local_id"], id is String || id is NSNumber else { throw WeChatReadError.invalidResponse }
                let timestamp = stamp.doubleValue
                guard seen.insert("\(id)@\(timestamp)").inserted else { throw WeChatReadError.changedSource }
                if let start, timestamp < start.timeIntervalSince1970 { continue }
                if let end, timestamp >= end.timeIntervalSince1970 { continue }
                let type = row["type"] as? String ?? "unknown"
                let body: String
                var imagePath: String?
                switch type.lowercased() {
                case "text", "文本", "1": body = content
                case "image", "图片", "3":
                    do {
                        let raw = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
                        let message = WeChatMessage(id: "\(id)@\(timestamp)", sender: row["sender"] as? String ?? "", timestamp: timestamp, content: content, type: type, raw: raw)
                        let data = try image(message: message, session: session)
                        try Task<Never, Never>.checkCancellation()
                        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                              let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw WeChatReadError.invalidResponse }
                        let path = "images/message-\(count + 1).png"
                        let url = temporary.appendingPathComponent(path)
                        guard let encoder = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw WeChatReadError.commandFailed }
                        CGImageDestinationAddImage(encoder, decoded, nil)
                        guard CGImageDestinationFinalize(encoder) else { throw WeChatReadError.commandFailed }
                        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                        imagePath = path; imageCount += 1
                        body = "[图片 / Image: \(path)]"
                    } catch is CancellationError { throw CancellationError() }
                    catch {
                        try Task<Never, Never>.checkCancellation()
                        let failedImage = temporary.appendingPathComponent("images/message-\(count + 1).png")
                        if FileManager.default.fileExists(atPath: failedImage.path) { try FileManager.default.removeItem(at: failedImage) }
                        unavailable += 1; body = "[图片不可用 / Image unavailable]"
                    }
                case "video", "视频", "43": body = "[视频 / Video]"
                case "sticker", "表情", "表情包", "47": body = "[表情 / Sticker]"
                case "voice", "语音", "34": body = "[语音 / Voice]"
                default: body = "[附件或其他消息 / Attachment or other message]"
                }
                try write("\(formatter.string(from: Date(timeIntervalSince1970: timestamp)))  \(row["sender"] as? String ?? "")\n\(body)\n\n")
                let heading = formatter.string(from: Date(timeIntervalSince1970: timestamp)) + "  " + (row["sender"] as? String ?? "")
                try writeHTML("<article id=\"message-\(count + 1)\"><header>" + escape(heading) + "</header><pre>" + escape(body) + "</pre>")
                if let imagePath { try writeHTML("<a href=\"\(imagePath)\"><img loading=\"lazy\" src=\"\(imagePath)\" alt=\"图片 / Image\"></a>") }
                try writeHTML("</article>\n")
                count += 1
            }
            if items.count < 200 { break }
            offset += items.count
        }
        // Detect a moving pagination head rather than silently delivering a partial export.
        guard try JSONSerialization.data(withJSONObject: page(0), options: [.sortedKeys]) == first else {
            throw WeChatReadError.changedSource
        }
        try Task<Never, Never>.checkCancellation()
        try output.synchronize()
        try output.close()
        try html.synchronize(); try html.close()
        // A new directory only: never overwrite an existing export or user folder.
        try FileManager.default.moveItem(at: temporary, to: destination)
        return WeChatExportResult(messages: count, images: imageCount, unavailableImages: unavailable)
    }

    public static func date(_ value: String, timeZone: TimeZone) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard value.count == 10, let date = formatter.date(from: value), formatter.string(from: date) == value else { return nil }
        return date
    }

    /// Read a bounded, half-open local date range. No persistent cursor: every request is explicit.
    public func history(session: WeChatSession, since: String, until: String, timeZone: TimeZone = .current,
                        pageSize: Int = 100, maxPages: Int = 5) throws -> WeChatReadResult {
        guard let start = Self.date(since, timeZone: timeZone), let end = Self.date(until, timeZone: timeZone),
              end > start,
              (1...200).contains(pageSize), (1...10).contains(maxPages),
              !session.id.isEmpty, !session.id.hasPrefix("-") else { throw WeChatReadError.invalidRange }
        func page(_ offset: Int) throws -> ([[String: Any]], [String: Any]) {
            try Self.rows(run(["history", session.id, "--since", since, "--until", until,
                               "--limit", String(pageSize), "--offset", String(offset), "--with-meta", "--json"]), key: "messages", expectedUsername: session.id)
        }
        var messages: [String: WeChatMessage] = [:], statuses = Set<String>()
        var first: Data?, fingerprints = Set<Data>(), truncated = true
        for index in 0..<maxPages {
            let (rows, meta) = try page(index * pageSize)
            guard rows.count <= pageSize else { throw WeChatReadError.invalidResponse }
            if let missing = meta["unknown_shards"] as? [Any], !missing.isEmpty { statuses.insert("unknown_shards") }
            if let status = meta["status"] as? String { statuses.insert(status) }
            else { statuses.insert("unknown") }
            let fingerprint = try JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys])
            if index == 0 { first = fingerprint }
            if !rows.isEmpty, !fingerprints.insert(fingerprint).inserted { throw WeChatReadError.changedSource }
            for row in rows {
                if let owner = row["chat_username"] as? String, owner != session.id { throw WeChatReadError.changedSource }
                guard let stamp = row["timestamp"] as? NSNumber,
                      CFGetTypeID(stamp) != CFBooleanGetTypeID(), stamp.doubleValue.isFinite,
                      let content = row["content"] as? String,
                      let localID = row["local_id"], localID is String || localID is NSNumber else {
                    throw WeChatReadError.invalidResponse
                }
                let timestamp = stamp.doubleValue
                let sender = row["sender"] as? String ?? ""
                let type = row["type"] as? String ?? "unknown"
                let id = "\(localID)@\(timestamp)"
                let raw = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
                let message = WeChatMessage(id: id, sender: sender, timestamp: timestamp, content: content, type: type, raw: raw)
                if let old = messages[id], old != message { throw WeChatReadError.changedSource }
                if timestamp >= start.timeIntervalSince1970 && timestamp < end.timeIntervalSince1970 {
                    messages[id] = message
                }
            }
            if rows.count < pageSize { truncated = false; break }
        }
        // Offset pagination has no snapshot token. Detect a changed head, but do not claim transactional consistency.
        let (again, _) = try page(0)
        guard try JSONSerialization.data(withJSONObject: again, options: [.sortedKeys]) == first else {
            throw WeChatReadError.changedSource
        }
        let sorted = messages.values.sorted { ($0.timestamp, $0.id) < ($1.timestamp, $1.id) }
        return WeChatReadResult(messages: sorted, truncated: truncated, statuses: statuses.sorted(), queriedAt: Date())
    }
}
#endif
