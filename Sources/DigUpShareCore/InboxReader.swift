import Foundation

public struct ReadyBatch: Sendable, Hashable, Identifiable {
    public var id: UUID { manifest.batchID }
    public let directory: URL
    public let manifest: BatchManifest
    public let intent: BatchIntent?

    public init(directory: URL, manifest: BatchManifest, intent: BatchIntent?) {
        self.directory = directory
        self.manifest = manifest
        self.intent = intent
    }

    public func itemURLs() -> [URL] {
        manifest.items.map { directory.appendingPathComponent($0.relativePath) }
    }
}

public struct InboxReader: Sendable {
    public let inbox: Inbox

    public init(inbox: Inbox) { self.inbox = inbox }

    public func listReady(fileManager: FileManager = .default) -> [ReadyBatch] {
        let urls = (try? fileManager.contentsOfDirectory(
            at: inbox.ready,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        var batches: [ReadyBatch] = []
        for url in urls {
            let manifestURL = url.appendingPathComponent(BatchStaging.manifestFileName)
            guard let data = try? Data(contentsOf: manifestURL),
                  let manifest = try? BatchManifest.decoder().decode(BatchManifest.self, from: data)
            else { continue }
            let intentURL = url.appendingPathComponent(BatchIntent.fileName)
            let intent: BatchIntent? = {
                guard let d = try? Data(contentsOf: intentURL) else { return nil }
                return try? BatchManifest.decoder().decode(BatchIntent.self, from: d)
            }()
            batches.append(ReadyBatch(directory: url, manifest: manifest, intent: intent))
        }
        return batches.sorted { $0.manifest.createdAt < $1.manifest.createdAt }
    }

    public func consumeFailures(fileManager: FileManager = .default) -> [ShareFailure] {
        let urls = (try? fileManager.contentsOfDirectory(
            at: inbox.failures,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        var failures: [ShareFailure] = []
        for url in urls where url.pathExtension == "json" {
            defer { try? fileManager.removeItem(at: url) }
            guard let data = try? Data(contentsOf: url),
                  let failure = try? BatchManifest.decoder().decode(ShareFailure.self, from: data)
            else { continue }
            failures.append(failure)
        }
        return failures
    }

    public func consumeIntent(in batch: ReadyBatch, fileManager: FileManager = .default) -> BatchIntent? {
        let url = batch.directory.appendingPathComponent(BatchIntent.fileName)
        guard let data = try? Data(contentsOf: url),
              let intent = try? BatchManifest.decoder().decode(BatchIntent.self, from: data)
        else { return nil }
        try? fileManager.removeItem(at: url)
        return intent
    }
}
