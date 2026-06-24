import SwiftUI
import AppKit
import UserNotifications
import SessionCore

// MARK: - Config

struct ConfigView: View {
    @Bindable var settings = AppSettings.shared
    let store: SessionStore

    var body: some View {
        Form {
            Section("Menu-bar icon") {
                Picker("Icon", selection: $settings.menuBarIcon) {
                    ForEach(AppSettings.menuBarIcons, id: \.self) { Image(systemName: $0).tag($0) }
                }.pickerStyle(.segmented).labelsHidden()
            }
            Section("Editor") {
                Picker("Open worktrees in", selection: $settings.editor) {
                    ForEach(AppSettings.Editor.allCases) { Text($0.rawValue).tag($0) }
                }
                if settings.editor == .custom {
                    TextField("Command — {path} is the folder, e.g. nvim {path}",
                              text: $settings.customEditorCommand)
                }
            }
            Section("Notifications") {
                Toggle("Notify when a session needs you", isOn: $settings.notificationsEnabled)
                Toggle("Play a sound", isOn: $settings.soundEnabled)
                Text("Fires when a session finishes its turn (your turn) or hits a permission prompt.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Startup") {
                Toggle("⚡ Launch at login", isOn: Binding(
                    get: { store.launchAtLogin }, set: { _ in store.toggleLaunchAtLogin() }))
                Text("The ⚡ in the menu-bar popover toggles this too.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Button("Quit SessionMaster", role: .destructive) { NSApp.terminate(nil) }
                    .pointerCursor()
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - About

struct AboutView: View {
    @State private var latest: String?
    @State private var checking = false

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "square.grid.2x2.fill").font(.system(size: 44)).foregroundStyle(.tint)
            Text("SessionMaster").font(.title.bold())
            Text("Version \(Updater.currentVersion)").foregroundStyle(.secondary)

            updateRow

            Divider().padding(.vertical, 4)
            Text("One live console for every Claude Code & Codex session.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            HStack(spacing: 14) {
                Link("GitHub", destination: URL(string: "https://github.com/wushan/session-master")!)
                Link("Releases", destination: URL(string: "https://github.com/wushan/session-master/releases")!)
                Text("MIT License").foregroundStyle(.secondary)
            }.font(.caption)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
        .task { await check() }
    }

    @ViewBuilder private var updateRow: some View {
        if checking {
            ProgressView().controlSize(.small)
        } else if let latest, Updater.isNewer(latest, than: Updater.currentVersion) {
            VStack(spacing: 6) {
                Text("Update available: \(latest)").font(.subheadline.weight(.semibold)).foregroundStyle(.orange)
                HStack {
                    Button("Update via Homebrew") { Updater.brewUpgrade() }.buttonStyle(.borderedProminent)
                    Button("Open release") { Updater.openReleases() }.buttonStyle(.bordered)
                }.pointerCursor()
            }
        } else {
            HStack(spacing: 8) {
                Text(latest == nil ? "Couldn’t check" : "Up to date").font(.caption).foregroundStyle(.secondary)
                Button("Check again") { Task { await check() } }.buttonStyle(.link).pointerCursor()
            }
        }
    }

    private func check() async {
        checking = true
        latest = await Updater.latest()
        checking = false
    }
}

// MARK: - Updater

enum Updater {
    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    static func latest() async -> String? {
        guard let url = URL(string: "https://api.github.com/repos/wushan/session-master/releases/latest"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = j["tag_name"] as? String else { return nil }
        return tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
    }

    /// Semantic-ish compare of dotted version strings.
    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    static func brewUpgrade() {
        Shell.run("/bin/sh", ["-lc", "brew upgrade --cask wushan/tab/session-master"])
        let c = UNMutableNotificationContent()
        c.title = "SessionMaster updated"; c.body = "Quit and reopen to run the new version."
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }

    static func openReleases() {
        NSWorkspace.shared.open(URL(string: "https://github.com/wushan/session-master/releases")!)
    }
}
