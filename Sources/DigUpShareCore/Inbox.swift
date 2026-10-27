import Foundation

/// Shared inbox between DigUpShare and DigUpApp.
///
/// Layout (same contract as Dukou):
/// ```
/// <group>/Inbox/
///   Staging/<id>.partial/   ← extension only
///   Ready/<id>/             ← app reads / deletes
///   Failures/<uuid>.json
///   Diagnostics/
/// ```
public struct Inbox: Sendable, Hashable {
    public let root: URL

    public init(root: URL) { self.root = root }

    public static func resolve(
        appGroupIdentifier: String = AppGroup.identifier,
        fileManager: FileManager = .default
    ) throws -> Inbox {
        guard let container = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else {
            throw InboxError.containerUnavailable(identifier: appGroupIdentifier)
        }
        return Inbox(root: container.appendingPathComponent("Inbox", isDirectory: true))
    }

    public var staging: URL { root.appendingPathComponent("Staging", isDirectory: true) }
    public var ready: URL { root.appendingPathComponent("Ready", isDirectory: true) }
    public var diagnostics: URL { root.appendingPathComponent("Diagnostics", isDirectory: true) }
    public var failures: URL { root.appendingPathComponent(ShareFailure.directoryName, isDirectory: true) }

    public func prepareDirectories(fileManager: FileManager = .default) throws {
        for directory in [staging, ready, diagnostics, failures] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    @discardableResult
    public func pruneStaging(
        olderThan interval: TimeInterval = 30 * 60,
        now: Date = Date(),
        fileManager: FileManager = .default
    ) -> Int {
        let contents = (try? fileManager.contentsOfDirectory(
            at: staging,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        var removed = 0
        for candidate in contents {
            let newest = Self.newestModificationDate(at: candidate, fileManager: fileManager) ?? .distantPast
            guard now.timeIntervalSince(newest) > interval else { continue }
            if (try? fileManager.removeItem(at: candidate)) != nil { removed += 1 }
        }
        return removed
    }

    static func newestModificationDate(at url: URL, fileManager: FileManager) -> Date? {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        var newest = (try? url.resourceValues(forKeys: Set(keys)))?.contentModificationDate
        guard let enumerator = fileManager.enumerator(
            at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return newest }
        for case let child as URL in enumerator {
            guard let date = (try? child.resourceValues(forKeys: Set(keys)))?.contentModificationDate else { continue }
            if newest == nil || date > newest! { newest = date }
        }
        return newest
    }
}
