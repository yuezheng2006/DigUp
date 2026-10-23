import AppKit
import Observation
import SwiftUI

/// Appearance and accent themes for the Chinese fork. Upstream stays on system look only;
/// this layer is opt-in via Settings and does not alter indexing or search behavior.
enum AppearanceMode: String, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: L("Match System")
        case .light: L("Light")
        case .dark: L("Dark")
        }
    }
}

enum ColorTheme: String, CaseIterable, Identifiable, Sendable {
    case system
    case moss
    case amber
    case slate

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: L("System Accent")
        case .moss: L("Moss")
        case .amber: L("Amber")
        case .slate: L("Slate")
        }
    }

    /// nil keeps the macOS control accent; otherwise SwiftUI `.tint` uses this color.
    var accentColor: Color? {
        switch self {
        case .system: nil
        case .moss: Color(red: 53 / 255, green: 102 / 255, blue: 82 / 255)
        case .amber: Color(red: 242 / 255, green: 162 / 255, blue: 42 / 255)
        case .slate: Color(red: 90 / 255, green: 110 / 255, blue: 130 / 255)
        }
    }
}

@MainActor @Observable
final class AppThemeStore {
    static let shared = AppThemeStore()

    private static let appearanceKey = "appearanceMode"
    private static let colorKey = "colorTheme"

    var appearance: AppearanceMode {
        didSet {
            guard appearance != oldValue else { return }
            AppSettings.defaults.set(appearance.rawValue, forKey: Self.appearanceKey)
            apply()
        }
    }

    var colorTheme: ColorTheme {
        didSet {
            guard colorTheme != oldValue else { return }
            AppSettings.defaults.set(colorTheme.rawValue, forKey: Self.colorKey)
        }
    }

    private init() {
        let defaults = AppSettings.defaults
        appearance = AppearanceMode(rawValue: defaults.string(forKey: Self.appearanceKey) ?? "") ?? .system
        colorTheme = ColorTheme(rawValue: defaults.string(forKey: Self.colorKey) ?? "") ?? .system
    }

    /// Launch-arg `-forceAppearance light|dark` still wins (tests / screenshots).
    func apply() {
        if let forced = UserDefaults.standard.string(forKey: "forceAppearance") {
            switch forced {
            case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
            case "light": NSApp.appearance = NSAppearance(named: .aqua)
            default: break
            }
            return
        }
        switch appearance {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

extension View {
    /// Applies the selected accent theme without touching upstream layout.
    func digupTheme() -> some View {
        DigUpThemed(content: self)
    }
}

private struct DigUpThemed<Content: View>: View {
    @Bindable private var theme = AppThemeStore.shared
    let content: Content

    var body: some View {
        if let accent = theme.colorTheme.accentColor {
            content.tint(accent)
        } else {
            content
        }
    }
}
