import Foundation
import UniformTypeIdentifiers

public struct Representation: Sendable, Hashable {
    public let typeIdentifier: String
    public let strategy: LoadStrategy

    public init(typeIdentifier: String, strategy: LoadStrategy) {
        self.typeIdentifier = typeIdentifier
        self.strategy = strategy
    }

    public static func choose(from identifiers: [String]) -> Representation? {
        let types = identifiers.compactMap { identifier in UTType(identifier).map { (identifier, $0) } }
        if let zip = types.first(where: { $0.1 == .zip }) {
            return Representation(typeIdentifier: zip.0, strategy: .fileRepresentation)
        }
        if let archive = types.first(where: { $0.1.conforms(to: .archive) && !$0.1.conforms(to: .url) }) {
            return Representation(typeIdentifier: archive.0, strategy: .fileRepresentation)
        }
        if let data = types.first(where: { $0.1.conforms(to: .data) && !$0.1.conforms(to: .url) }) {
            return Representation(typeIdentifier: data.0, strategy: .fileRepresentation)
        }
        if let fileURL = types.first(where: { $0.1.conforms(to: .fileURL) }) {
            return Representation(typeIdentifier: fileURL.0, strategy: .fileURL)
        }
        return nil
    }

    public static func displayName(
        preferredName: String?,
        temporaryURL: URL,
        typeIdentifier: String
    ) -> String {
        let raw = (preferredName?.isEmpty == false) ? preferredName : temporaryURL.lastPathComponent
        let fallbackExtension = temporaryURL.pathExtension.isEmpty
            ? UTType(typeIdentifier)?.preferredFilenameExtension
            : temporaryURL.pathExtension
        return DisplayName.sanitize(raw, fallbackExtension: fallbackExtension)
    }
}
