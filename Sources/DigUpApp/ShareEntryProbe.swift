import DigUpShareCore
import Foundation

enum ShareEntryState: Sendable, Equatable {
    case enabled, disabled, unregistered
}

/// Reads/writes DigUp Share-menu elections via `/usr/bin/pluginkit` (same approach as Dukou).
@MainActor
final class ShareEntryProbe: ObservableObject {
    private nonisolated static let timeout: TimeInterval = 3

    @Published private(set) var states: [ShareAction: ShareEntryState] = [:]
    @Published private(set) var switching: Set<ShareAction> = []
    @Published private(set) var requested: [ShareAction: Bool] = [:]
    private var isRefreshing = false

    func isOn(_ action: ShareAction) -> Bool {
        requested[action] ?? (states[action] == .enabled)
    }

    func isSwitching(_ action: ShareAction) -> Bool { switching.contains(action) }

    func refresh() {
        guard !isRefreshing, switching.isEmpty else { return }
        guard let base = Bundle.main.bundleIdentifier else {
            states = Dictionary(uniqueKeysWithValues: ShareAction.allCases.map { ($0, .unregistered) })
            return
        }
        isRefreshing = true
        let entries = ShareAction.allCases.map { ($0, "\(base).\($0.bundleIdentifierSuffix)") }
        Self.queue.async {
            var probed: [ShareAction: ShareEntryState] = [:]
            for (action, identifier) in entries {
                probed[action] = Self.probe(identifier)
            }
            Task { @MainActor [probed] in
                self.states = probed
                self.isRefreshing = false
            }
        }
    }

    func setEnabled(_ enabled: Bool, for action: ShareAction) {
        guard !switching.contains(action), let base = Bundle.main.bundleIdentifier else { return }
        let identifier = "\(base).\(action.bundleIdentifierSuffix)"
        switching.insert(action)
        requested[action] = enabled
        Self.queue.async {
            _ = Self.run(["-e", enabled ? "use" : "ignore", "-i", identifier])
            let state = Self.probe(identifier)
            Task { @MainActor in
                self.states[action] = state
                self.requested[action] = nil
                self.switching.remove(action)
            }
        }
    }

    private nonisolated static let queue = DispatchQueue(
        label: "com.yuezheng.digupplus.share-entry-probe",
        qos: .userInitiated,
        attributes: .concurrent
    )

    nonisolated static func probe(_ identifier: String) -> ShareEntryState {
        guard let result = run(["-m", "-i", identifier]), result.status == 0 else {
            return .unregistered
        }
        return state(fromOutput: result.text, identifier: identifier)
    }

    private struct ToolResult {
        let status: Int32
        let text: String
    }

    private nonisolated static func run(_ arguments: [String]) -> ToolResult? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do { try process.run() } catch { return nil }
        guard finished.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            return nil
        }
        let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
        return ToolResult(status: process.terminationStatus, text: String(decoding: data, as: UTF8.self))
    }

    nonisolated static func state(fromOutput text: String, identifier: String) -> ShareEntryState {
        for line in text.split(whereSeparator: \.isNewline) where line.contains(identifier) {
            let flag = line.first { !$0.isWhitespace }
            return flag == "+" ? .enabled : .disabled
        }
        return .unregistered
    }
}
