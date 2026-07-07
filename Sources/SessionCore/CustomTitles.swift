import Foundation

/// User-set custom titles for sessions, keyed by the (stable) session id and persisted in
/// UserDefaults — so you can rename a session to something you'll recognise.
public enum CustomTitles {
    static let key = "customTitles"
    static let lock = NSLock()

    public static func get(_ id: String) -> String? {
        (UserDefaults.standard.dictionary(forKey: key) as? [String: String])?[id]
    }

    /// Session ids the user has explicitly renamed. A rename is a strong "I want to keep this"
    /// signal — used so archiving a Desktop conversation you've taken over and renamed doesn't hide it.
    public static func allIds() -> Set<String> {
        Set((UserDefaults.standard.dictionary(forKey: key) as? [String: String])?.keys ?? [:].keys)
    }

    public static func set(_ title: String?, for id: String) {
        lock.lock(); defer { lock.unlock() }
        var d = (UserDefaults.standard.dictionary(forKey: key) as? [String: String]) ?? [:]
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let t = trimmed, !t.isEmpty { d[id] = t } else { d.removeValue(forKey: id) }
        UserDefaults.standard.set(d, forKey: key)
    }
}
