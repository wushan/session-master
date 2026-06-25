import SwiftUI
import AppKit
import SessionCore

// MARK: - Config

struct ConfigView: View {
    @Bindable var settings = AppSettings.shared
    let store: SessionStore

    var body: some View {
        Form {
            Section("Menu-bar icon") {
                Picker("Icon", selection: $settings.menuBarIcon) {
                    ForEach(AppSettings.menuBarIcons, id: \.self) { id in
                        Group {
                            if id == MenuBarIcons.ringsID { Image(nsImage: MenuBarIcons.rings) }
                            else { Image(systemName: id) }
                        }.tag(id)
                    }
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
            Section("Dashboard") {
                Toggle("Keep dashboard always on top", isOn: $settings.dashboardAlwaysOnTop)
                Text("Floats the dashboard window above other apps so the session list stays visible.")
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
            appIcon
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

    @ViewBuilder private var appIcon: some View {
        let img = Bundle.main.url(forResource: "AppIcon", withExtension: "icns").flatMap(NSImage.init(contentsOf:))
            ?? NSApp.applicationIconImage
        if let img { Image(nsImage: img).resizable().frame(width: 76, height: 76) }
        else { Image(systemName: "circle.circle").font(.system(size: 44)).foregroundStyle(.tint) }
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

    /// Run the upgrade in a visible Terminal window (a temp `.command`) so you can see brew's
    /// progress and any errors — with `brew update` first so the tap is fresh. Non-blocking; opens
    /// the Releases page as a fallback if the script can't be written.
    static func brewUpgrade() {
        let script = """
        #!/bin/bash
        echo "Updating SessionMaster via Homebrew…"; echo
        if brew update && brew upgrade --cask wushan/tap/session-master; then
          echo; echo "✅ Done — quit and reopen SessionMaster to run the new version."
        else
          echo; echo "❌ Update failed (see above) — or download the .dmg from Releases."
        fi
        """
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("update-sessionmaster.command")
        guard (try? script.write(to: url, atomically: true, encoding: .utf8)) != nil else {
            openReleases(); return
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        NSWorkspace.shared.open(url)
    }

    static func openReleases() {
        NSWorkspace.shared.open(URL(string: "https://github.com/wushan/session-master/releases")!)
    }
}
