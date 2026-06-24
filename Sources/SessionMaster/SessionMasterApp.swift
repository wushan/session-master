import SwiftUI
import AppKit
import SessionCore

@main
struct SessionMasterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(store: delegate.store, floating: delegate.floating)
        } label: {
            MenuBarLabel(store: delegate.store)
        }
        .menuBarExtraStyle(.window)

        Window("SessionMaster", id: "main") {
            MainWindowView(store: delegate.store)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 720, height: 520)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = SessionStore()
    lazy var floating = FloatingPanel(store: store)
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)   // menu-bar only, no Dock icon
        store.start()
        if CommandLine.arguments.contains("--pinned") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in self?.floating.show() }
        }
    }
}

/// Menu-bar label: icon + a count of sessions needing attention / busy.
struct MenuBarLabel: View {
    let store: SessionStore
    @State private var settings = AppSettings.shared
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: settings.menuBarIcon)
            if store.needsApprovalCount > 0 {
                Text("\(store.needsApprovalCount)").foregroundStyle(.red)        // needs approval
            } else if store.awaitingYouCount > 0 {
                Text("\(store.awaitingYouCount)").foregroundStyle(.yellow)        // your turn
            } else if store.workingCount > 0 {
                Text("\(store.workingCount)").foregroundStyle(.secondary)         // working
            }
        }
    }
}

/// Opens the dashboard window and pulls the (accessory) app forward to focus it.
@MainActor
func openDashboard(_ openWindow: OpenWindowAction) {
    openWindow(id: "main")
    NSApp.activate(ignoringOtherApps: true)
}
