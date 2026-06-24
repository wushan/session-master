import Foundation

/// Minimal iCalendar RRULE evaluator — enough for the cron-style rules Codex emits
/// (FREQ=WEEKLY/HOURLY/DAILY with BYDAY/BYHOUR/BYMINUTE). Next run is found by a bounded
/// per-minute forward scan, which is simple and correct for these constraint-based rules.
public struct RRule: Sendable {
    public var freq: String?
    public var byHour: [Int] = []
    public var byMinute: [Int] = []
    public var byDay: [Int] = []     // Calendar weekday: 1=Sun … 7=Sat
    public var interval = 1

    public static func parse(_ s: String) -> RRule {
        var r = RRule()
        let body = s.replacingOccurrences(of: "RRULE:", with: "")
        for part in body.split(separator: ";") {
            let kv = part.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            let v = String(kv[1])
            switch kv[0].uppercased() {
            case "FREQ": r.freq = v.uppercased()
            case "INTERVAL": r.interval = Int(v) ?? 1
            case "BYHOUR": r.byHour = v.split(separator: ",").compactMap { Int($0) }
            case "BYMINUTE": r.byMinute = v.split(separator: ",").compactMap { Int($0) }
            case "BYDAY": r.byDay = v.split(separator: ",").compactMap { weekday(String($0)) }
            default: break
            }
        }
        return r
    }

    static func weekday(_ s: String) -> Int? {
        ["SU": 1, "MO": 2, "TU": 3, "WE": 4, "TH": 5, "FR": 6, "SA": 7][s.uppercased()]
    }

    /// Next matching time by a bounded per-minute scan. NOTE: `INTERVAL` is not honored
    /// (every-N-weeks/hours needs a DTSTART anchor the rule doesn't carry); INTERVAL>1 rules
    /// therefore report the next BY* match, which can be earlier than the true occurrence.
    public func nextRun(after date: Date = Date(), calendar cal: Calendar = .current) -> Date? {
        let comps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        guard let truncated = cal.date(from: comps) else { return nil }
        var t = truncated.addingTimeInterval(60)               // start at the next whole minute
        for _ in 0..<(8 * 24 * 60) {                            // search up to 8 days
            let c = cal.dateComponents([.weekday, .hour, .minute], from: t)
            let okMin = byMinute.isEmpty || byMinute.contains(c.minute ?? -1)
            let okHour = byHour.isEmpty || byHour.contains(c.hour ?? -1)
            let okDay = byDay.isEmpty || byDay.contains(c.weekday ?? -1)
            if okMin && okHour && okDay { return t }
            t = t.addingTimeInterval(60)
        }
        return nil
    }
}
