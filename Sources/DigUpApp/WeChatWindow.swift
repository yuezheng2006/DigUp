import AppKit
import DigUpKit
import Observation
import SwiftUI

@Observable
final class WeChatState {
    var executable = AppSettings.defaults.string(forKey: "wechatExecutable") ?? ""
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

    func chooseExecutable() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            reset()
            executable = url.path
            AppSettings.defaults.set(executable, forKey: "wechatExecutable")
        }
    }

    func reset() {
        cancelWork?()
        cancelWork = nil
        generation = UUID()
        sessions = []; selection = ""; result = nil; error = nil; query = ""
    }

    private func message(_ error: Error) -> String {
        switch error as? WeChatReadError {
        case .executable: L("Choose an executable wx reader that is already configured.")
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
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("WeChat Messages")).font(.title2.bold())
            Text(L("Read an authorized local account through your configured wx reader. Nothing is sent or added to the file index."))
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Text(state.executable.isEmpty ? L("No reader selected") : state.executable)
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                Spacer()
                Button(L("Choose wx…")) { state.chooseExecutable() }.disabled(state.busy)
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
            .disabled(!state.authorized || state.busy)
            HStack {
                DatePicker(L("From"), selection: $state.since, displayedComponents: .date)
                DatePicker(L("Until (exclusive)"), selection: $state.until, displayedComponents: .date)
                Button(L("Read Messages")) { state.read() }.disabled(state.selection.isEmpty)
            }
            .disabled(!state.authorized || state.busy)
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
                TextField(L("Search within loaded messages (text or sender)"), text: $state.query)
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

final class WeChatWindowController: NSObject, NSWindowDelegate {
    private unowned let app: AppController
    let state = WeChatState()
    private var window: NSWindow?
    var isVisible: Bool { window?.isVisible == true }
    init(app: AppController) { self.app = app }
    func show() {
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: WeChatView(state: state)))
            window.title = L("WeChat Messages")
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        if let window { app.present(window) }
    }
    func snapshot(to url: URL) throws { try Snapshot.write(window, to: url) }

    func windowWillClose(_ notification: Notification) {
        state.authorized = false
        state.reset()
        app.windowClosed()
    }
}
