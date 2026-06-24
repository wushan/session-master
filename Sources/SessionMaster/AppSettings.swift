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

    var editor: Editor { didSet { d.set(editor.rawValue, forKey: "editor") } }
    /// e.g. `nvim` or `idea` — `{path}` is substituted, else the path is appended.
    var customEditorCommand: String { didSet { d.set(customEditorCommand, forKey: "customEditor") } }
    var soundEnabled: Bool { didSet { d.set(soundEnabled, forKey: "sound") } }
    var notificationsEnabled: Bool { didSet { d.set(notificationsEnabled, forKey: "notifications") } }

    private let d = UserDefaults.standard
    private init() {
        editor = Editor(rawValue: d.string(forKey: "editor") ?? "") ?? .vscode
        customEditorCommand = d.string(forKey: "customEditor") ?? ""
        soundEnabled = d.object(forKey: "sound") as? Bool ?? true
        notificationsEnabled = d.object(forKey: "notifications") as? Bool ?? true
    }
}
