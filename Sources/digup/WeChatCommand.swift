import Foundation
import DigUpKit

func wechatCommand(_ input: [String]) throws {
    #if os(macOS)
    guard let action = input.first,
          ["sessions", "history", "search", "sns-feed", "sns-search"].contains(action) else {
        throw CLIError("wechat: sessions | history CHAT | search QUERY | sns-feed | sns-search QUERY")
    }
    let needsValue = ["history", "search", "sns-search"].contains(action)
    var cursor = 1
    var arguments = [action]
    if needsValue {
        guard input.count > cursor, !input[cursor].isEmpty, !input[cursor].hasPrefix("-") else {
            throw CLIError("wechat: missing chat/query")
        }
        arguments.append(input[cursor]); cursor += 1
    }
    var options: [String: String] = [:]
    let permitted: Set<String> = action == "sessions" ? ["--limit"] :
        action == "history" ? ["--limit", "--offset", "--since", "--until"] :
        action == "search" ? ["--limit", "--since", "--until", "--in"] :
        ["--limit", "--since", "--until", "--user"]
    while cursor < input.count {
        let key = input[cursor]
        guard permitted.contains(key), cursor + 1 < input.count, options[key] == nil,
              !input[cursor + 1].hasPrefix("-") else { throw CLIError("wechat: invalid option \(key)") }
        options[key] = input[cursor + 1]; cursor += 2
    }
    guard let limit = Int(options["--limit"] ?? "20"), (1...200).contains(limit) else {
        throw CLIError("wechat: limit must be 1...200")
    }
    options["--limit"] = String(limit)
    if let offset = options["--offset"], Int(offset).map({ $0 >= 0 }) != true {
        throw CLIError("wechat: invalid offset")
    }
    let format = DateFormatter(); format.locale = Locale(identifier: "en_US_POSIX")
    format.dateFormat = "yyyy-MM-dd"; format.isLenient = false
    for key in ["--since", "--until"] {
        if let text = options[key] {
            guard let date = format.date(from: text), format.string(from: date) == text else {
                throw CLIError("wechat: date must be YYYY-MM-DD")
            }
        }
    }
    if let since = options["--since"], let until = options["--until"], since >= until {
        throw CLIError("wechat: until must be after since")
    }
    guard let executable = WeChatReaderLocation.detect() else {
        throw CLIError("wechat: reader missing; configure WeChat access in the application")
    }
    if action == "sessions" {
        let sessions = try WeChatReader(executable: executable).sessions().prefix(limit)
        let rows: [[String: Any]] = sessions.map {
            ["username": $0.id, "name": $0.name, "chat_type": $0.kind.rawValue,
             "timestamp": $0.lastMessageTimestamp as Any? ?? NSNull()]
        }
        let data = try JSONSerialization.data(withJSONObject: ["sessions": rows, "source_limit": 200])
        FileHandle.standardOutput.write(data)
        return
    }
    for key in options.keys.sorted() { arguments += [key, options[key]!] }
    arguments += ["--json", "--with-meta"]
    let data = try WeChatProcess.run(executable: executable, arguments: arguments)
    let value = try JSONSerialization.jsonObject(with: data)
    if let object = value as? [String: Any], object["error"] != nil || object["success"] as? Bool == false {
        throw CLIError("wechat: reader reported unavailable data; check application access configuration")
    }
    // Keep source/freshness metadata, including incomplete-cache warnings. Never call it full history.
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
    #else
    throw CLIError("wechat: currently supported on macOS only")
    #endif
}
