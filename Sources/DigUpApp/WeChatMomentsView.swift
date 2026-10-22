import SwiftUI
import DigUpKit

struct WeChatView: View {
    @Bindable var state: WeChatState
    var body: some View {
        VStack(spacing: 0) {
            Picker(L("WeChat"), selection: $state.showsMoments) {
                Text(L("Conversations")).tag(false)
                Text(L("Moments feed")).tag(true)
            }.pickerStyle(.segmented).frame(width: 240).padding(10)
            if state.showsMoments { WeChatMomentsView() } else { WeChatChatsView(state: state) }
        }
    }
}

@MainActor @Observable
final class WeChatMomentsState {
    var items: [WeChatMoment] = []
    var query = ""
    var author = ""
    var since = Calendar.current.date(byAdding: .month, value: -1, to: Date())!
    var until = Calendar.current.date(byAdding: .day, value: 1, to: Date())!
    var busy = false
    var error: String?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    func cancel() { generation = UUID(); task?.cancel(); busy = false }
    func load() {
        cancel(); items = []; error = nil
        guard let executable = WeChatReaderLocation.detect() else {
            error = L("WeChat reader not found. Install and configure wx on this Mac, then detect again."); return
        }
        let format = DateFormatter(); format.dateFormat = "yyyy-MM-dd"
        let start = format.string(from: since), end = format.string(from: until)
        guard start < end else { error = L("Invalid date range"); return }
        busy = true
        let token = generation, query = query.trimmingCharacters(in: .whitespacesAndNewlines), author = author
        task = Task {
            let work = Task.detached {
                try WeChatMomentsProvider(executable: executable).moments(query: query, author: author, since: start, until: end, limit: 100)
            }
            do {
                let result = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                guard token == generation else { return }
                items = result
            } catch {
                guard token == generation else { return }
                self.error = L("Could not read Moments. Check WeChat access and retry.")
            }
            if token == generation { busy = false }
        }
    }
}

struct WeChatMomentsView: View {
    @State private var state = WeChatMomentsState()
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField(L("Search Moments"), text: $state.query).onSubmit { state.load() }
                TextField(L("Author"), text: $state.author).frame(width: 150).onSubmit { state.load() }
                Button(L("Search")) { state.load() }
            }
            HStack {
                DatePicker(L("From"), selection: $state.since, displayedComponents: .date)
                DatePicker(L("Until (exclusive)"), selection: $state.until, displayedComponents: .date)
            }
            Text(L("Local Moments cache · up to 100 posts")).font(.caption).foregroundStyle(.secondary)
            if state.busy { ProgressView().controlSize(.small) }
            if let error = state.error { Text(error).foregroundStyle(.red) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if !state.busy && state.error == nil && state.items.isEmpty {
                        Text(L("No cached Moments in this range")).foregroundStyle(.secondary)
                    }
                    ForEach(state.items) { item in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(item.author).font(.headline)
                                Spacer()
                                Text(Date(timeIntervalSince1970: item.timestamp), format: .dateTime.year().month().day().hour().minute())
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Text(verbatim: item.content).textSelection(.enabled)
                            if item.mediaCount > 0 { Text(L("Media preview unavailable ({0})", item.mediaCount)).font(.caption).foregroundStyle(.secondary) }
                        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
        }.padding(16).task { state.load() }.onDisappear { state.cancel() }
    }
}
