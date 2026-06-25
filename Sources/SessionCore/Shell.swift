import Foundation

/// Minimal helper for running external commands and capturing trimmed stdout.
public enum Shell {
    @discardableResult
    public static func run(_ launchPath: String, _ args: [String], timeout: TimeInterval = 15) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        let out = Pipe(); p.standardOutput = out
        // Send stderr to /dev/null: we never read it, and an undrained stderr Pipe can fill its
        // buffer and deadlock the child (and the 2s poll) forever.
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        // Watchdog: a hung child (e.g. gh waiting on the network) must not wedge the caller forever.
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler { if p.isRunning { p.terminate() } }
        timer.resume()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        timer.cancel()
        let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return p.terminationStatus == 0 ? (s ?? "") : (s?.isEmpty == false ? s : nil)
    }

    public static func osascript(_ source: String) -> String? {
        run("/usr/bin/osascript", ["-e", source])
    }
}
