import AppKit
import DigUpKit
import Observation
import SwiftUI

@Observable
final class WeChatState {
    var executable = ""
    var authorized = false
    var sessions: [WeChatSession] = []
    var selection = ""
    var since = Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date()
    var until = Date()
    var query = ""
    var result: WeChatReadResult?
    var busy = false
    var error: String?
    private var generation = UUID()
    private var cancelWork: (() -> Void)?

    var selected = false

    func detectReader() {
        reset()
        // Launch-only override for isolated runtime tests, never a persisted user path.
        let override = UserDefaults.standard.string(forKey: "defaultsSuite") != nil
            ? UserDefaults.standard.string(forKey: "wechatExecutable") : nil
        executable = override ?? WeChatReaderLocation.detect() ?? ""
    }

    func reset() {
        cancelWork?()
        cancelWork = nil
        generation = UUID()
        sessions = []; selection = ""; result = nil; error = nil; query = ""
    }

    private func message(_ error: Error) -> String {
        switch error as? WeChatReadError {
        case .executable: L("WeChat reader not found. Install and configure wx on this Mac, then detect again.")
        case .timeout: L("Reader timed out. Check its service before trying again; no automatic retry was made.")
        case .outputLimit: L("Reader output exceeded the limit. Choose a smaller date range.")
        case .invalidRange: L("Choose a start date before the end date, at most 31 days apart.")
        case .changedSource: L("Messages changed during pagination. No partial result was accepted; try again later.")
        case .invalidResponse: L("Unsupported reader response. This connector expects the wx JSON protocol.")
        default: L("Reader failed. Check the selected reader locally; private error output is not logged.")
        }
    }

    func loadSessions() {
        guard authorized, !busy else { return }
        reset()
        busy = true
        let reader = WeChatReader(executable: executable), token = generation
        let work = Task.detached { try reader.sessions() }
        cancelWork = { work.cancel() }
        Task {
            do {
                let found = try await work.value
                if token == generation { sessions = found }
            } catch {
                if token == generation { self.error = message(error) }
            }
            cancelWork = nil
            busy = false
        }
    }

    func read() {
        guard authorized, !busy, let session = sessions.first(where: { $0.id == selection }) else { return }
        result = nil; error = nil; busy = true
        let reader = WeChatReader(executable: executable), token = generation
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        let start = formatter.string(from: since), end = formatter.string(from: until), zone = TimeZone.current
        let work = Task.detached {
            try reader.history(session: session, since: start, until: end, timeZone: zone)
        }
        cancelWork = { work.cancel() }
        Task {
            do {
                let found = try await work.value
                if token == generation { result = found }
            } catch {
                if token == generation { self.error = message(error) }
            }
            cancelWork = nil
            busy = false
        }
    }

    var visibleMessages: [WeChatMessage] {
        let messages = result?.messages ?? []
        guard !query.isEmpty else { return messages }
        return messages.filter { $0.content.localizedCaseInsensitiveContains(query) || $0.sender.localizedCaseInsensitiveContains(query) }
    }
}

struct WeChatView: View {
    @Bindable var state: WeChatState
    private var executableStatus: String {
        state.executable.isEmpty
            ? L("WeChat reader not found. Install and configure wx on this Mac, then detect again.")
            : L("Local WeChat reader detected. Your reader manages the account and data location.")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("WeChat Messages")).font(.title2.bold())
            Text(L("After authorization, load recent conversations, then choose a group or individual chat and a date range. Only the selected conversation is read; cancel authorization to clear results."))
                .font(.callout).foregroundStyle(.secondary)
            Text(L("Read an authorized local account through your configured wx reader. Nothing is sent or added to the file index."))
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Text(executableStatus).foregroundStyle(.secondary)
                Spacer()
                Button(L("Detect Again")) { state.detectReader() }.disabled(state.busy)
            }
            Toggle(L("I am authorized to read the account configured in this reader."), isOn: $state.authorized)
                .onChange(of: state.authorized) { _, granted in if !granted { state.reset() } }
            HStack {
                Button(L("Load Conversations")) { state.loadSessions() }
                Picker(L("Conversation"), selection: $state.selection) {
                    Text(L("Choose a conversation")).tag("")
                    ForEach(state.sessions) { session in Text("\(session.name) · \(session.id)").tag(session.id) }
                }
                .onChange(of: state.selection) { _, _ in state.result = nil; state.query = "" }
            }
            .disabled(!state.authorized || state.busy || state.executable.isEmpty)
            HStack {
                DatePicker(L("From"), selection: $state.since, displayedComponents: .date)
                DatePicker(L("Until (exclusive)"), selection: $state.until, displayedComponents: .date)
                Button(L("Read Messages")) { state.read() }.disabled(state.selection.isEmpty)
            }
            .disabled(!state.authorized || state.busy || state.executable.isEmpty)
            .onChange(of: state.since) { _, _ in state.result = nil }
            .onChange(of: state.until) { _, _ in state.result = nil }
            Text(L("Local timezone: {0}. Up to 200 recent conversations and 500 messages per read; no background sync.", TimeZone.current.identifier))
                .font(.caption).foregroundStyle(.secondary)
            if state.busy { ProgressView().controlSize(.small) }
            if let error = state.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if let result = state.result {
                Text(L("{0} messages read. Source status: {1}. Phone sync freshness is not verified.", result.messages.count, result.statuses.joined(separator: ", ")))
                    .font(.caption).textSelection(.enabled)
                if result.truncated {
                    Text(L("Read limit reached. Results may be incomplete; narrow the date range.")).foregroundStyle(.orange)
                }
                Text(L("{0} matching messages", state.visibleMessages.count)).font(.caption)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(state.visibleMessages) { item in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(item.sender) · \(Date(timeIntervalSince1970: item.timestamp).formatted()) · \(item.type)")
                                    .font(.caption).foregroundStyle(.secondary)
                                Text(verbatim: item.content).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                if !["text", "文本", "1"].contains(item.type.lowercased()) {
                                    Text(L("Media and attachments have not been decoded.")).font(.caption).foregroundStyle(.secondary)
                                }
                                Divider()
                            }
                        }
                    }.padding(4)
                }
                if result.messages.isEmpty {
                    Text(L("No messages found in the local data for this range. This does not mean the phone has no messages."))
                }
            } else {
                Spacer()
            }
        }.padding(20).frame(minWidth: 760, minHeight: 560)
    }
}

/// Routes the menu shortcut to the main product window; owns no separate window.
final class WeChatWindowController {
    private unowned let app: AppController
    let state = WeChatState()
    init(app: AppController) { self.app = app }
    func show() { app.searchWindow.showWeChat() }
    func snapshot(to url: URL) throws { try app.searchWindow.snapshot(to: url) }
}
