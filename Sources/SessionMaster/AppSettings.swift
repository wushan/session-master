import Foundation
import Observation

/// User preferences, persisted in UserDefaults. Shared singleton read by the store + views.
@MainActor
@Observable
final class AppSettings {
    static let shared = AppSettings()

    enum Editor: String, CaseIterable, Identifiable {
        case vscode = "VS Code", cursor = "Cursor", zed = "Zed"
        case sublime = "Sublime Text", xcode = "Xcode", custom = "Custom command…"
        var id: String { rawValue }
        /// macOS app name for `open -a`, or nil for the custom command.
        var appName: String? {
            switch self {
            case .vscode: return "Visual Studio Code"
            case .cursor: return "Cursor"
            case .zed: return "Zed"
            case .sublime: return "Sublime Text"
            case .xcode: return "Xcode"
            case .custom: return nil
            }
        }
    }

    /// Menu-bar icon options. "rings" is the custom three-circle glyph (matches the app icon);
    /// the rest are SF Symbols.
    static let menuBarIcons = [
        MenuBarIcons.ringsID, "bubble.left.and.bubble.right.fill", "square.stack.3d.up.fill",
        "rectangle.3.group.fill", "point.3.filled.connected.trianglepath.dotted", "waveform.path.ecg",
    ]
    var menuBarIcon: String { didSet { d.set(menuBarIcon, forKey: "menuBarIcon") } }

    var editor: Editor { didSet { d.set(editor.rawValue, forKey: "editor") } }
    /// e.g. `nvim` or `idea` — `{path}` is substituted, else the path is appended.
    var customEditorCommand: String { didSet { d.set(customEditorCommand, forKey: "customEditor") } }
    var soundEnabled: Bool { didSet { d.set(soundEnabled, forKey: "sound") } }
    var notificationsEnabled: Bool { didSet { d.set(notificationsEnabled, forKey: "notifications") } }
    /// Keep the dashboard window floating above other apps' windows so the session list stays visible.
    var dashboardAlwaysOnTop: Bool { didSet { d.set(dashboardAlwaysOnTop, forKey: "alwaysOnTop") } }

    private let d = UserDefaults.standard
    private init() {
        menuBarIcon = d.string(forKey: "menuBarIcon") ?? AppSettings.menuBarIcons[0]
        editor = Editor(rawValue: d.string(forKey: "editor") ?? "") ?? .vscode
        customEditorCommand = d.string(forKey: "customEditor") ?? ""
        soundEnabled = d.object(forKey: "sound") as? Bool ?? true
        notificationsEnabled = d.object(forKey: "notifications") as? Bool ?? true
        dashboardAlwaysOnTop = d.object(forKey: "alwaysOnTop") as? Bool ?? true
    }
}
