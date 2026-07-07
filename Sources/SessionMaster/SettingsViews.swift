import SwiftUI
import AppKit
import SessionCore

// MARK: - Config

struct ConfigView: View {
    @Bindable var settings = AppSettings.shared
    let store: SessionStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                caption("Behavior")
                group {
                    dropdownRow("chevron.left.forwardslash.chevron.right", "Editor",
                                settings.editor.rawValue) {
                        Picker("", selection: $settings.editor) {
                            ForEach(AppSettings.Editor.allCases) { Text($0.rawValue).tag($0) }
                        }
                    }
                    if settings.editor == .custom {
                        rowDivider
                        HStack {
                            Text("Command").font(.system(size: 13)).foregroundStyle(.secondary)
                            TextField("nvim {path}", text: $settings.customEditorCommand)
                                .textFieldStyle(.roundedBorder).font(.system(size: 12))
                        }.padding(.horizontal, 12).padding(.vertical, 8)
                    }
                    rowDivider
                    dropdownRow("terminal", "Resume terminal", settings.resumeTerminal.rawValue) {
                        Picker("", selection: $settings.resumeTerminal) {
                            ForEach(TerminalApp.allCases) { Text($0.rawValue).tag($0) }
                        }
                    }
                }

                caption("Menu bar")
                group { iconPickerRow }

                caption("Alerts")
                group {
                    toggleRow("bolt.fill", "Sound", $settings.soundEnabled)
                    rowDivider
                    toggleRow("bell", "Notifications", $settings.notificationsEnabled)
                    rowDivider
                    toggleRow("macwindow.on.rectangle", "Confirm Desktop resume", $settings.confirmDesktopResume)
                }

                caption("System")
                group {
                    toggleRow(nil, "Launch at login", Binding(
                        get: { store.launchAtLogin }, set: { _ in store.toggleLaunchAtLogin() }))
                    rowDivider
                    toggleRow(nil, "Always on top", $settings.dashboardAlwaysOnTop)
                }

                HStack {
                    Text("v\(Updater.currentVersion)").font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Button("Quit SessionMaster") { NSApp.terminate(nil) }
                        .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Color.sage).pointerCursor()
                }.padding(.horizontal, 14).padding(.top, 6)
            }
            .padding(.horizontal, 8).padding(.vertical, 10)
        }
    }

    // MARK: building blocks

    private func caption(_ t: String) -> some View {
        Text(t.uppercased()).font(.system(size: 9.5, weight: .semibold)).tracking(0.9)
            .foregroundStyle(.tertiary).padding(.leading, 12).padding(.top, 8).padding(.bottom, 2)
    }

    @ViewBuilder private func group<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
    }

    private var rowDivider: some View {
        Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 1).padding(.leading, 12)
    }

    private func dropdownRow<P: View>(_ icon: String, _ label: String, _ value: String,
                                      @ViewBuilder _ picker: () -> P) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon).font(.system(size: 13)).foregroundStyle(.secondary).frame(width: 16)
            Text(label).font(.system(size: 14))
            Spacer()
            Menu {
                picker().labelsHidden().pickerStyle(.inline)
            } label: {
                HStack(spacing: 4) {
                    Text(value).font(.system(size: 13)).foregroundStyle(Color.sage)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 9)).foregroundStyle(.tertiary)
                }
            }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().pointerCursor()
        }.padding(.horizontal, 12).frame(height: 44)
    }

    private func toggleRow(_ icon: String?, _ label: String, _ binding: Binding<Bool>) -> some View {
        HStack(spacing: 9) {
            if let icon {
                Image(systemName: icon).font(.system(size: 13)).foregroundStyle(.secondary).frame(width: 16)
            }
            Text(label).font(.system(size: 14))
            Spacer()
            Toggle("", isOn: binding).labelsHidden().toggleStyle(.switch).tint(.sage).controlSize(.small)
        }.padding(.horizontal, 12).frame(height: 44)
    }

    private var iconPickerRow: some View {
        HStack(spacing: 9) {
            Text("Icon").font(.system(size: 14))
            Spacer()
            HStack(spacing: 6) {
                ForEach(AppSettings.menuBarIcons, id: \.self) { id in
                    let on = settings.menuBarIcon == id
                    Button { settings.menuBarIcon = id } label: {
                        Group {
                            if id == MenuBarIcons.ringsID { Image(nsImage: MenuBarIcons.rings) }
                            else { Image(systemName: id).font(.system(size: 15)) }
                        }
                        .frame(width: 30, height: 26)
                        .foregroundStyle(on ? Color.sage : .secondary)
                        .background(RoundedRectangle(cornerRadius: 7)
                            .fill(on ? Color.sage.opacity(0.14) : .clear))
                        .overlay(RoundedRectangle(cornerRadius: 7)
                            .strokeBorder(on ? Color.sage : .clear, lineWidth: 1))
                    }.buttonStyle(.plain).pointerCursor()
                }
            }
        }.padding(.horizontal, 12).frame(height: 48)
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
          echo; echo "✅ Updated — relaunching SessionMaster…"
          pkill -f "SessionMaster.app/Contents/MacOS/SessionMaster" 2>/dev/null
          sleep 1
          open -a SessionMaster
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
