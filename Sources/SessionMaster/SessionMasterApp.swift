import SwiftUI
import AppKit
import SessionCore

@main
struct SessionMasterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(store: delegate.store)
        } label: {
            MenuBarLabel(store: delegate.store)
        }
        .menuBarExtraStyle(.window)

        Window("SessionMaster", id: "main") {
            MainWindowView(store: delegate.store)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 430, height: 580)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = SessionStore()
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Single instance: if another copy (same bundle id) is already running, focus it and quit
        // so you don't end up with two menu-bar icons.
        let me = NSRunningApplication.current
        if let other = NSRunningApplication
            .runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "com.sessionmaster.app")
            .first(where: { $0.processIdentifier != me.processIdentifier }) {
            other.activate()
            NSApp.terminate(nil)
            return
        }
        NSApp.setActivationPolicy(.accessory)   // menu-bar only, no Dock icon
        store.start()
    }
}

/// Menu-bar label: icon + a count of sessions needing attention / busy.
struct MenuBarLabel: View {
    let store: SessionStore
    @State private var settings = AppSettings.shared
    var body: some View {
        HStack(spacing: 3) {
            if settings.menuBarIcon == MenuBarIcons.ringsID {
                Image(nsImage: MenuBarIcons.rings)
            } else {
                Image(systemName: settings.menuBarIcon)
            }
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

/// Opens the dashboard window and pulls the (accessory) app forward to focus it. If it was already
/// open on another Space, drag it to the one you're on now and raise it — otherwise clicking
/// Dashboard from another desktop switches Spaces (or looks like nothing happened).
@MainActor
func openDashboard(_ openWindow: OpenWindowAction) {
    openWindow(id: "main")
    NSApp.activate(ignoringOtherApps: true)
    for w in NSApp.windows where w.title == "SessionMaster" {
        w.collectionBehavior.insert(.moveToActiveSpace)
        w.makeKeyAndOrderFront(nil)
    }
}
