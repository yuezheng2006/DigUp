import AppKit
import Observation

/// State the menubar, the panel and the windows share. Engine updates arrive on the main thread.
@Observable
final class AppModel {
    var status = EngineStatus()
    var settings: AppSettings
    var hotkey: KeyCombo?
    let download: ModelDownload
    /// A newer DigUp the daily check found ("0.6.1"), until you open it (`Updates`).
    var updateAvailable: String?

    init(settings: AppSettings, download: ModelDownload) {
        self.settings = settings
        self.download = download
    }

    var hasFolders: Bool { !settings.roots.isEmpty }
    /// Code search is on (there are code folders).
    var hasCode: Bool { !settings.codeRoots.isEmpty }

    /// One line for the menu and the windows: what the index is doing.
    var statusLine: String {
        let status = self.status
        guard hasFolders else { return L("No folders chosen yet") }
        switch status.activity {
        case .starting: return L("Starting…")
        case .failed(let problem): return "⚠︎ \(problem)"
        case .syncing: return L("Checking folders…")
        case .indexing(let done, let total):
            let percent = total > 0 ? Int((Double(done) / Double(total) * 100).rounded(.down)) : 0
            return L("Indexing {0}% · {1} of {2}", percent, done.formatted(), total.formatted())
        case .finishing(let done, let total, let files):
            let percent = total > 0 ? Int((Double(done) / Double(total) * 100).rounded(.down)) : 0
            let which = files > 0 ? L("{0} long {1}", files.formatted(), files == 1 ? L("file") : L("files")) : L("long files")
            return L("Reading the rest of {0} · {1}%", which, percent)
        case .idle:
            if let line = downloadLine { return line }
            if let code = status.code.indexing, code.total > 0 {
                let percent = Int((Double(code.done) / Double(code.total) * 100).rounded(.down))
                return L("Indexing code {0}% · {1} of {2}", percent, code.done.formatted(), code.total.formatted())
            }
            let waiting = L("{0} {1} waiting", status.pending.formatted(), status.pending == 1 ? L("file") : L("files"))
            if status.pending > 0, status.paused { return L("Paused · {0}", waiting) }
            if let until = status.heldUntil, !status.paused {
                // Outside the set hours: what's known to wait, and when indexing starts again.
                let when = L("indexing from {0}", until.formatted(date: .omitted, time: .shortened))
                if status.pending > 0 { return "\(waiting) · \(when)" }
                return L("{0} {1} indexed · {2}", status.searchable.formatted(), status.searchable == 1 ? L("file") : L("files"), when)
            }
            if status.pending > 0, let reason = status.waitingFor { return "\(waiting) · \(reason)" }
            if status.pending > 0 { return L("{0} to be indexed", waiting) }
            if status.unfinished > 0 {
                let rest = L("{0} long {1} to finish", status.unfinished.formatted(), status.unfinished == 1 ? L("file") : L("files"))
                if status.paused { return L("Paused · {0}", rest) }
                if let reason = status.waitingFor { return "\(rest) · \(reason)" }
            }
            return L("{0} {1} indexed", status.searchable.formatted(), status.searchable == 1 ? L("file") : L("files"))
                + (status.paused ? L(" · paused") : "")
        }
    }

    /// While the model isn't there, how its download goes.
    private var downloadLine: String? {
        switch download.phase {
        case .ready: nil
        case .downloading: L("Downloading the model · {0}%", Int(download.fraction * 100))
        case .verifying: L("Checking the model download…")
        case .retrying: L("Model download: waiting for the network")
        case .failed: L("⚠︎ The model download stopped")
        case .needed: status.pending > 0 ? L("The model isn't downloaded yet") : nil
        }
    }

    /// 0…1 for the menubar ring and progress bars: the model download, then an indexing pass or the rest of long files.
    var progress: Double? {
        if download.isActive { return download.fraction }
        switch status.activity {
        case .indexing(let done, let total) where total > 0: return Double(done) / Double(total)
        case .finishing(let done, let total, _) where total > 0: return Double(done) / Double(total)
        case .idle:
            guard let code = status.code.indexing, code.total > 0 else { return nil }
            return Double(code.done) / Double(code.total)
        default: return nil
        }
    }

    /// One line about the code index, for Settings → Code: "812 code files indexed", "Indexing code 42%…".
    var codeStatusLine: String {
        let code = status.code
        guard hasCode else { return L("Code search is off") }
        if !download.isReady { return L("Code is read once the model has downloaded") }
        if let indexing = code.indexing, indexing.total > 0 {
            let percent = Int((Double(indexing.done) / Double(indexing.total) * 100).rounded(.down))
            return L("Indexing code {0}% · {1} of {2}", percent, indexing.done.formatted(), indexing.total.formatted())
        }
        let waiting = code.pending > 0 ? L(" · {0} waiting", code.pending.formatted()) : ""
        if code.pending > 0, status.paused { return L("Paused · {0} code files waiting", code.pending.formatted()) }
        if code.pending > 0, let reason = status.waitingFor { return L("{0} code files waiting · {1}", code.pending.formatted(), reason) }
        if code.pending > 0, let until = status.heldUntil {
            return L("{0} code files waiting · indexing from ", code.pending.formatted())
                + until.formatted(date: .omitted, time: .shortened)
        }
        // Code is read once the other folders have nothing waiting (the helper's order).
        if code.pending > 0, status.pending > 0 {
            let files = L("{0} code {1}", code.pending.formatted(), code.pending == 1 ? L("file") : L("files"))
            return files + L(" waiting · read after your other files")
        }
        return L("{0} code {1} indexed", code.searchable.formatted(), code.searchable == 1 ? L("file") : L("files")) + waiting
    }

    /// A few words for the search bar while results may be incomplete: "Indexing 42%", "Downloading model · 42%".
    var activityBadge: String? {
        if download.isActive { return L("Downloading model · {0}%", Int(download.fraction * 100)) }
        if case .indexing(let done, let total) = status.activity, total > 0 {
            return L("Indexing {0}%", Int(Double(done) / Double(total) * 100))
        }
        if status.paused, status.pending > 0 { return L("Indexing paused") }
        return nil
    }

    /// Why meaning search can't run yet (words still match), or nil.
    var meaningUnavailable: String? {
        guard !download.isReady else { return nil }
        if download.isActive {
            return L("Matching words only until the model has downloaded ({0}%)", Int(download.fraction * 100))
        }
        return L("Matching words only: the model isn't downloaded")
    }

    /// Why results may be incomplete right now, or nil.
    var resultsCaveat: String? {
        if let meaningUnavailable { return meaningUnavailable }
        if case .indexing(let done, let total) = status.activity, total > 0 {
            return L("Still indexing ({0}%): some files aren't in yet", Int(Double(done) / Double(total) * 100))
        }
        if status.pending > 0 {
            return L("{0} {1} indexed yet", status.pending.formatted(), status.pending == 1 ? L("file isn't") : L("files aren't"))
        }
        return nil
    }
}
