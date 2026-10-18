import Foundation

/// The user's launchd agents (~/Library/LaunchAgents), the macOS counterpart of the Windows
/// Task Scheduler view: scripts and jobs on a timer, with pause, resume and delete.
public struct LaunchAgentJob: Equatable, Identifiable {
    public var id: String { label }
    public var label: String
    public var path: String
    public var program: String
    public var schedule: String
    public var next: Date?
    /// Installed by an app (its program lives in an app bundle or Application Support).
    public var fromApp: Bool
    public var loaded = false
    public var running = false
    public var disabled = false
    public var lastExit: Int?

    public var paused: Bool { disabled || !loaded }
    public var failed: Bool { (lastExit ?? 0) != 0 }

    /// Builds a job from a plist's contents; nil for a file that is not a launchd job.
    public static func parse(_ plist: [String: Any], path: String, now: Date = Date(), calendar: Calendar = .current) -> LaunchAgentJob? {
        guard let label = plist["Label"] as? String, !label.isEmpty else { return nil }
        let arguments = plist["ProgramArguments"] as? [String] ?? []
        let program = plist["Program"] as? String ?? arguments.first ?? ""
        let home = NSHomeDirectory()
        let fromApp = program.contains(".app/") || program.contains("/Library/Application Support/") || label.hasPrefix("com.apple.")
            || (program.hasPrefix(home + "/Library/") && !program.hasPrefix(home + "/Library/Scripts"))
        let (schedule, next) = describe(plist, now: now, calendar: calendar)
        let shown = arguments.isEmpty ? program : arguments.map { $0.contains(" ") ? "\"\($0)\"" : $0 }.joined(separator: " ")
        return LaunchAgentJob(label: label, path: path, program: shown, schedule: schedule, next: next, fromApp: fromApp)
    }

    /// "Every 10 min", "Daily at 09:00", "At login", "Always running"…, and the next calendar run.
    static func describe(_ plist: [String: Any], now: Date, calendar: Calendar) -> (String, Date?) {
        if let seconds = (plist["StartInterval"] as? NSNumber)?.intValue, seconds > 0 {
            let text = seconds % 86400 == 0 ? "Every \(seconds / 86400) d" : seconds % 3600 == 0 ? "Every \(seconds / 3600) h"
                : seconds % 60 == 0 ? "Every \(seconds / 60) min" : "Every \(seconds) s"
            return (text, nil)
        }
        let entries: [[String: Any]] = (plist["StartCalendarInterval"] as? [[String: Any]]) ?? ((plist["StartCalendarInterval"] as? [String: Any]).map { [$0] } ?? [])
        if !entries.isEmpty {
            let nexts = entries.compactMap { entry -> Date? in
                var parts = DateComponents()
                parts.minute = (entry["Minute"] as? NSNumber)?.intValue ?? 0
                parts.hour = (entry["Hour"] as? NSNumber)?.intValue
                parts.day = (entry["Day"] as? NSNumber)?.intValue
                parts.month = (entry["Month"] as? NSNumber)?.intValue
                if let weekday = (entry["Weekday"] as? NSNumber)?.intValue { parts.weekday = weekday % 7 + 1 } // launchd: 0 and 7 are Sunday
                return calendar.nextDate(after: now, matching: parts, matchingPolicy: .nextTime)
            }
            return (entries.count > 1 ? "\(entries.count) times" : calendarText(entries[0]), nexts.min())
        }
        if plist["KeepAlive"] as? Bool == true || plist["KeepAlive"] is [String: Any] { return ("Always running", nil) }
        if plist["WatchPaths"] != nil || plist["QueueDirectories"] != nil { return ("When files change", nil) }
        if plist["RunAtLoad"] as? Bool == true { return ("At login", nil) }
        return ("Manual", nil)
    }

    static func calendarText(_ entry: [String: Any]) -> String {
        let minute = (entry["Minute"] as? NSNumber)?.intValue ?? 0
        let hour = (entry["Hour"] as? NSNumber)?.intValue
        let time = hour.map { String(format: "%02d:%02d", $0, minute) }
        if let weekday = (entry["Weekday"] as? NSNumber)?.intValue {
            let names = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
            return "\(names[min(7, max(0, weekday))])s" + (time.map { " at \($0)" } ?? "")
        }
        if let day = (entry["Day"] as? NSNumber)?.intValue { return "Monthly on day \(day)" + (time.map { " at \($0)" } ?? "") }
        if let time { return "Daily at \(time)" }
        return String(format: "Hourly at :%02d", minute)
    }

    /// `launchctl list`: label → (pid, last exit status).
    public static func parseList(_ text: String) -> [String: (pid: Int?, status: Int?)] {
        var result: [String: (Int?, Int?)] = [:]
        for line in text.split(separator: "\n").dropFirst() {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard parts.count >= 3 else { continue }
            result[String(parts[2])] = (Int(parts[0]), Int(parts[1]))
        }
        return result
    }

    /// `launchctl print-disabled gui/<uid>`: labels marked disabled.
    public static func parseDisabled(_ text: String) -> Set<String> {
        var result = Set<String>()
        for line in text.split(separator: "\n") where line.contains("=> disabled") || line.contains("=> true") {
            if let start = line.firstIndex(of: "\""), let end = line[line.index(after: start)...].firstIndex(of: "\"") {
                result.insert(String(line[line.index(after: start)..<end]))
            }
        }
        return result
    }

    /// "Every 10 min · next 09:50 · last exit 0", "Running now", "Paused", "Failed (exit 1)".
    public func meta(formatter: DateFormatter) -> String {
        if running { return "\(schedule) · Running now" }
        if paused { return "\(schedule) · Paused" }
        var parts = [schedule]
        if let next { parts.append("next " + formatter.string(from: next)) }
        if let lastExit, lastExit != 0 { parts.append("failed (exit \(lastExit))") }
        return parts.joined(separator: " · ")
    }
}
