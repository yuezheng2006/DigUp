import AppKit
import DigUpKit
import Observation
import SwiftUI

/// Enabled after real local group and individual chat acceptance.
enum WeChatAvailability {
    static let enabled = true
}

@Observable
final class WeChatState {
    var executable = ""
    var authorized = true
    var sessions: [WeChatSession] = []
    var selection = ""
    var since = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
    var until = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
    var query = ""
    var result: WeChatReadResult?
    var busy = false
    var error: String?
    private var generation = UUID()
    private var cancelWork: (() -> Void)?

    var selected = false
    var images: [String: NSImage] = [:]
    var imageErrors: Set<String> = []
    var loadingImage: String?
    private var imageTask: Task<Data, Error>?
    private var mediaGeneration = UUID()

    func clearMedia() {
        imageTask?.cancel(); imageTask = nil
        mediaGeneration = UUID(); images = [:]; imageErrors = []; loadingImage = nil
    }

    func loadImage(_ message: WeChatMessage) {
        guard loadingImage == nil, let session = sessions.first(where: { $0.id == selection }) else { return }
        loadingImage = message.id
        let reader = WeChatReader(executable: executable), token = mediaGeneration
        let work = Task.detached { try reader.image(message: message, session: session) }
        imageTask = work
        Task {
            do {
                let data = try await work.value
                guard token == mediaGeneration else { return }
                if let image = NSImage(data: data), image.isValid { images[message.id] = image }
                else { imageErrors.insert(message.id) }
            } catch {
                if token == mediaGeneration { imageErrors.insert(message.id) }
            }
            if token == mediaGeneration { loadingImage = nil; imageTask = nil }
        }
    }

    func detectReader() {
        reset()
        executable = WeChatReaderLocation.detect() ?? ""
    }

    func open() {
        detectReader()
        authorized = true
        selected = true
        if !executable.isEmpty { loadSessions() }
    }

    func reset() {
        clearMedia()
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
        guard WeChatAvailability.enabled, authorized, !busy else { return }
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
        guard WeChatAvailability.enabled, authorized, !busy, let session = sessions.first(where: { $0.id == selection }) else { return }
        clearMedia()
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
            if state.executable.isEmpty {
                Text(L("WeChat reader not found. Install and configure wx on this Mac, then detect again."))
                    .foregroundStyle(.secondary)
                Button(L("Detect Again")) { state.open() }
            }
            HStack {
                Picker(L("Conversation"), selection: $state.selection) {
                    Text(L("Choose a conversation")).tag("")
                    ForEach(state.sessions) { session in
                        Text(session.name == session.id ? L("Unnamed conversation") : session.name).tag(session.id)
                    }
                }
                .onChange(of: state.selection) { _, _ in
                    state.clearMedia(); state.result = nil; state.query = ""
                    if !state.selection.isEmpty { state.read() }
                }
                Button(L("Refresh")) { state.selection.isEmpty ? state.loadSessions() : state.read() }
            }
            .disabled(state.busy || state.executable.isEmpty)
            HStack {
                DatePicker(L("From"), selection: $state.since, displayedComponents: .date)
                DatePicker(L("Until (exclusive)"), selection: $state.until, displayedComponents: .date)
            }
            .disabled(!state.authorized || state.busy || state.executable.isEmpty)
            .onChange(of: state.since) { _, _ in state.result = nil; state.read() }
            .onChange(of: state.until) { _, _ in state.result = nil; state.read() }
            if state.busy { ProgressView().controlSize(.small) }
            if let error = state.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if let result = state.result {
                if result.truncated {
                    Text(L("Read limit reached. Results may be incomplete; narrow the date range.")).foregroundStyle(.orange)
                }
                Text(L("{0} matching messages", state.visibleMessages.count)).font(.caption)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(state.visibleMessages) { item in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(item.sender.hasPrefix("wxid_") ? L("WeChat contact") : item.sender) · \(Date(timeIntervalSince1970: item.timestamp).formatted())")
                                    .font(.caption).foregroundStyle(.secondary)
                                if ["text", "文本", "1"].contains(item.type.lowercased()) {
                                    Text(verbatim: item.content).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                } else if ["image", "图片", "3"].contains(item.type.lowercased()) {
                                    if let image = state.images[item.id] {
                                        Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 220)
                                    } else if state.imageErrors.contains(item.id) {
                                        Text(L("Image unavailable. It may not be downloaded or its decoder is missing.")).foregroundStyle(.secondary)
                                    } else if state.loadingImage == item.id {
                                        ProgressView().controlSize(.small)
                                    } else {
                                        Button(L("View Image")) { state.loadImage(item) }.disabled(state.loadingImage != nil)
                                    }
                                } else {
                                    Text(L("Media or attachment preview is not available yet.")).foregroundStyle(.secondary)
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
        }.padding(20).frame(minWidth: 760, minHeight: 400)
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
