import Foundation

/// Which system Share-menu entry the user picked.
///
/// One `.appex` per entry (macOS builds the menu from signed bundles). All DigUp
/// share extensions run the same binary and differ only by `DUShareAction` in
/// their Info.plist — same pattern as Dukou (MIT, qzz0518/Dukou).
public enum ShareAction: String, Codable, Sendable, CaseIterable {
    case shelf
    case codex
    case claude
    case clipboard
    case custom

    public static let infoDictionaryKey = "DUShareAction"

    public static var declared: ShareAction {
        let raw = Bundle.main.object(forInfoDictionaryKey: infoDictionaryKey) as? String
        return raw.flatMap(ShareAction.init(rawValue:)) ?? .shelf
    }

    public var targetBundleIdentifier: String? {
        switch self {
        case .codex: return "com.openai.codex"
        case .claude: return "com.anthropic.claudefordesktop"
        case .shelf, .clipboard, .custom: return nil
        }
    }

    public var needsIntent: Bool {
        switch self {
        case .shelf, .clipboard: return false
        case .codex, .claude, .custom: return true
        }
    }

    public var targetDisplayName: String {
        switch self {
        case .shelf: return L10n.text("暂存架")
        case .codex: return L10n.text("Codex")
        case .claude: return L10n.text("Claude")
        case .clipboard: return L10n.text("剪贴板")
        case .custom: return L10n.text("所选应用")
        }
    }

    public var entryTitle: String {
        switch self {
        case .shelf: return L10n.text("暂存到 DigUp Plus")
        case .codex, .claude: return L10n.format("发给 %@", targetDisplayName)
        case .clipboard: return L10n.text("复制到剪贴板")
        case .custom: return L10n.text("发送到自定义")
        }
    }

    public var bundleIdentifierSuffix: String {
        switch self {
        case .shelf: return "Share"
        case .codex: return "ShareCodex"
        case .claude: return "ShareClaude"
        case .clipboard: return "ShareClipboard"
        case .custom: return "ShareCustom"
        }
    }
}

public struct BatchIntent: Codable, Sendable, Hashable {
    public static let fileName = "intent.json"
    public static let currentSchemaVersion = 1
    public static let freshnessWindow: TimeInterval = 90

    public let schemaVersion: Int
    public let action: ShareAction
    public let requestedAt: Date
    public let targetBundleIdentifier: String?
    public let targetDisplayName: String?

    public init(
        action: ShareAction,
        requestedAt: Date,
        targetBundleIdentifier: String? = nil,
        targetDisplayName: String? = nil,
        schemaVersion: Int = currentSchemaVersion
    ) {
        self.schemaVersion = schemaVersion
        self.action = action
        self.requestedAt = requestedAt
        self.targetBundleIdentifier = targetBundleIdentifier ?? action.targetBundleIdentifier
        self.targetDisplayName = targetDisplayName ?? action.targetDisplayName
    }

    public func isFresh(now: Date = Date()) -> Bool {
        now.timeIntervalSince(requestedAt) < Self.freshnessWindow
    }
}
