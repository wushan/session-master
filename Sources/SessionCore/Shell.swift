import Foundation

/// Minimal helper for running external commands and capturing trimmed stdout.
public enum Shell {
    @discardableResult
    public static func run(_ launchPath: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return p.terminationStatus == 0 ? (s ?? "") : (s?.isEmpty == false ? s : nil)
    }

    public static func osascript(_ source: String) -> String? {
        run("/usr/bin/osascript", ["-e", source])
    }
}
