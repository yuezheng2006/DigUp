import Foundation

/// App ↔ share extension shared container id.
///
/// Team-prefixed (`3396ALL92C…`) so Apple Development / Developer ID signing
/// can resolve the group. Override via `DUAppGroupIdentifier` in Info.plist
/// (rewritten by `build.sh`). Must be registered under the signing team in
/// the Apple Developer portal for production installs.
public enum AppGroup {
    public static let infoDictionaryKey = "DUAppGroupIdentifier"
    public static let fallbackIdentifier = "3396ALL92C.group.com.yuezheng.digupplus.shared"

    public static var identifier: String {
        let declared = Bundle.main.object(forInfoDictionaryKey: infoDictionaryKey) as? String
        guard let declared, !declared.isEmpty else { return fallbackIdentifier }
        return declared
    }
}
