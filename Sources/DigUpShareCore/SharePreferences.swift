import Foundation

/// Prompt pasted ahead of WeChat forward files (Claude / Codex / custom).
public struct AttachedPrompt: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var text: String

    public init(id: UUID = UUID(), text: String) {
        self.id = id
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct ForwardTarget: Codable, Hashable, Sendable, Identifiable {
    public let bundleIdentifier: String
    public let displayName: String
    public let addedAt: Date
    public let pastesPathOnly: Bool

    public var id: String { bundleIdentifier }

    public init(
        bundleIdentifier: String,
        displayName: String,
        addedAt: Date = Date(),
        pastesPathOnly: Bool = false
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
        self.addedAt = addedAt
        self.pastesPathOnly = pastesPathOnly
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bundleIdentifier = try container.decode(String.self, forKey: .bundleIdentifier)
        displayName = try container.decode(String.self, forKey: .displayName)
        addedAt = try container.decode(Date.self, forKey: .addedAt)
        pastesPathOnly = try container.decodeIfPresent(Bool.self, forKey: .pastesPathOnly) ?? false
    }
}

/// App-group preferences shared by DigUpShare extensions and DigUpApp.
public struct SharePreferences: Codable, Hashable, Sendable {
    public static let defaultsSuiteKey = "DUSharePreferences"
    public static let collectionKey = "DUShareCollectionBatchIDs"
    public static let maximumPrompts = 5

    public var prompts: [AttachedPrompt]
    public var selectedPromptID: UUID?
    public var attachPromptToForwards: Bool
    public var customTargets: [ForwardTarget]
    public var lastCustomBundleID: String?
    /// When true, 「暂存」只收入暂存架，不自动打开预览；方便分批超过 100 条后再一次投递。
    public var collectOnlyOnShelf: Bool
    /// Bookmark data for Markdown / Obsidian vault folder (security-scoped).
    public var markdownFolderBookmark: Data?

    public init(
        prompts: [AttachedPrompt] = SharePreferences.defaultPrompts(),
        selectedPromptID: UUID? = nil,
        attachPromptToForwards: Bool = true,
        customTargets: [ForwardTarget] = [],
        lastCustomBundleID: String? = nil,
        collectOnlyOnShelf: Bool = true,
        markdownFolderBookmark: Data? = nil
    ) {
        self.prompts = prompts
        self.selectedPromptID = selectedPromptID ?? prompts.first?.id
        self.attachPromptToForwards = attachPromptToForwards
        self.customTargets = customTargets
        self.lastCustomBundleID = lastCustomBundleID
        self.collectOnlyOnShelf = collectOnlyOnShelf
        self.markdownFolderBookmark = markdownFolderBookmark
        normalize()
    }

    public static func defaultPrompts() -> [AttachedPrompt] {
        [
            AttachedPrompt(text: "请总结这段微信聊天：关键结论、待办、未决问题。用中文简短列出。"),
            AttachedPrompt(text: "从对话里提取待办事项，按优先级排列，并标出负责人（如有）。"),
            AttachedPrompt(text: "只处理相对上次转发的新增内容；若无法判断新旧，先说明再总结。"),
        ]
    }

    public var selectedPrompt: AttachedPrompt? {
        prompts.first { $0.id == selectedPromptID } ?? prompts.first
    }

    public mutating func normalize() {
        if prompts.count > Self.maximumPrompts {
            prompts = Array(prompts.prefix(Self.maximumPrompts))
        }
        if selectedPromptID == nil || !prompts.contains(where: { $0.id == selectedPromptID }) {
            selectedPromptID = prompts.first?.id
        }
    }

    public func promptTextForForward() -> String? {
        guard attachPromptToForwards, let text = selectedPrompt?.text, !text.isEmpty else { return nil }
        return text
    }

    // MARK: - Persistence

    public static func load(appGroupIdentifier: String = AppGroup.identifier) -> SharePreferences {
        guard let defaults = UserDefaults(suiteName: appGroupIdentifier),
              let data = defaults.data(forKey: defaultsSuiteKey),
              let decoded = try? BatchManifest.decoder().decode(SharePreferences.self, from: data)
        else { return SharePreferences() }
        return decoded
    }

    public func save(appGroupIdentifier: String = AppGroup.identifier) {
        guard let defaults = UserDefaults(suiteName: appGroupIdentifier),
              let data = try? BatchManifest.encoder().encode(self)
        else { return }
        defaults.set(data, forKey: Self.defaultsSuiteKey)
    }

    // MARK: - Batch collection (multi-forward > 100 msgs)

    public static func collectionIDs(appGroupIdentifier: String = AppGroup.identifier) -> [UUID] {
        guard let defaults = UserDefaults(suiteName: appGroupIdentifier),
              let raw = defaults.array(forKey: collectionKey) as? [String]
        else { return [] }
        return raw.compactMap(UUID.init(uuidString:))
    }

    public static func setCollectionIDs(_ ids: [UUID], appGroupIdentifier: String = AppGroup.identifier) {
        guard let defaults = UserDefaults(suiteName: appGroupIdentifier) else { return }
        defaults.set(ids.map(\.uuidString), forKey: collectionKey)
    }

    public static func appendCollectionID(_ id: UUID, appGroupIdentifier: String = AppGroup.identifier) {
        var ids = collectionIDs(appGroupIdentifier: appGroupIdentifier)
        if !ids.contains(id) { ids.append(id) }
        setCollectionIDs(ids, appGroupIdentifier: appGroupIdentifier)
    }

    public static func clearCollection(appGroupIdentifier: String = AppGroup.identifier) {
        setCollectionIDs([], appGroupIdentifier: appGroupIdentifier)
    }
}
