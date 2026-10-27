import Foundation

public struct ShareFailure: Codable, Sendable, Hashable {
    public static let directoryName = "Failures"

    public let at: Date
    public let action: ShareAction
    public let message: String

    public init(at: Date, action: ShareAction, message: String) {
        self.at = at
        self.action = action
        self.message = message
    }

    public static func record(
        _ failure: ShareFailure,
        in inbox: Inbox,
        fileManager: FileManager = .default
    ) {
        guard let payload = try? BatchManifest.encoder().encode(failure) else { return }
        let directory = inbox.failures
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try? payload.write(
            to: directory.appendingPathComponent("\(UUID().uuidString).json"),
            options: .atomic
        )
    }
}
