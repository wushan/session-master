import Foundation

/// Minimal TOML reader for the FLAT, generated `automation.toml` files (no nested tables).
/// Handles: double-quoted strings (with \n \t \" \\ escapes), ints, bools, string arrays.
public enum TOMLLite {
    public static func parse(_ text: String) -> [String: Any] {
        var out: [String: Any] = [:]
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix("[") { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let val = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { out[key] = value(val) }
        }
        return out
    }

    static func value(_ s: String) -> Any {
        if s.hasPrefix("\"") { return unquote(s) }
        if s.hasPrefix("[") { return array(s) }
        if s == "true" { return true }
        if s == "false" { return false }
        if let i = Int(s) { return i }
        if let d = Double(s) { return d }
        return s
    }

    static func unquote(_ s: String) -> String {
        var result = ""; var started = false; var escaped = false
        for ch in s {
            if !started { if ch == "\"" { started = true }; continue }
            if escaped {
                switch ch {
                case "n": result.append("\n"); case "t": result.append("\t")
                case "\"": result.append("\""); case "\\": result.append("\\")
                default: result.append(ch)
                }
                escaped = false
            } else if ch == "\\" { escaped = true }
            else if ch == "\"" { break }
            else { result.append(ch) }
        }
        return result
    }

    static func array(_ s: String) -> [String] {
        guard let l = s.firstIndex(of: "["), let r = s.lastIndex(of: "]"), l < r else { return [] }
        // Split on commas, but not on commas inside a quoted string (paths can contain commas).
        var items: [String] = []
        var current = ""; var inString = false; var escaped = false
        for ch in s[s.index(after: l)..<r] {
            if escaped { current.append(ch); escaped = false }
            else if inString && ch == "\\" { current.append(ch); escaped = true }
            else if ch == "\"" { inString.toggle(); current.append(ch) }
            else if ch == "," && !inString {
                let v = unquote(current.trimmingCharacters(in: .whitespaces))
                if !v.isEmpty { items.append(v) }
                current = ""
            } else { current.append(ch) }
        }
        let v = unquote(current.trimmingCharacters(in: .whitespaces))
        if !v.isEmpty { items.append(v) }
        return items
    }
}
