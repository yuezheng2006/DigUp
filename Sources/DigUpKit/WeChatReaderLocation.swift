#if os(macOS)
import Foundation

/// Locate a reader, never enumerate accounts, databases or key material.
public enum WeChatReaderLocation {
    public static func detect(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        path: String = ProcessInfo.processInfo.environment["PATH"] ?? ""
    ) -> String? {
        let fm = FileManager.default
        var candidates = path.split(separator: ":").filter { $0.hasPrefix("/") }.map { "\($0)/wx" }
        candidates += ["/opt/homebrew/bin/wx", "/usr/local/bin/wx", home.appendingPathComponent(".local/bin/wx").path]
        let nodes = home.appendingPathComponent(".nvm/versions/node")
        let versions = (try? fm.contentsOfDirectory(atPath: nodes.path)) ?? []
        candidates += versions.sorted { $0.compare($1, options: .numeric) == .orderedDescending }
            .map { nodes.appendingPathComponent("\($0)/bin/wx").path }
        return candidates.first {
            var directory: ObjCBool = false
            return fm.fileExists(atPath: $0, isDirectory: &directory)
                && !directory.boolValue && fm.isExecutableFile(atPath: $0)
        }
    }
}
#endif
