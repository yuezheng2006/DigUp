import AppKit
import DigUpShareCore
import SwiftUI

/// Floating panel for multi-forward collection (突破微信单次 100 条).
@MainActor
final class WeChatShareShelfController: NSObject {
    static let shared = WeChatShareShelfController()

    private var panel: NSPanel?
    private var hosting: NSHostingView<WeChatShareShelfView>?
    private let model = WeChatShareShelfModel()

    func show() {
        model.reload()
        if panel == nil {
            let view = WeChatShareShelfView(model: model)
            let host = NSHostingView(rootView: view)
            hosting = host
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 360, height: 420),
                styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.title = L("WeChat Share Shelf")
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.hidesOnDeactivate = false
            panel.contentView = host
            panel.center()
            self.panel = panel
        }
        panel?.orderFrontRegardless()
    }

    func refresh() {
        model.reload()
        if panel?.isVisible == true {
            hosting?.rootView = WeChatShareShelfView(model: model)
        }
    }
}

@MainActor
final class WeChatShareShelfModel: ObservableObject {
    @Published var rows: [Row] = []
    @Published var prefs = SharePreferences.load()
    @Published var status: String = ""

    struct Row: Identifiable {
        let id: UUID
        let title: String
        let detail: String
        let zipURLs: [URL]
        let directory: URL
    }

    func reload() {
        prefs = SharePreferences.load()
        guard let inbox = try? Inbox.resolve() else {
            rows = []
            return
        }
        let reader = InboxReader(inbox: inbox)
        let ready = Dictionary(uniqueKeysWithValues: reader.listReady().map { ($0.id, $0) })
        let ids = SharePreferences.collectionIDs()
        rows = ids.compactMap { id in
            guard let batch = ready[id] else { return nil }
            let zips = batch.itemURLs().filter { $0.pathExtension.lowercased() == "zip" }
            let count = zips.count
            return Row(
                id: id,
                title: batch.manifest.action.entryTitle,
                detail: "\(count) ZIP · \(batch.manifest.createdAt.formatted(date: .abbreviated, time: .shortened))",
                zipURLs: zips,
                directory: batch.directory
            )
        }
    }

    func clear() {
        SharePreferences.clearCollection()
        reload()
        status = L("Collection cleared")
    }

    func deliver(to action: ShareAction) {
        let urls = rows.flatMap(\.zipURLs)
        guard !urls.isEmpty else {
            status = L("Collection is empty")
            return
        }
        if let prompt = prefs.promptTextForForward() {
            FilePasteboard.writeText(prompt + "\n\n" + urls.map(\.path).joined(separator: "\n"))
        } else {
            FilePasteboard.write(urls)
        }
        let bundleID = action.targetBundleIdentifier
            ?? prefs.lastCustomBundleID
            ?? prefs.customTargets.first?.bundleIdentifier
        if let bundleID,
           let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
            status = L("Delivered to %@").replacingOccurrences(of: "%@", with: action.targetDisplayName)
        } else {
            status = L("Copied to clipboard — paste into your app")
        }
    }

    func exportMarkdown() {
        let urls = rows.flatMap(\.zipURLs)
        guard !urls.isEmpty else {
            status = L("Collection is empty")
            return
        }
        do {
            let folder = try resolveMarkdownFolder()
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let out = folder.appendingPathComponent("DigUp-WeChat-\(stamp)", isDirectory: true)
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            var allRecords: [WeChatTranscriptRecord] = []
            var title = "微信转发合集"
            var media: [String] = []
            for (index, zip) in urls.enumerated() {
                let data = try Data(contentsOf: zip, options: .mappedIfSafe)
                let extract = out.appendingPathComponent("batch-\(index + 1)", isDirectory: true)
                try FileManager.default.createDirectory(at: extract, withIntermediateDirectories: true)
                let names = try WeChatForwardZIP.extract(data, to: extract)
                media += names.filter { !$0.lowercased().hasSuffix(".txt") }.map { "batch-\(index + 1)/\($0)" }
                if let transcript = try WeChatForwardZIP.transcript(data) {
                    if index == 0 {
                        title = (transcript.path as NSString).deletingPathExtension
                    }
                    allRecords += transcript.records ?? []
                }
            }
            let md = WeChatMarkdownExport.render(
                title: title,
                records: allRecords,
                body: "",
                mediaRelativePaths: media
            )
            try md.write(to: out.appendingPathComponent(WeChatMarkdownExport.fileName), atomically: true, encoding: .utf8)
            NSWorkspace.shared.activateFileViewerSelecting([out])
            status = L("Markdown exported")
        } catch {
            status = error.localizedDescription
        }
    }

    private func resolveMarkdownFolder() throws -> URL {
        if let bookmark = prefs.markdownFolderBookmark {
            var stale = false
            let url = try URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
            _ = url.startAccessingSecurityScopedResource()
            if stale {
                prefs.markdownFolderBookmark = try url.bookmarkData(
                    options: .withSecurityScope,
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
                prefs.save()
            }
            return url
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = L("Choose Obsidian folder")
        guard panel.runModal() == .OK, let url = panel.url else {
            throw NSError(
                domain: "DigUpPlus.Share",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: L("Cancelled")]
            )
        }
        prefs.markdownFolderBookmark = try url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        prefs.save()
        return url
    }
}

struct WeChatShareShelfView: View {
    @ObservedObject var model: WeChatShareShelfModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Collect multiple WeChat forwards (100+), then deliver once."))
                .font(.callout)
                .foregroundStyle(.secondary)
            if model.rows.isEmpty {
                Text(L("Shelf is empty — use「暂存到 DigUp Plus」in WeChat share menu."))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                List(model.rows) { row in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.title).font(.headline)
                        Text(row.detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .listStyle(.inset)
            }
            if !model.status.isEmpty {
                Text(model.status).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button(L("Deliver to Claude")) { model.deliver(to: .claude) }
                Button(L("Deliver to Codex")) { model.deliver(to: .codex) }
            }
            HStack {
                Button(L("Export Markdown / Obsidian")) { model.exportMarkdown() }
                Spacer()
                Button(L("Clear"), role: .destructive) { model.clear() }
            }
        }
        .padding(14)
        .frame(minWidth: 340, minHeight: 380)
        .onAppear { model.reload() }
    }
}
