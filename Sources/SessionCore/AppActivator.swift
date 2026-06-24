import AppKit

/// Brings apps to the foreground — used for Desktop sessions (no terminal window to raise).
public enum AppActivator {
    public static func bringToFront(appNamed name: String) {
        Shell.run("/usr/bin/open", ["-a", name])
    }

    @discardableResult
    public static func activate(pid: pid_t) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
        return app.activate()
    }
}
