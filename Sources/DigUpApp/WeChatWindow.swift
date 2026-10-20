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
    var query = "" { didSet { searchMessages() } }
    var result: WeChatReadResult?
    var busy = false
    var error: String?
    private var generation = UUID()
    private var cancelWork: (() -> Void)?

    private let engine: Engine
    private let semanticIndex: WeChatSemanticIndex?
    private var indexTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var vectors: [String: [Float]] = [:]
    private var vectorSource: String?
    private var rankedIDs: [String]?
    var indexStatus = ""
    var conversationQuery = ""
    var conversationKind = "all"
    var filteredSessions: [WeChatSession] {
        sessions.filter {
            (conversationKind == "all" || $0.kind.rawValue == conversationKind)
            && (conversationQuery.isEmpty || $0.name.localizedCaseInsensitiveContains(conversationQuery))
        }
    }
    init(engine: Engine) {
        self.engine = engine
        semanticIndex = try? WeChatSemanticIndex(directory: engine.indexDirectory.appendingPathComponent("WeChat"))
    }
    private func clearSearch() {
        indexTask?.cancel(); searchTask?.cancel()
        vectors = [:]; vectorSource = nil; rankedIDs = nil; indexStatus = ""
    }
    private func indexMessages(_ messages: [WeChatMessage], session: WeChatSession) {
        let token = generation
        let documents = messages.filter { ["text", "文本", "1"].contains($0.type.lowercased()) && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { ($0.id, Prompts.document(title: session.name, text: String($0.content.prefix(4000)))) }
        guard !documents.isEmpty else { return }
        indexStatus = L("Preparing semantic search…")
        indexTask = Task {
            do {
                guard let semanticIndex, let source = await engine.chatEmbeddingSource() else {
                    if token == generation { indexStatus = L("Text search only") }
                    return
                }
                try Task.checkCancellation()
                let keys = documents.map { WeChatSemanticIndex.key(session: session.id, message: $0.0, document: $0.1) }
                let cached = try await semanticIndex.cached(keys: keys, source: source)
                guard token == generation else { return }
                vectorSource = source
                for (i, document) in documents.enumerated() { vectors[document.0] = cached[keys[i]] }
                let missing = documents.indices.filter { cached[keys[$0]] == nil }
                for start in stride(from: 0, to: missing.count, by: 8) {
                    try Task.checkCancellation()
                    let batch = Array(missing[start..<min(start + 8, missing.count)])
                    guard let embedded = await engine.embedChatDocuments(batch.map { documents[$0].1 }), embedded.count == batch.count,
                          embedded.allSatisfy({ $0.source == source }) else { throw WeChatReadError.invalidResponse }
                    try Task.checkCancellation()
                    guard token == generation else { return }
                    var save: [String: [Float]] = [:]
                    for (i, embedding) in zip(batch, embedded) { vectors[documents[i].0] = embedding.values; save[keys[i]] = embedding.values }
                    try await semanticIndex.store(save, source: source)
                    guard !Task.isCancelled, token == generation else { return }
                    indexStatus = L("Indexing {0}/{1}", vectors.count, documents.count)
                }
                guard token == generation else { return }
                indexStatus = L("Semantic search ready · {0}", vectors.count)
                searchMessages()
            } catch is CancellationError {} catch {
                if token == generation { indexStatus = L("Text search only") }
            }
        }
    }
    private func searchMessages() {
        searchTask?.cancel(); rankedIDs = nil
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines), token = generation
        guard !text.isEmpty, !vectors.isEmpty, let source = vectorSource else { return }
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            guard let queryVector = await engine.embedChatQuery(text), queryVector.source == source,
                  !Task.isCancelled, token == generation, query.trimmingCharacters(in: .whitespacesAndNewlines) == text else { return }
            rankedIDs = WeChatSemanticIndex.rank(messages: result?.messages ?? [], vectors: vectors, query: text, queryVector: queryVector.values)
        }
    }
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
        selected = true
        if !sessions.isEmpty { return }
        detectReader()
        authorized = true
        selected = true
        if !executable.isEmpty { loadSessions() }
    }

    func reset() {
        clearSearch()
        busy = false
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
            if token == generation { cancelWork = nil; busy = false }
        }
    }

    func read() {
        guard WeChatAvailability.enabled, authorized, let session = sessions.first(where: { $0.id == selection }) else { return }
        cancelWork?()
        generation = UUID()
        clearSearch()
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
                if token == generation { result = found; indexMessages(found.messages, session: session) }
            } catch {
                if token == generation { self.error = message(error) }
            }
            if token == generation { cancelWork = nil; busy = false }
        }
    }

    var visibleMessages: [WeChatMessage] {
        let messages = result?.messages ?? []
        guard !query.isEmpty else { return messages }
        if let rankedIDs {
            let byID = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) })
            return rankedIDs.compactMap { byID[$0] }
        }
        return messages.filter { $0.content.localizedCaseInsensitiveContains(query) || $0.sender.localizedCaseInsensitiveContains(query) }
    }
}

struct WeChatView: View {
    @Bindable var state: WeChatState
    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 10) {
                HStack {
                    TextField(L("Find conversation"), text: $state.conversationQuery)
                    Button { state.loadSessions() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.plain).help(L("Refresh")).disabled(state.busy)
                }.padding(.horizontal, 12).padding(.top, 12)
                Picker(L("Conversations"), selection: $state.conversationKind) {
                    Text(L("All conversations")).tag("all")
                    Text(L("Group chats")).tag("group")
                    Text(L("Personal chats")).tag("person")
                    Text(L("Official accounts")).tag("official")
                    Text(L("Other conversations")).tag("other")
                }.labelsHidden().padding(.horizontal, 12)
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(state.filteredSessions) { session in
                            Button {
                                guard state.selection != session.id else { return }
                                state.selection = session.id; state.query = ""; state.read()
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: session.kind == .group ? "person.2" : session.kind == .official ? "megaphone" : session.kind == .person ? "person" : "bubble.left")
                                        .frame(width: 20).foregroundStyle(.secondary)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(session.name == session.id ? L("Unnamed conversation") : session.name)
                                            .lineLimit(2).multilineTextAlignment(.leading)
                                        Text(L(session.kind == .group ? "Group chats" : session.kind == .official ? "Official accounts" : session.kind == .person ? "Personal chats" : "Other conversations"))
                                            .font(.caption2).foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 12).padding(.vertical, 10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(state.selection == session.id ? Color.accentColor.opacity(0.15) : Color.clear)
                                .contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }.frame(width: 220)
            Divider()
            VStack(alignment: .leading, spacing: 12) {
            if state.executable.isEmpty {
                Text(L("WeChat reader not found. Install and configure wx on this Mac, then detect again."))
                    .foregroundStyle(.secondary)
                Button(L("Detect Again")) { state.open() }
            }
            HStack {
                Text(state.sessions.first(where: { $0.id == state.selection }).map { $0.name == $0.id ? L("Unnamed conversation") : $0.name } ?? L("Choose a conversation"))
                    .font(.headline).lineLimit(1)
                Spacer()
                Button(L("Refresh")) { state.read() }.disabled(state.selection.isEmpty || state.busy)
            }
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
                HStack {
                    Text(L("{0} matching messages", state.visibleMessages.count))
                    Spacer()
                    Text(state.indexStatus)
                }.font(.caption).foregroundStyle(.secondary)
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
            }.padding(16).frame(maxWidth: .infinity, maxHeight: .infinity)
        }.frame(minWidth: 760, minHeight: 400)
    }
}

/// Routes the menu shortcut to the main product window; owns no separate window.
final class WeChatWindowController {
    private unowned let app: AppController
    let state: WeChatState
    init(app: AppController) { self.app = app; state = WeChatState(engine: app.engine) }
    func show() { app.searchWindow.showWeChat() }
    func snapshot(to url: URL) throws { try app.searchWindow.snapshot(to: url) }
}
