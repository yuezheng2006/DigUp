import AppKit
import DigUpKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// Enabled after real local group and individual chat acceptance.
enum WeChatAvailability {
    static let enabled = true
}

@Observable
final class WeChatState {
    var showsMoments = false
    var selectedPreset: WeChatDatePreset?
    var exportPreset: WeChatDatePreset?
    func applyRange(_ preset: WeChatDatePreset) {
        let now = Date()
        selectedPreset = preset
        since = preset.start(through: now)
        until = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: now))!
        read()
    }
    var exportPresented = false
    var exportAll = true
    var exportStart = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
    var exportEnd = Date()
    var exportFolder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
    var exporting = false
    var exportStatus = ""
    private var exportTask: Task<WeChatExportResult, Error>?
    /// Contact remarks / nicknames; used so history shows WeChat-visible names, not bare wxids.
    var profiles = WeChatProfiles()
    var names = WeChatNameDirectory()

    func cancelExport() { exportTask?.cancel() }

    /// One sheet (HIG / TablePro-style): pick the folder inside the sheet with a non-blocking
    /// AppKit panel (`begin` / `beginSheetModal`), never `runModal()` while the SwiftUI sheet is up.
    @MainActor
    func chooseExportFolder() async {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = exportFolder
        panel.prompt = L("Export here")
        let response: NSApplication.ModalResponse
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            response = await panel.beginSheetModalAsync(for: window)
        } else {
            response = await panel.beginModalAsync()
        }
        if response == .OK, let url = panel.url { exportFolder = url }
    }

    /// Closes the options sheet, then writes under `exportFolder` (folder already chosen in-sheet).
    func exportMessages() {
        guard !exporting, let session = sessions.first(where: { $0.id == selection }) else { return }
        guard let bounds = WeChatExportPlan.dayBounds(all: exportAll, start: exportStart, end: exportEnd) else { return }
        let url = exportFolder.appendingPathComponent(WeChatExportPlan.folderName())
        let readerPath = executable
        let zone = TimeZone.current
        exportPresented = false
        exporting = true
        exportStatus = L("Exporting…")
        let directory = names
        let work = Task.detached { [weak self] in
            try WeChatReader(executable: readerPath).exportConversation(
                session: session, to: url, since: bounds.since, until: bounds.until, timeZone: zone,
                progress: { messages, images in
                    Task { @MainActor in
                        guard let self, self.exporting else { return }
                        self.exportStatus = L("Exporting {0} messages · {1} images…", messages, images)
                    }
                },
                displayName: { directory.displayName(for: $0) })
        }
        exportTask = work
        Task { @MainActor in
            do {
                let report = try await work.value
                self.exportStatus = L(
                    "Exported {0} messages · {1} images · {2} unavailable",
                    report.messages, report.images, report.unavailableImages)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch is CancellationError {
                self.exportStatus = L("Export cancelled")
            } catch {
                self.exportStatus = L("Export failed. No partial file was saved.") + " " + self.message(error)
            }
            self.exporting = false
            self.exportTask = nil
        }
    }

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
        if !executable.isEmpty {
            Task.detached { [weak self] in
                let loaded = WeChatProfiles.load()
                await MainActor.run { self?.profiles = loaded }
            }
        }
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
        names = WeChatNameDirectory()
    }

    /// WeChat-visible label: 备注 → 昵称 → alias；未解析的 wxid_ 显示为「微信联系人」。
    func displayName(for message: WeChatMessage) -> String {
        let label = names.displayName(for: message.sender)
        if label.hasPrefix("wxid_") { return L("WeChat contact") }
        return label.isEmpty ? L("WeChat contact") : label
    }

    /// Session list / header: contact or group `small_head_url` from wx contact DB.
    func avatarURL(for session: WeChatSession) -> URL? {
        profiles.people[session.id]?.avatar
    }

    /// Message row: resolve sender (wxid / nick / alias) → profile avatar.
    func avatarURL(for message: WeChatMessage) -> URL? {
        names.avatarURL(for: message.sender, in: profiles)
            ?? profiles.people[message.sender]?.avatar
    }

    private func message(_ error: Error) -> String {
        switch error as? WeChatReadError {
        case .executable: L("WeChat reader not found. Install and configure wx on this Mac, then detect again.")
        case .timeout: L("Reader timed out. Check its service before trying again; no automatic retry was made.")
        case .outputLimit: L("Reader output exceeded the limit. Choose a smaller date range.")
        case .invalidRange: L("Choose a start date before the end date.")
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
        result = nil; error = nil; busy = true; names = WeChatNameDirectory()
        let reader = WeChatReader(executable: executable), token = generation
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        let start = formatter.string(from: since), end = formatter.string(from: until), zone = TimeZone.current
        let knownProfiles = profiles
        let work = Task.detached {
            async let history = reader.history(session: session, since: start, until: end, timeZone: zone)
            let roster: [WeChatMember]
            do { roster = try reader.members(session: session) } catch { roster = [] }
            let loadedProfiles = knownProfiles.people.isEmpty ? WeChatProfiles.load() : knownProfiles
            let directory = WeChatNameDirectory.build(members: roster, profiles: loadedProfiles)
            return (try await history, directory, loadedProfiles)
        }
        cancelWork = { work.cancel() }
        Task {
            do {
                let (found, directory, loadedProfiles) = try await work.value
                if token == generation {
                    if profiles.people.isEmpty { profiles = loadedProfiles }
                    names = directory
                    result = found
                    indexMessages(found.messages, session: session)
                }
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
        return messages.filter {
            $0.content.localizedCaseInsensitiveContains(query)
                || $0.sender.localizedCaseInsensitiveContains(query)
                || displayName(for: $0).localizedCaseInsensitiveContains(query)
        }
    }
}

struct WeChatChatsView: View {
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
                    Text(L("Other conversations")).tag("other")
                }.labelsHidden().padding(.horizontal, 12)
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(state.filteredSessions) { session in
                            Button {
                                guard state.selection != session.id else { return }
                                state.selection = session.id; state.query = ""; state.read()
                            } label: {
                                HStack(spacing: 10) {
                                    WeChatAvatarView(
                                        url: state.avatarURL(for: session),
                                        group: session.kind == .group,
                                        fallback: session.kind == .group ? "person.2.fill"
                                            : session.kind == .person ? "person.fill" : "bubble.left",
                                        size: 36)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(session.name == session.id ? L("Unnamed conversation") : session.name)
                                            .lineLimit(2).multilineTextAlignment(.leading)
                                        HStack(spacing: 4) {
                                            Text(L(session.kind == .group ? "Group chats" : session.kind == .person ? "Personal chats" : "Other conversations"))
                                            Spacer(minLength: 0)
                                            if let timestamp = session.lastMessageTimestamp {
                                                Text(Date(timeIntervalSince1970: timestamp), format: .dateTime.month(.twoDigits).day(.twoDigits).hour().minute())
                                                    .lineLimit(1)
                                            }
                                        }.font(.caption2).foregroundStyle(.secondary)
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
            HStack(spacing: 10) {
                if let session = state.sessions.first(where: { $0.id == state.selection }) {
                    WeChatAvatarView(
                        url: state.avatarURL(for: session),
                        group: session.kind == .group,
                        fallback: session.kind == .group ? "person.2.fill"
                            : session.kind == .person ? "person.fill" : "bubble.left",
                        size: 28)
                }
                Text(state.sessions.first(where: { $0.id == state.selection }).map { $0.name == $0.id ? L("Unnamed conversation") : $0.name } ?? L("Choose a conversation"))
                    .font(.headline).lineLimit(1)
                Spacer()
                Button(L("Export…")) { state.exportPresented = true }
                    .disabled(state.selection.isEmpty || state.exporting || state.executable.isEmpty)
                Button(L("Refresh")) { state.read() }.disabled(state.selection.isEmpty || state.busy)
            }
            HStack(spacing: 6) {
                ForEach(WeChatDatePreset.allCases, id: \.self) { preset in
                    Button(L(preset.rawValue)) { state.applyRange(preset) }
                        .buttonStyle(.bordered)
                        .tint(state.selectedPreset == preset ? Color.accentColor : Color.secondary)
                }
            }.disabled(!state.authorized || state.executable.isEmpty)
            HStack {
                DatePicker(L("From"), selection: Binding(get: { state.since }, set: {
                    state.selectedPreset = nil; state.since = $0; state.read()
                }), displayedComponents: .date)
                DatePicker(L("Until (exclusive)"), selection: Binding(get: { state.until }, set: {
                    state.selectedPreset = nil; state.until = $0; state.read()
                }), displayedComponents: .date)
            }.disabled(!state.authorized || state.executable.isEmpty)
            if state.exporting {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(L("Exporting…"))
                    Button(L("Cancel")) { state.cancelExport() }
                }
            }
            if !state.exportStatus.isEmpty { Text(state.exportStatus).font(.caption).textSelection(.enabled) }
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
                            HStack(alignment: .top, spacing: 10) {
                                WeChatAvatarView(
                                    url: state.avatarURL(for: item),
                                    group: false,
                                    fallback: "person.fill",
                                    size: 32)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("\(state.displayName(for: item)) · \(Date(timeIntervalSince1970: item.timestamp).formatted())")
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
        .sheet(isPresented: $state.exportPresented) {
            WeChatExportSheet(state: state)
        }
    }
}

/// One options sheet: range + destination + Export. Avoids sheet→`runModal` deadlock
/// (osaurus / TablePro pattern: non-blocking panel, destination chosen before start).
private struct WeChatExportSheet: View {
    @Bindable var state: WeChatState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L("Export conversation")).font(.headline)
            Picker(L("Export range"), selection: $state.exportAll) {
                Text(L("All messages")).tag(true)
                Text(L("Date range")).tag(false)
            }.pickerStyle(.segmented)
            HStack(spacing: 6) {
                ForEach(WeChatDatePreset.allCases, id: \.self) { preset in
                    Button(L(preset.rawValue)) {
                        state.exportAll = false; state.exportPreset = preset
                        let now = Date()
                        state.exportStart = preset.start(through: now); state.exportEnd = now
                    }
                    .buttonStyle(.bordered)
                    .tint(!state.exportAll && state.exportPreset == preset ? Color.accentColor : Color.secondary)
                }
            }
            if !state.exportAll {
                DatePicker(L("From"), selection: Binding(get: { state.exportStart }, set: { state.exportPreset = nil; state.exportStart = $0 }), displayedComponents: .date)
                DatePicker(L("Through"), selection: Binding(get: { state.exportEnd }, set: { state.exportPreset = nil; state.exportEnd = $0 }), displayedComponents: .date)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(L("Save export to")).foregroundStyle(.secondary)
                Text(state.exportFolder.path)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(state.exportFolder.path)
                Spacer(minLength: 8)
                Button(L("Choose Folders…")) {
                    Task { await state.chooseExportFolder() }
                }
                .disabled(state.exporting)
            }
            Text(L("A folder with text and linked images. Unavailable media are marked.")).font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(L("Cancel")) { dismiss() }
                Button(L("Export")) { state.exportMessages() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(state.exporting || (!state.exportAll && Calendar.current.startOfDay(for: state.exportStart) > Calendar.current.startOfDay(for: state.exportEnd)))
            }
        }.padding(24).frame(width: 520)
    }
}

extension NSSavePanel {
    /// Non-blocking panel (osaurus): avoids nested `runModal` app-hang false positives and sheet freezes.
    @MainActor
    func beginModalAsync() async -> NSApplication.ModalResponse {
        await withCheckedContinuation { continuation in
            begin { continuation.resume(returning: $0) }
        }
    }

    @MainActor
    func beginSheetModalAsync(for window: NSWindow) async -> NSApplication.ModalResponse {
        await withCheckedContinuation { continuation in
            beginSheetModal(for: window) { continuation.resume(returning: $0) }
        }
    }
}

/// CDN avatar (qlogo / qpic) with SF Symbol fallback — session list, header, message rows.
private struct WeChatAvatarView: View {
    let url: URL?
    var group = false
    var fallback = "person.fill"
    var size: CGFloat = 36
    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .fill(Color.secondary.opacity(0.12))
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else if failed || url == nil {
                Image(systemName: fallback)
                    .font(.system(size: size * 0.38, weight: .medium))
                    .foregroundStyle(group ? Color.accentColor : Color.secondary)
            } else {
                ProgressView().controlSize(.mini)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        .task(id: url?.absoluteString) { await load() }
    }

    private func load() async {
        guard let url else { image = nil; failed = false; return }
        image = nil; failed = false
        do {
            let data = try await WeChatMedia.image(url: url)
            try Task.checkCancellation()
            image = NSImage(data: data); failed = image == nil
        } catch {
            if !Task.isCancelled { failed = true }
        }
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
