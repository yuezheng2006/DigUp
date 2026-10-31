import AppKit
import DigUpShareCore
import SwiftUI
import UniformTypeIdentifiers

/// Settings → WeChat Share: entry switches, prompts, custom apps, Markdown folder.
struct WeChatShareSettings: View {
    @StateObject private var probe = ShareEntryProbe()
    @State private var prefs = SharePreferences.load()
    @State private var newPrompt = ""
    @State private var folderLabel = ""

    var body: some View {
        Form {
            Section {
                Text(L("WeChat 4.1.13+ → merge forward → Forward to other apps. DigUp Plus entries appear in that menu."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section(L("Share menu entries")) {
                ForEach(ShareAction.allCases, id: \.self) { action in
                    Toggle(isOn: Binding(
                        get: { probe.isOn(action) },
                        set: { probe.setEnabled($0, for: action) }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(action.entryTitle)
                            if probe.states[action] == .unregistered {
                                Text(L("Not registered — rebuild/install DigUp.app first"))
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                    .disabled(probe.isSwitching(action) || probe.states[action] == .unregistered)
                }
                Button(L("Open System Settings…")) {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }

            Section {
                Toggle(L("Shelf collects only (for 100+ batching)"), isOn: $prefs.collectOnlyOnShelf)
                Toggle(L("Attach prompt when delivering to AI"), isOn: $prefs.attachPromptToForwards)
            } header: {
                Text(L("Collection"))
            } footer: {
                Text(L("Turn on shelf-collect, forward several WeChat batches to「暂存」, then open the shelf to deliver once or export Markdown."))
            }

            Section(L("Prompt templates")) {
                Picker(L("Active prompt"), selection: Binding(
                    get: { prefs.selectedPromptID ?? prefs.prompts.first?.id },
                    set: { prefs.selectedPromptID = $0 }
                )) {
                    ForEach(prefs.prompts) { prompt in
                        Text(prompt.text.prefix(36) + (prompt.text.count > 36 ? "…" : ""))
                            .tag(Optional(prompt.id))
                    }
                }
                ForEach(prefs.prompts) { prompt in
                    Text(prompt.text)
                        .font(.caption)
                        .textSelection(.enabled)
                }
                HStack {
                    TextField(L("New prompt"), text: $newPrompt, axis: .vertical)
                        .lineLimit(2...4)
                    Button(L("Add")) {
                        let text = newPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty, prefs.prompts.count < SharePreferences.maximumPrompts else { return }
                        let prompt = AttachedPrompt(text: text)
                        prefs.prompts.append(prompt)
                        prefs.selectedPromptID = prompt.id
                        newPrompt = ""
                        save()
                    }
                    .disabled(newPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || prefs.prompts.count >= SharePreferences.maximumPrompts)
                }
                Button(L("Reset default prompts")) {
                    prefs.prompts = SharePreferences.defaultPrompts()
                    prefs.selectedPromptID = prefs.prompts.first?.id
                    save()
                }
            }

            Section(L("Custom「发送到自定义」apps")) {
                ForEach(prefs.customTargets) { target in
                    HStack {
                        Text(target.displayName)
                        Spacer()
                        Text(target.bundleIdentifier)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button(role: .destructive) {
                            prefs.customTargets.removeAll { $0.id == target.id }
                            save()
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                Button(L("Add application…")) { addCustomApp() }
            }

            Section(L("Markdown / Obsidian folder")) {
                Text(folderLabel.isEmpty ? L("Not set — chosen on first export") : folderLabel)
                    .foregroundStyle(folderLabel.isEmpty ? .secondary : .primary)
                Button(L("Choose folder…")) { chooseMarkdownFolder() }
            }

            Section {
                Button(L("Open share shelf…")) {
                    WeChatShareShelfController.shared.show()
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            probe.refresh()
            prefs = SharePreferences.load()
            refreshFolderLabel()
        }
        .onChange(of: prefs.collectOnlyOnShelf) { _, _ in save() }
        .onChange(of: prefs.attachPromptToForwards) { _, _ in save() }
        .onChange(of: prefs.selectedPromptID) { _, _ in save() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            probe.refresh()
        }
    }

    private func save() {
        prefs.normalize()
        prefs.save()
    }

    private func addCustomApp() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = L("Add")
        guard panel.runModal() == .OK, let url = panel.url,
              let bundle = Bundle(url: url),
              let id = bundle.bundleIdentifier
        else { return }
        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        prefs.customTargets.removeAll { $0.bundleIdentifier == id }
        prefs.customTargets.append(ForwardTarget(bundleIdentifier: id, displayName: name))
        prefs.lastCustomBundleID = id
        save()
    }

    private func chooseMarkdownFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.prompt = L("Choose Obsidian folder")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        prefs.markdownFolderBookmark = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        save()
        refreshFolderLabel()
    }

    private func refreshFolderLabel() {
        guard let data = prefs.markdownFolderBookmark else {
            folderLabel = ""
            return
        }
        var stale = false
        if let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale) {
            folderLabel = url.path
        } else {
            folderLabel = ""
        }
    }
}
