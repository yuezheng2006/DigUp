import Foundation

public struct BatchStaging: Sendable, Hashable {
    public let batchID: UUID
    public let directory: URL

    public static let partialSuffix = "partial"
    public static let manifestFileName = "manifest.json"
    public static let itemsDirectoryName = "items"

    public var itemsDirectory: URL {
        directory.appendingPathComponent(Self.itemsDirectoryName, isDirectory: true)
    }

    public static func create(
        in inbox: Inbox,
        batchID: UUID = UUID(),
        fileManager: FileManager = .default
    ) throws -> BatchStaging {
        try inbox.prepareDirectories(fileManager: fileManager)
        let directory = inbox.staging
            .appendingPathComponent("\(batchID.uuidString).\(partialSuffix)", isDirectory: true)
        try fileManager.createDirectory(
            at: directory.appendingPathComponent(itemsDirectoryName, isDirectory: true),
            withIntermediateDirectories: true
        )
        return BatchStaging(batchID: batchID, directory: directory)
    }

    public func destination(
        for itemID: UUID,
        displayName: String,
        fileManager: FileManager = .default
    ) throws -> URL {
        let itemDirectory = itemsDirectory.appendingPathComponent(itemID.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: itemDirectory, withIntermediateDirectories: true)
        return itemDirectory.appendingPathComponent(displayName, isDirectory: false)
    }

    public func relativePath(for itemID: UUID, displayName: String) -> String {
        "\(Self.itemsDirectoryName)/\(itemID.uuidString)/\(displayName)"
    }

    @discardableResult
    public func commit(
        manifest: BatchManifest,
        diagnostics: ImportDiagnostics?,
        intent: BatchIntent?,
        in inbox: Inbox,
        fileManager: FileManager = .default
    ) throws -> URL {
        try BatchManifest.encoder().encode(manifest).write(
            to: directory.appendingPathComponent(Self.manifestFileName),
            options: .atomic
        )
        if let intent, let payload = try? BatchManifest.encoder().encode(intent) {
            try payload.write(
                to: directory.appendingPathComponent(BatchIntent.fileName),
                options: .atomic
            )
        }
        if let payload = diagnostics?.encoded() {
            try? payload.write(
                to: directory.appendingPathComponent(ImportDiagnostics.fileName),
                options: .atomic
            )
        }
        try fileManager.createDirectory(at: inbox.ready, withIntermediateDirectories: true)
        let destination = inbox.ready.appendingPathComponent(batchID.uuidString, isDirectory: true)
        try fileManager.moveItem(at: directory, to: destination)
        return destination
    }

    public func discard(fileManager: FileManager = .default) {
        try? fileManager.removeItem(at: directory)
    }
}
