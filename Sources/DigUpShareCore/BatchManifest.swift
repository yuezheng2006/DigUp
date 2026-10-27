import Foundation

public enum LoadStrategy: String, Codable, Sendable {
    case fileRepresentation
    case fileURL
}

public struct ManifestItem: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public let displayName: String
    public let relativePath: String
    public let contentType: String?
    public let byteCount: Int64
    public let itemIndex: Int
    public let attachmentIndex: Int
    public let loadStrategy: LoadStrategy

    public init(
        id: UUID,
        displayName: String,
        relativePath: String,
        contentType: String?,
        byteCount: Int64,
        itemIndex: Int,
        attachmentIndex: Int,
        loadStrategy: LoadStrategy
    ) {
        self.id = id
        self.displayName = displayName
        self.relativePath = relativePath
        self.contentType = contentType
        self.byteCount = byteCount
        self.itemIndex = itemIndex
        self.attachmentIndex = attachmentIndex
        self.loadStrategy = loadStrategy
    }
}

public struct BatchManifest: Codable, Sendable, Hashable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let batchID: UUID
    public let createdAt: Date
    public let action: ShareAction
    public let items: [ManifestItem]

    public init(
        batchID: UUID,
        createdAt: Date,
        items: [ManifestItem],
        action: ShareAction = .shelf,
        schemaVersion: Int = currentSchemaVersion
    ) {
        self.schemaVersion = schemaVersion
        self.batchID = batchID
        self.createdAt = createdAt
        self.action = action
        self.items = items
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        batchID = try container.decode(UUID.self, forKey: .batchID)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        action = try container.decodeIfPresent(ShareAction.self, forKey: .action) ?? .shelf
        items = try container.decode([ManifestItem].self, forKey: .items)
    }

    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
