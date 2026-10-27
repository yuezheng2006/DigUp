import Foundation

public enum NameSource: String, Codable, Sendable {
    case suggested, fileURL, temporaryFile
}

public struct AttachmentDiagnostic: Codable, Sendable, Hashable {
    public let itemIndex: Int
    public let attachmentIndex: Int
    public let registeredTypeIdentifiers: [String]
    public let hasSuggestedName: Bool
    public let suggestedNameExtension: String?
    public let nameSource: NameSource?
    public let selectedTypeIdentifier: String?
    public let loadStrategy: LoadStrategy?
    public let byteCount: Int64?
    public let failure: String?

    public init(
        itemIndex: Int,
        attachmentIndex: Int,
        registeredTypeIdentifiers: [String],
        hasSuggestedName: Bool,
        suggestedNameExtension: String?,
        nameSource: NameSource?,
        selectedTypeIdentifier: String?,
        loadStrategy: LoadStrategy?,
        byteCount: Int64?,
        failure: String?
    ) {
        self.itemIndex = itemIndex
        self.attachmentIndex = attachmentIndex
        self.registeredTypeIdentifiers = registeredTypeIdentifiers
        self.hasSuggestedName = hasSuggestedName
        self.suggestedNameExtension = suggestedNameExtension
        self.nameSource = nameSource
        self.selectedTypeIdentifier = selectedTypeIdentifier
        self.loadStrategy = loadStrategy
        self.byteCount = byteCount
        self.failure = failure
    }
}

public struct ImportDiagnostics: Codable, Sendable, Hashable {
    public static let currentSchemaVersion = 1
    public static let fileName = "diagnostics.json"

    public let schemaVersion: Int
    public let batchID: UUID
    public let createdAt: Date
    public let extensionVersion: String?
    public let action: ShareAction
    public let inputItemCount: Int
    public let succeeded: Bool
    public let attachments: [AttachmentDiagnostic]

    public init(
        batchID: UUID,
        createdAt: Date,
        extensionVersion: String?,
        action: ShareAction,
        inputItemCount: Int,
        succeeded: Bool,
        attachments: [AttachmentDiagnostic],
        schemaVersion: Int = currentSchemaVersion
    ) {
        self.schemaVersion = schemaVersion
        self.batchID = batchID
        self.createdAt = createdAt
        self.extensionVersion = extensionVersion
        self.action = action
        self.inputItemCount = inputItemCount
        self.succeeded = succeeded
        self.attachments = attachments
    }

    public func encoded() -> Data? {
        try? BatchManifest.encoder().encode(self)
    }
}

public enum DiagnosticsLog {
    public static func record(_ diagnostics: ImportDiagnostics, in inbox: Inbox) {
        guard let payload = diagnostics.encoded() else { return }
        try? FileManager.default.createDirectory(at: inbox.diagnostics, withIntermediateDirectories: true)
        try? payload.write(
            to: inbox.diagnostics.appendingPathComponent("\(diagnostics.batchID.uuidString).json"),
            options: .atomic
        )
    }
}
