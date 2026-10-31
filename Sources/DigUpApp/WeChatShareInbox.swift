import AppKit
import DigUpShareCore
import Foundation

/// Watches DigUp Plus App Group inbox for WeChat 「合并转发」 share batches.
@MainActor
final class WeChatShareInboxController {
    static let shared = WeChatShareInboxController()

    private var observer: NSObjectProtocol?
    private var seenBatchIDs = Set<UUID>()
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        observer = DistributedNotificationCenter.default().addObserver(
            forName: InboxSignal.didChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.scan() }
        }
        scan()
    }

    func scan() {
        guard let inbox = try? Inbox.resolve() else { return }
        let reader = InboxReader(inbox: inbox)
        for failure in reader.consumeFailures() {
            presentAlert(title: L("WeChat Share"), message: failure.message)
        }
        for batch in reader.listReady() {
            guard !seenBatchIDs.contains(batch.id) else { continue }
            seenBatchIDs.insert(batch.id)
            handle(batch: batch, reader: reader)
        }
    }

    private func handle(batch: ReadyBatch, reader: InboxReader) {
        let urls = batch.itemURLs()
        let intent = reader.consumeIntent(in: batch) ?? batch.intent
        let prefs = SharePreferences.load()

        // 「暂存」：收入分批暂存架（突破 100 条），默认不抢开浏览器。
        if batch.manifest.action == .shelf || intent?.action == .shelf {
            SharePreferences.appendCollectionID(batch.id)
            WeChatShareShelfController.shared.show()
            WeChatShareShelfController.shared.refresh()
            if !prefs.collectOnlyOnShelf {
                openPreview(urls: urls, batchID: batch.id)
            }
            return
        }

        openPreview(urls: urls, batchID: batch.id)

        guard let intent, intent.isFresh() else { return }
        switch intent.action {
        case .shelf:
            break
        case .clipboard:
            FilePasteboard.write(urls)
        case .claude, .codex, .custom:
            deliver(urls: urls, action: intent.action, prefs: prefs, intent: intent)
        }
    }

    private func deliver(urls: [URL], action: ShareAction, prefs: SharePreferences, intent: BatchIntent) {
        if let prompt = prefs.promptTextForForward() {
            // Prompt first as plain text; apps that accept files still get paths in the same paste as a fallback note.
            let note = prompt + "\n\n" + urls.map(\.path).joined(separator: "\n")
            FilePasteboard.writeText(note)
            // Also put file URLs for apps that prefer file paste.
            let pb = NSPasteboard.general
            pb.declareTypes([.string, .fileURL], owner: nil)
            pb.setString(note, forType: .string)
            _ = pb.writeObjects(urls.map { $0 as NSURL })
        } else {
            FilePasteboard.write(urls)
        }

        let bundleID = intent.targetBundleIdentifier
            ?? action.targetBundleIdentifier
            ?? prefs.lastCustomBundleID
            ?? prefs.customTargets.first?.bundleIdentifier
        guard let bundleID,
              let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
    }

    private func openPreview(urls: [URL], batchID: UUID) {
        var previewDir: URL?
        for url in urls where url.pathExtension.lowercased() == "zip" {
            if let dir = try? expandPreview(zipURL: url, batchID: batchID) {
                previewDir = dir
                break
            }
        }
        if let previewDir {
            let index = previewDir.appendingPathComponent("index.html")
            if FileManager.default.fileExists(atPath: index.path) {
                NSWorkspace.shared.open(index)
            } else {
                NSWorkspace.shared.activateFileViewerSelecting([previewDir])
            }
        } else if !urls.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }
    }

    private func expandPreview(zipURL: URL, batchID: UUID) throws -> URL {
        let data = try Data(contentsOf: zipURL, options: .mappedIfSafe)
        let transcript = try WeChatForwardZIP.transcript(data)
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("DigUpPlus/SharePreviews/\(batchID.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let extractRoot = support.appendingPathComponent("archive", isDirectory: true)
        try? FileManager.default.removeItem(at: extractRoot)
        try FileManager.default.createDirectory(at: extractRoot, withIntermediateDirectories: true)
        let names = try WeChatForwardZIP.extract(data, to: extractRoot)

        let title = (transcript?.path as NSString?)?.deletingPathExtension
            ?? zipURL.deletingPathExtension().lastPathComponent
        let records = transcript?.records ?? []
        let media = names.filter { !$0.lowercased().hasSuffix(".txt") }
        let html = Self.renderHTML(title: title, records: records, body: transcript?.body ?? "")
        try html.write(to: support.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        if let body = transcript?.body {
            try body.write(to: support.appendingPathComponent("messages.txt"), atomically: true, encoding: .utf8)
        }
        let md = WeChatMarkdownExport.render(
            title: title,
            records: records,
            body: transcript?.body ?? "",
            mediaRelativePaths: media.map { "archive/\($0)" }
        )
        try md.write(to: support.appendingPathComponent(WeChatMarkdownExport.fileName), atomically: true, encoding: .utf8)
        return support
    }

    private static func renderHTML(title: String, records: [WeChatTranscriptRecord], body: String) -> String {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        var bubbles = ""
        if records.isEmpty {
            bubbles = "<pre class=\"raw\">\(esc(body))</pre>"
        } else {
            for record in records {
                bubbles += """
                <div class="row them">
                  <div class="meta">\(esc(formatter.string(from: record.date))) · \(esc(record.sender))</div>
                  <div class="bubble">\(esc(record.text))</div>
                </div>
                """
            }
        }
        return """
        <!doctype html><html lang="zh-Hans"><head><meta charset="utf-8">
        <title>\(esc(title)) · DigUp Plus</title>
        <style>
          body{margin:0;padding:16px;font:14px/1.45 -apple-system,BlinkMacSystemFont,sans-serif;background:#f5f5f7;color:#111}
          h1{font-size:18px;margin:0 0 12px}
          .row{display:flex;flex-direction:column;margin:8px 0;max-width:92%}
          .meta{font-size:11px;color:#888;margin-bottom:2px}
          .bubble{padding:8px 12px;border-radius:14px;background:#fff;border:1px solid #ddd;white-space:pre-wrap;word-break:break-word}
          .raw{white-space:pre-wrap;background:#fff;padding:12px;border-radius:8px;border:1px solid #ddd}
        </style></head><body>
        <h1>\(esc(title)) <span style="color:#888;font-weight:400">· \(records.count) 条 · 微信转发包</span></h1>
        \(bubbles)
        </body></html>
        """
    }

    private func presentAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
}
