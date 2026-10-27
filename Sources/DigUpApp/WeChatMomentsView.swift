import SwiftUI
import DigUpKit

struct WeChatView: View {
    @Bindable var state: WeChatState
    @AppStorage("wechat.riskNoticeDismissed") private var riskNoticeDismissed = false
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer(minLength: 0)
                Picker(L("WeChat"), selection: $state.showsMoments) {
                    Text(L("Conversations")).tag(false)
                    Text(L("Moments feed")).tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 220)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 4)
            if !riskNoticeDismissed {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                    Text(L("WeChat risk notice body"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button(L("Got it")) { riskNoticeDismissed = true }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.secondary.opacity(0.08))
                .padding(.horizontal, 10)
                .padding(.bottom, 4)
                .accessibilityLabel(L("WeChat risk notice body"))
            }
            if state.showsMoments { WeChatMomentsView() } else { WeChatChatsView(state: state) }
        }
    }
}

@MainActor @Observable
final class WeChatMomentsState {
    var items: [WeChatMoment] = []
    var directory: [WeChatMoment] = []
    var profiles = WeChatProfiles()
    var selected = ""
    var peopleQuery = ""
    var hideAds = true
    var hideEnterprise = true
    var blocked = Set(UserDefaults.standard.stringArray(forKey: "moments.hiddenAuthors") ?? [])
    var allowed = Set(UserDefaults.standard.stringArray(forKey: "moments.allowedAuthors") ?? [])
    var showHidden = false
    func hide(_ id: String) {
        blocked.insert(id); allowed.remove(id); saveFilters()
    }
    func allow(_ id: String) {
        blocked.remove(id); allowed.insert(id); saveFilters()
    }
    func saveFilters() {
        UserDefaults.standard.set(Array(blocked), forKey: "moments.hiddenAuthors")
        UserDefaults.standard.set(Array(allowed), forKey: "moments.allowedAuthors")
    }
    func isHidden(_ item: WeChatMoment) -> Bool {
        if item.authorID == profiles.selfID || allowed.contains(item.authorID) { return false }
        return blocked.contains(item.authorID)
            || (hideEnterprise && item.authorID.hasSuffix("@openim"))
            || (hideAds && MomentsFilter.suspectedAdvertisement(item.content))
    }
    var visible: [WeChatMoment] { items.filter { (selected.isEmpty || $0.authorID == selected) && (showHidden || !isHidden($0)) } }
    var authors: [WeChatMoment] {
        var seen = Set<String>()
        return directory.filter { (showHidden || !isHidden($0)) && seen.insert($0.authorID).inserted && (peopleQuery.isEmpty || $0.author.localizedCaseInsensitiveContains(peopleQuery)) }
    }
    func choose(_ id: String) { selected = id; author = id; load() }

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
            let metadata = await Task.detached { WeChatProfiles.load() }.value
            guard token == generation else { return }
            if !metadata.people.isEmpty { profiles = metadata }

            let work = Task.detached {
                try WeChatMomentsProvider(executable: executable).moments(query: query, author: author, since: start, until: end, limit: 100)
            }
            do {
                let result = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                guard token == generation else { return }
                items = result
                if author.isEmpty { directory = result }
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
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Button { state.choose("") } label: {
                    Label(L("All Moments"), systemImage: "square.grid.2x2").frame(maxWidth: .infinity, alignment: .leading)
                }
                Button { if let me = state.profiles.selfID { state.choose(me) } } label: {
                    Label(L("My Moments"), systemImage: "star.fill").fontWeight(.semibold)
                        .frame(maxWidth: .infinity, alignment: .leading).foregroundStyle(Color.accentColor)
                }.disabled(state.profiles.selfID == nil)
                    .help(state.profiles.selfID == nil ? L("Current account could not be identified") : L("My Moments"))
                Divider()
                TextField(L("Find person"), text: $state.peopleQuery)
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(state.authors, id: \.authorID) { person in
                            Button { state.choose(person.authorID) } label: {
                                HStack(spacing: 8) {
                                    MomentsImage(url: state.profiles.people[person.authorID]?.avatar, avatar: true)
                                        .frame(width: 36, height: 36).clipShape(Circle())
                                    Text(person.author).lineLimit(2).multilineTextAlignment(.leading)
                                    Spacer(minLength: 0)
                                }.padding(7).background(state.selected == person.authorID ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8))
                            }.buttonStyle(.plain)
                        }
                    }
                }
                Toggle(L("Hide suspected ads"), isOn: $state.hideAds)
                Toggle(L("Hide enterprise accounts"), isOn: $state.hideEnterprise)
                Toggle(L("Show hidden posts"), isOn: $state.showHidden)
            }.padding(12).frame(width: 210)
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(state.selected == state.profiles.selfID ? L("My Moments") : state.items.first?.author == nil || state.selected.isEmpty ? L("Moments feed") : state.items.first!.author)
                        .font(.headline)
                    Spacer()
                    Text(L("Cached posts")).font(.caption).foregroundStyle(.secondary)
                        .help(L("Local Moments cache · up to 100 posts"))
                }
                HStack {
                    TextField(L("Search Moments"), text: $state.query).onSubmit { state.load() }
                    Button(L("Search")) { state.load() }
                }
                HStack {
                    DatePicker(L("From"), selection: $state.since, displayedComponents: .date)
                    DatePicker(L("Until (exclusive)"), selection: $state.until, displayedComponents: .date)
                }
                if state.busy { ProgressView().controlSize(.small) }
                if let error = state.error { Text(error).foregroundStyle(.red) }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if !state.busy && state.error == nil && state.visible.isEmpty {
                            Text(L("No visible posts. Adjust dates or filters.")).foregroundStyle(.secondary)
                        }
                        ForEach(state.visible) { item in
                            VStack(alignment: .leading, spacing: 9) {
                                HStack {
                                    MomentsImage(url: state.profiles.people[item.authorID]?.avatar, avatar: true)
                                        .frame(width: 28, height: 28).clipShape(Circle())
                                    Text(item.author).font(.headline)
                                    if item.authorID == state.profiles.selfID { Label(L("Me"), systemImage: "star.fill").foregroundStyle(Color.accentColor) }
                                    Spacer()
                                    Menu {
                                        Button(L("Hide this author")) { state.hide(item.authorID) }
                                        Button(L("Always show this author")) { state.allow(item.authorID) }
                                    } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 24)
                                }
                                Text(Date(timeIntervalSince1970: item.timestamp), format: .dateTime.year().month().day().hour().minute())
                                    .font(.caption).foregroundStyle(.secondary)
                                Text(verbatim: item.content).textSelection(.enabled)
                                if !item.media.isEmpty {
                                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 130, maximum: 200))], alignment: .leading, spacing: 6) {
                                        ForEach(Array(item.media.enumerated()), id: \.offset) { _, media in
                                            MomentsImage(url: media.url, media: media)
                                                .frame(height: 140).clipped().clipShape(RoundedRectangle(cornerRadius: 6))
                                        }
                                    }
                                }
                            }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                                .background(item.authorID == state.profiles.selfID ? Color.accentColor.opacity(0.08) : Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                }
            }.padding(16).frame(maxWidth: .infinity)
        }.task { state.load() }.onDisappear { state.cancel() }
    }
}

private struct MomentsImage: View {
    let url: URL?
    var media: WeChatMomentMedia? = nil
    var avatar = false
    @State private var image: NSImage?
    @State private var failed = false
    var body: some View {
        ZStack {
            Color.secondary.opacity(0.08)
            if let image { Image(nsImage: image).resizable().scaledToFit() }
            else if failed || url == nil {
                if avatar { Image(systemName: "person.crop.circle.fill").resizable().scaledToFit().foregroundStyle(.secondary) }
                else { Button(L("Retry image")) { failed = false; Task { await load() } }.buttonStyle(.plain).font(.caption) }
            } else { ProgressView().controlSize(.small) }
        }.task(id: url) { await load() }
    }
    private func load() async {
        guard let url else { return }
        image = nil; failed = false
        do {
            let data = try await WeChatMedia.image(url: url, media: media)
            try Task.checkCancellation()
            image = NSImage(data: data); failed = image == nil
        } catch { if !Task.isCancelled { failed = true } }
    }
}
