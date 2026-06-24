import ServiceManagement

/// Launch-at-login via the modern ServiceManagement API (macOS 13+).
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func setEnabled(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() }
            else if isEnabled { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("SessionMaster: login-item toggle failed: \(error)")
        }
    }
}
