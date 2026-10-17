import AppKit
import DigUpKit
import Observation
import SwiftUI

enum SettingsTab: String, CaseIterable {
    case general, folders, code, storage

    var title: String {
        switch self {
        case .general: L("General")
        case .folders: L("Folders")
        case .code: L("Code")
        case .storage: L("Storage")
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .folders: "folder"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .storage: "internaldrive"
        }
    }
}

/// Settings, the way Mac apps lay them out: a toolbar of tabs, and the window sized to each one. Folders is also where
/// the index shows how far along it is, folder by folder.
final class SettingsWindowController: NSObject, NSWindowDelegate {
    let state: SettingsState
    /// Folders → Add Folders…, a sheet on this window.
    let addSheet: AddFoldersController
    /// Code → Add Folders… (code search's folders), a sheet on this window.
    let codeSheet: AddFoldersController
    private unowned let app: AppController
    private var window: NSWindow?
    private var tabs: NSTabViewController?

    init(app: AppController) {
        self.app = app
        state = SettingsState(app: app)
        addSheet = AddFoldersController(app: app)
        codeSheet = AddFoldersController(app: app, code: true)
        super.init()
        state.addFolders = { [weak self] in self?.addFolders() }
        state.addCodeFolders = { [weak self] in self?.addCodeFolders() }
        for sheet in [addSheet, codeSheet] {
            sheet.onAdded = { [weak self] in
                guard let self else { return }
                Task { await self.state.refresh() }
            }
        }
    }

    /// Opens Add Folders on the Folders tab.
    func addFolders() {
        addSheet.begin(on: window)
    }

    /// Opens the code folders' sheet on the Code tab.
    func addCodeFolders() {
        codeSheet.begin(on: window)
    }

    var isVisible: Bool { window?.isVisible == true }

    func show(_ tab: SettingsTab = .general) {
        let window = self.window ?? makeWindow()
        tabs?.selectedTabViewItemIndex = SettingsTab.allCases.firstIndex(of: tab) ?? 0
        state.tab = tab
        Task { await state.refresh() }
        app.present(window)
    }

    var selectedTab: SettingsTab { state.tab }

    private func makeWindow() -> NSWindow {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        tabs.transitionOptions = [.allowUserInteraction]
        for tab in SettingsTab.allCases {
            let controller = NSHostingController(rootView: SettingsPane(tab: tab, state: state))
            controller.sizingOptions = .preferredContentSize
            controller.title = tab.title   // the window takes the selected tab's title
            let item = NSTabViewItem(viewController: controller)
            item.label = tab.title
            item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.title)
            item.identifier = tab.rawValue
            tabs.addTabViewItem(item)
        }
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.tabs = tabs
        self.window = window
        state.selectTab = { [weak self] tab in
            self?.tabs?.selectedTabViewItemIndex = SettingsTab.allCases.firstIndex(of: tab) ?? 0
        }
        return window
    }

    func windowWillClose(_ notification: Notification) {
        addSheet.end()
        codeSheet.end()
        window?.contentViewController = nil
        window = nil
        tabs = nil
        app.windowClosed()
    }

    func snapshot(to url: URL) throws {
        try Snapshot.write(window, to: url)
    }
}

@Observable
final class SettingsState {
    var tab = SettingsTab.general
    private(set) var summaries: [Engine.RootSummary]?
    private(set) var codeSummaries: [Engine.RootSummary] = []
    private(set) var indexSize: Int64 = 0
    private(set) var codeIndexSize: Int64 = 0
    var launchAtLogin = false
    var loginProblem: String?
    var checksForUpdates = false
    @ObservationIgnored let app: AppController
    @ObservationIgnored var selectTab: (SettingsTab) -> Void = { _ in }
    @ObservationIgnored var addFolders: () -> Void = {}
    @ObservationIgnored var addCodeFolders: () -> Void = {}

    init(app: AppController) {
        self.app = app
    }

    @ObservationIgnored private var lastRefresh = Date.distantPast
    @ObservationIgnored private var refreshPending = false

    var model: AppModel { app.model }

    func refresh() async {
        lastRefresh = Date()
        launchAtLogin = app.launchesAtLogin
        checksForUpdates = app.updates.automaticallyChecks
        indexSize = app.engine.indexSize
        codeIndexSize = app.engine.codeIndexSize
        codeSummaries = await app.engine.rootSummaries(code: true)
        summaries = await app.engine.rootSummaries()
    }

    /// The index changed: refresh the folder counts, at most every 2 s while files are being indexed.
    func statusChanged() {
        guard !refreshPending else { return }
        refreshPending = true
        let wait = max(0, 2 - Date().timeIntervalSince(lastRefresh))
        Task {
            try? await Task.sleep(for: .seconds(wait))
            refreshPending = false
            await refresh()
        }
    }

    /// Ready to be drawn (debug snapshots wait for this).
    var isLoaded: Bool { summaries != nil }
}

/// One tab's content, at the width every tab shares.
private struct SettingsPane: View {
    let tab: SettingsTab
    let state: SettingsState
    /// The content's own height. The window is that tall up to what the screen has room for, and scrolls past it (a
    /// long list of folders ran it off the screen, Add Folders… with it).
    @State private var height: CGFloat?

    var body: some View {
        ScrollView(.vertical) {
            Group {
                switch tab {
                case .general: GeneralSettings(state: state)
                case .folders: FolderSettings(state: state)
                case .code: CodeSettings(state: state)
                case .storage: StorageSettings(state: state)
                }
            }
            .frame(width: 580)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(width: 580, height: height.map { min($0, Self.tallest) })
    }

    /// The screen's room below the menu bar, less the window's title bar and tabs and a margin.
    private static var tallest: CGFloat {
        (NSScreen.main?.visibleFrame.height ?? 800) - 140
    }
}

private struct GeneralSettings: View {
    @Bindable var state: SettingsState

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    ShortcutRecorder(combo: state.model.hotkey, apply: { state.app.setHotkey($0) },
                                     listening: { state.app.hotkeyRecording($0) }, capSize: 13)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("Search shortcut"))
                        Text(L("Opens the search panel from any app."))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                Toggle(isOn: Binding(get: { state.launchAtLogin }, set: { on in
                    state.loginProblem = state.app.setLaunchAtLogin(on)
                    state.launchAtLogin = state.app.launchesAtLogin
                })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("Open DigUp when you log in"))
                        Text(state.loginProblem ?? L("So the shortcut always works."))
                            .font(.system(size: 11))
                            .foregroundStyle(state.loginProblem == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
                    }
                }
            }
            Section {
                Text(L("Chinese fork: updates are downloaded manually from this fork’s releases."))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                LabeledContent {
                    Button(L("Open Fork Releases")) { state.app.updates.checkNow() }
                } label: {
                    Text(state.model.updateAvailable.map { L("DigUp {0} is available", $0) }
                         ?? "DigUp \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
    }
}

private struct FolderSettings: View {
    @Bindable var state: SettingsState
    @State private var removing: Engine.RootSummary?

    var body: some View {
        Form {
            Section {
                IndexProgress(model: state.model) { state.app.engine.setPaused(!state.model.status.paused) }
            }
            Section {
                if let summaries = state.summaries {
                    if summaries.isEmpty {
                        Text(L("No folders yet. Add the ones DigUp should search."))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(summaries) { summary in
                        FolderStatusRow(summary: summary) { removing = summary }
                    }
                } else {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity)
                }
            } header: {
                Text(L("Folders to search"))
            } footer: {
                HStack {
                    Button(action: state.addFolders) {
                        Label(L("Add Folders…"), systemImage: "plus")
                    }
                    Spacer()
                }
            }
            Section {
                ForEach(state.model.settings.excludedFolders, id: \.path) { folder in
                    HStack {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: folder.path))
                            .resizable()
                            .frame(width: 18, height: 18)
                        Text(tildePath(folder.path)).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button {
                            state.app.setExcluded(state.model.settings.excludedFolders.filter { $0 != folder })
                        } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help(L("Search this folder again"))
                    }
                }
                if state.model.settings.excludedFolders.isEmpty {
                    Text(L("None. Code projects, app bundles and caches are skipped anyway (code has its own tab)."))
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text(L("Skip these folders"))
            } footer: {
                HStack {
                    Button {
                        state.app.pickFolders(for: NSApp.keyWindow, prompt: L("Skip")) { folders in
                            guard !folders.isEmpty else { return }
                            state.app.setExcluded(state.model.settings.excludedFolders
                                + folders.filter { !state.model.settings.excludedFolders.contains($0) })
                        }
                    } label: {
                        Label(L("Skip a Folder…"), systemImage: "plus")
                    }
                    Spacer()
                }
            }
            Section {
                TypeExclusions(types: state.model.settings.excludedTypes) { state.app.setExcludedTypes($0) }
            } header: {
                Text(L("Skip these file types"))
            } footer: {
                Text(L("DigUp only reads pictures, PDFs, documents (txt, md, typ, rtf, docx, odt, html), audio and video here; ")
                     + L("code is read only in the code folders (the Code tab). Keys, certificates and password files are ")
                     + L("never read, nor are hidden folders like ~/.ssh."))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                Toggle(isOn: Binding(get: { state.model.settings.indexOnBattery },
                                     set: { state.app.setIndexOnBattery($0) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(AppSettings.batteryTitle)
                        Text(AppSettings.batteryDetail)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                Toggle(isOn: Binding(get: { state.model.settings.indexHoursOn }, set: { on in
                    state.app.setIndexHours(on: on, hours: state.model.settings.indexHours)
                })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("Index only at set hours"))
                        Text(L("Files are read only between these times, and what changed meanwhile is picked up when ")
                             + L("they begin. Search works all day."))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if state.model.settings.indexHoursOn {
                    LabeledContent(L("From")) {
                        HStack(spacing: 6) {
                            DatePicker(L("From"), selection: time(\.start), displayedComponents: .hourAndMinute)
                                .labelsHidden()
                            Text(L("to"))
                            DatePicker(L("To"), selection: time(\.end), displayedComponents: .hourAndMinute)
                                .labelsHidden()
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .onChange(of: state.model.status) { state.statusChanged() }
        .confirmationDialog(removalTitle, isPresented: Binding(get: { removing != nil },
                                                               set: { if !$0 { removing = nil } })) {
            Button(L("Remove"), role: .destructive) {
                guard let removing else { return }
                state.app.removeFolder(URL(fileURLWithPath: removing.path))
                Task { await state.refresh() }
            }
        } message: {
            Text(L("Its {0} files leave the index. Adding it back later indexes them ", removing?.files.formatted() ?? "")
                 + L("again."))
        }
    }

    private var removalTitle: String {
        L("Stop searching “{0}”?", removing.map { ($0.path as NSString).lastPathComponent } ?? "")
    }

    /// One end of the set hours, as a time of day for a date picker.
    private func time(_ end: KeyPath<IndexHours, Int>) -> Binding<Date> {
        Binding(get: {
            let minute = state.model.settings.indexHours[keyPath: end]
            return Calendar.current.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: Date()) ?? Date()
        }, set: { date in
            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
            let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            let hours = state.model.settings.indexHours
            state.app.setIndexHours(on: true, hours: end == \IndexHours.start ? IndexHours(start: minute, end: hours.end)
                                                                              : IndexHours(start: hours.start, end: minute))
        })
    }
}

/// Extensions typed as "heic, txt": applied on Return or when the field loses focus.
private struct TypeExclusions: View {
    let types: [String]
    let apply: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(L("Extensions"), text: $text, prompt: Text(L("e.g. heic, txt")))
            .labelsHidden()
            .focused($focused)
            .onSubmit { apply(text) }
            .onChange(of: focused) { _, now in if !now { apply(text) } }
            .onAppear { text = types.joined(separator: ", ") }
            .onChange(of: types) { _, now in text = now.joined(separator: ", ") }
    }
}

/// What the index is doing, with Pause/Resume.
private struct IndexProgress: View {
    let model: AppModel
    let togglePause: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(model.statusLine).font(.system(size: 13, weight: .semibold))
                if let progress = model.progress {
                    ProgressView(value: progress).controlSize(.small)
                }
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.hasFolders {
                Button(model.status.paused ? L("Resume") : L("Pause"), action: togglePause)
            }
        }
    }

    /// "357 of 365 files searchable · 8 waiting · 2 long files to finish"
    private var detail: String {
        let status = model.status
        var text = L("{0} of {1} files searchable", status.searchable.formatted(), status.files.formatted())
        if status.pending > 0 { text += L(" · {0} waiting", status.pending.formatted()) }
        if status.unfinished > 0 {
            text += L(" · {0} long {1} to finish", status.unfinished.formatted(), status.unfinished == 1 ? L("file") : L("files"))
        }
        if model.download.isActive { text += L(" · model {0}", model.download.progressText) }
        return text
    }
}

private struct FolderStatusRow: View {
    let summary: Engine.RootSummary
    let remove: () -> Void
    @State private var showingReasons = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: summary.missing ? "/Volumes" : summary.path))
                .resizable()
                .frame(width: 32, height: 32)
                .opacity(summary.missing ? 0.5 : 1)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text((summary.path as NSString).lastPathComponent).font(.system(size: 13, weight: .semibold))
                    if summary.missing || summary.unreadable {
                        Text(summary.missing ? L("Not connected") : L("No access"))
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.orange.opacity(0.2)))
                    }
                    if summary.unreadable {
                        Button(L("Allow in Settings…"), action: openFolderPrivacySettings)
                            .buttonStyle(.link)
                            .font(.system(size: 11))
                    }
                }
                Text(tildePath(summary.path))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !summary.kinds.isEmpty {
                    KindCounts(counts: summary.kinds).padding(.top, 1)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(summary.missing || summary.unreadable ? L("Kept for when it's back")
                     : L("{0} of {1} indexed", summary.indexed.formatted(), summary.files.formatted()))
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                if !states.isEmpty {
                    if reasons.isEmpty {
                        Text(states).font(.system(size: 11)).foregroundStyle(.secondary)
                    } else {
                        Button { showingReasons.toggle() } label: {
                            HStack(spacing: 3) {
                                Text(states)
                                Image(systemName: "info.circle")
                            }
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Why some files aren't searchable")
                        .popover(isPresented: $showingReasons, arrowEdge: .bottom) {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(reasons, id: \.self) { Text($0) }
                            }
                            .font(.system(size: 12))
                            .padding(12)
                            .frame(maxWidth: 360, alignment: .leading)
                        }
                    }
                }
            }
            Button(action: remove) {
                Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(L("Stop searching this folder"))
            .accessibilityLabel(L("Remove {0}", (summary.path as NSString).lastPathComponent))
        }
        .padding(.vertical, 2)
    }

    private var states: String {
        [summary.pending > 0 ? L("{0} waiting", summary.pending.formatted()) : nil,
         summary.unfinished > 0
            ? L("{0} long {1} to finish", summary.unfinished.formatted(), summary.unfinished == 1 ? L("file") : L("files")) : nil,
         summary.skipped > 0 ? L("{0} skipped", summary.skipped.formatted()) : nil,
         summary.failed > 0 ? L("{0} couldn't be read", summary.failed.formatted()) : nil,
         summary.leftOutCount > 0 ? L("{0} not read", summary.leftOutCount.formatted()) : nil].compactMap { $0 }
            .joined(separator: " · ")
    }

    /// One line per reason: what the crawl never queued from this folder, then what was skipped once read.
    private var reasons: [String] {
        let crawl: [String: String] = [
            "other type": "of types DigUp doesn't read",
            "app or bundle": "inside apps or bundles",
            "Photos library": "in a Photos library (its photos aren't read yet)",
            "link or special file": "links or special files",
            "in the cloud, not downloaded": "only in the cloud, not downloaded",
            "inside a code project": "inside code projects, where only screenshots count",
            "dataset": "in folders that look like datasets",
            "code or data file": "code or data files",
            "excluded type": "of the file types you skip",
        ]
        let leftOut = summary.leftOut.sorted { $0.value > $1.value }.map { reason, count in
            reason.hasPrefix("folders ") ? "\(count.formatted()) folders weren't opened (\(reason.dropFirst(8)))"
                : "\(count.formatted()) \(crawl[reason] ?? reason)"
        }
        let skipped = summary.skippedReasons.sorted { $0.value > $1.value }.map { "\($1.formatted()) skipped: \($0)" }
        return leftOut + skipped
    }
}

private struct StorageSettings: View {
    let state: SettingsState

    var body: some View {
        Form {
            Section {
                LabeledContent("EmbeddingGemma 2") {
                    Text("Google · Apache 2.0 · 865 MB")
                }
                LabeledContent(L("Status")) {
                    HStack(spacing: 8) {
                        Text(state.model.download.isReady ? L("Downloaded") : state.model.download.progressText)
                        switch state.model.download.phase {
                        case .needed, .failed:
                            Button(L("Download")) { state.model.download.start() }.controlSize(.small)
                            Button(L("Use Files…")) { state.model.download.chooseFiles(for: NSApp.keyWindow) }
                                .controlSize(.small)
                        default:
                            EmptyView()
                        }
                    }
                }
                LabeledContent(L("Location")) {
                    PathButton(url: state.model.settings.modelsDirectory)
                }
            } header: {
                Text(L("Model"))
            } footer: {
                if !state.model.download.isReady {
                    HStack(alignment: .firstTextBaseline) {
                        Text(L("If your network blocks Hugging Face, download the two files on another network and ")
                             + L("click Use Files… to choose them. DigUp checks them before it uses them."))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button(L("Copy Links")) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(ModelDownload.links, forType: .string)
                        }
                        .controlSize(.small)
                        .help(L("Copies the addresses of the two files"))
                    }
                }
            }
            Section(L("Index")) {
                LabeledContent(L("Size on disk"), value: bytes(state.indexSize))
                if state.model.hasCode {
                    LabeledContent(L("Code index"), value: bytes(state.codeIndexSize))
                }
                LabeledContent(L("Location")) {
                    PathButton(url: state.model.settings.indexDirectory)
                }
            }
            Section(L("Privacy")) {
                Text(L("DigUp reads the folders you choose and keeps what it learns in its index, on this Mac. ")
                     + L("It goes online only to download its model, once, and to check for updates (General), ")
                     + L("which sends nothing about your files."))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                Text("DigUp \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") · "
                     + "EmbeddingGemma 2 by Google (Apache 2.0), run by llama.cpp (MIT).")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
    }
}

/// Code search: its folders and how far along their index is, the editor results open in, and turning it off.
private struct CodeSettings: View {
    @Bindable var state: SettingsState
    @State private var turningOff = false
    @State private var removing: Engine.RootSummary?

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("Search your code")).font(.system(size: 13, weight: .semibold))
                    Text(L("Find code by what it does, or by a name in it: type code: in the search panel, as in ")
                         + L("“code: retry with backoff”. Code has an index of its own, and it never shows up in ")
                         + L("other searches."))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if state.model.hasCode {
                    HStack {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(state.model.codeStatusLine).font(.system(size: 12, weight: .medium))
                            if let indexing = state.model.status.code.indexing, indexing.total > 0 {
                                ProgressView(value: Double(indexing.done) / Double(indexing.total)).controlSize(.small)
                            }
                        }
                        Spacer()
                        Text(bytes(state.codeIndexSize))
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                if state.codeSummaries.isEmpty {
                    Text(L("No code folders yet. Add the folders that hold your projects."))
                        .foregroundStyle(.secondary)
                }
                ForEach(state.codeSummaries) { summary in
                    FolderStatusRow(summary: summary) { removing = summary }
                }
            } header: {
                Text(L("Code folders"))
            } footer: {
                HStack {
                    Button(action: state.addCodeFolders) {
                        Label(state.model.hasCode ? L("Add Folders…") : L("Choose Code Folders…"), systemImage: "plus")
                    }
                    Spacer()
                }
            }
            if state.model.hasCode {
                Section {
                    ForEach(state.model.settings.codeExcluded, id: \.path) { folder in
                        HStack {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: folder.path))
                                .resizable()
                                .frame(width: 18, height: 18)
                            Text(tildePath(folder.path)).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button {
                                state.app.applyCodeFolders(state.model.settings.codeRoots,
                                                           excluded: state.model.settings.codeExcluded.filter { $0 != folder })
                            } label: {
                                Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Search this folder's code again")
                        }
                    }
                    if state.model.settings.codeExcluded.isEmpty {
                        Text("None. What git ignores, vendored and generated code are skipped anyway.")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Skip these folders")
                } footer: {
                    HStack {
                        Button {
                            state.app.pickFolders(for: NSApp.keyWindow, prompt: "Skip") { folders in
                                guard !folders.isEmpty else { return }
                                let excluded = state.model.settings.codeExcluded
                                state.app.applyCodeFolders(state.model.settings.codeRoots,
                                                           excluded: excluded + folders.filter { !excluded.contains($0) })
                            }
                        } label: {
                            Label("Skip a Folder…", systemImage: "plus")
                        }
                        Spacer()
                    }
                }
            }
            Section {
                Picker(L("Open code in"), selection: Binding(get: { CodeEditor.chosen(state.model.settings.codeEditor).id },
                                                          set: { state.app.setCodeEditor($0) })) {
                    ForEach(CodeEditor.installed) { editor in Text(editor.name).tag(editor.id) }
                    Text(CodeEditor.defaultApp.name).tag(CodeEditor.defaultApp.id)
                }
            } footer: {
                Text(L("A result opens there at the line that matched. Space shows the whole file in Quick Look."))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Section {
                Text(L("The code index keeps your code's text on this Mac, as the main index keeps your documents'. ")
                     + L("It skips what git ignores, vendored and generated code, data files, and anything that looks ")
                     + L("like a key or a password."))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if state.model.hasCode {
                    HStack {
                        Spacer()
                        Button(L("Turn Off Code Search…"), role: .destructive) { turningOff = true }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .onChange(of: state.model.status) { state.statusChanged() }
        .confirmationDialog(L("Turn off code search?"), isPresented: $turningOff) {
            Button(L("Turn Off"), role: .destructive) {
                state.app.applyCodeFolders([], excluded: [])
                Task { await state.refresh() }
            }
        } message: {
            Text(L("The code index ({0}) is deleted. Turning it on again reads the code again.", bytes(state.codeIndexSize)))
        }
        .confirmationDialog(L("Stop searching the code in “{0}”?", removing.map { ($0.path as NSString).lastPathComponent } ?? ""),
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button(L("Remove"), role: .destructive) {
                guard let removing else { return }
                state.app.removeCodeFolder(URL(fileURLWithPath: removing.path))
                Task { await state.refresh() }
            }
        } message: {
            Text(L("Its {0} code files leave the code index.", removing?.files.formatted() ?? ""))
        }
    }
}

/// "~/Library/…/Models" that shows the folder in Finder.
private struct PathButton: View {
    let url: URL

    var body: some View {
        Button {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } label: {
            HStack(spacing: 4) {
                Text(tildePath(url.path)).lineLimit(1).truncationMode(.middle)
                Image(systemName: "arrow.right.circle.fill").foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .help(L("Show in Finder"))
    }
}
