import Foundation

/// The GitHub contribution calendar (Windows GithubData), also the cache (github-cache.json).
public struct GithubData: Codable, Equatable {
    public struct Day: Codable, Equatable {
        /// "2026-10-16"
        public var date: String
        public var count: Int
        /// 0 to 4, GitHub's quartiles.
        public var level: Int
        public init(date: String, count: Int, level: Int) { self.date = date; self.count = count; self.level = level }
    }

    public var login: String
    public var fetched: Date
    public var total: Int
    public var days: [Day]

    public init(login: String, fetched: Date, total: Int, days: [Day]) {
        self.login = login; self.fetched = fetched; self.total = total; self.days = days
    }

    public static let calendarQuery = "query { viewer { login contributionsCollection { contributionCalendar { totalContributions weeks { contributionDays { date contributionCount contributionLevel } } } } } }"
    public static let loginQuery = "query { viewer { login } }"

    /// Consecutive days with contributions ending today (a still-empty today does not break it).
    public var streak: Int {
        var index = days.count - 1, count = 0
        if index >= 0, days[index].count == 0 { index -= 1 }
        while index >= 0, days[index].count > 0 { count += 1; index -= 1 }
        return count
    }

    /// Same content: the graph does not need to be redrawn.
    public func sameGraph(_ other: GithubData) -> Bool { total == other.total && days == other.days }

    public static func parse(_ data: [String: Any], fetched: Date) throws -> GithubData {
        guard let viewer = data["viewer"] as? [String: Any],
              let calendar = ((viewer["contributionsCollection"] as? [String: Any])?["contributionCalendar"]) as? [String: Any],
              let weeks = calendar["weeks"] as? [[String: Any]] else { throw GithubError.message("GitHub sent an unexpected response.", offline: false) }
        let levels = ["FIRST_QUARTILE": 1, "SECOND_QUARTILE": 2, "THIRD_QUARTILE": 3, "FOURTH_QUARTILE": 4]
        let days = weeks.flatMap { ($0["contributionDays"] as? [[String: Any]]) ?? [] }.compactMap { day -> Day? in
            guard let date = day["date"] as? String else { return nil }
            return Day(date: date, count: day["contributionCount"] as? Int ?? 0, level: levels[day["contributionLevel"] as? String ?? ""] ?? 0)
        }
        return GithubData(login: viewer["login"] as? String ?? "", fetched: fetched, total: calendar["totalContributions"] as? Int ?? 0, days: days)
    }

    /// The `data` object of a GraphQL response, or the error to show.
    public static func payload(status: Int?, body: Data?, transportFailed: Bool) throws -> [String: Any] {
        if transportFailed { throw GithubError.message("No connection to GitHub.", offline: true) }
        switch status ?? 0 {
        case 401: throw GithubError.message("GitHub rejected the token. Check it in Settings.", offline: false)
        case 403, 429: throw GithubError.message("GitHub refused the request (rate limit or missing permission).", offline: false)
        case 200..<300: break
        default: throw GithubError.message("GitHub returned \(status ?? 0).", offline: false)
        }
        guard let body, let root = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            throw GithubError.message("GitHub sent an unexpected response.", offline: false)
        }
        if let errors = root["errors"] as? [[String: Any]], let first = errors.first {
            throw GithubError.message(first["message"] as? String ?? "GitHub returned an error.", offline: false)
        }
        guard let data = root["data"] as? [String: Any] else { throw GithubError.message("GitHub sent an unexpected response.", offline: false) }
        return data
    }

    /// Deterministic sample data for diagnostic runs.
    public static func demo(now: Date = Date()) -> GithubData {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let today = calendar.startOfDay(for: now)
        let weekday = calendar.component(.weekday, from: today) - 1
        let start = calendar.date(byAdding: .day, value: -(52 * 7 + weekday), to: today)!
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        var days: [Day] = []
        var seed: UInt64 = 42
        var total = 0
        var date = start
        while date <= today {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let roll = Int(seed >> 59)
            let count = roll < 14 ? 0 : (roll - 13) * 2
            total += count
            days.append(Day(date: formatter.string(from: date), count: count, level: count == 0 ? 0 : min(4, (count + 1) / 2)))
            date = calendar.date(byAdding: .day, value: 1, to: date)!
        }
        return GithubData(login: "octocat", fetched: now, total: total, days: days)
    }
}

public enum GithubError: Error, Equatable {
    case message(String, offline: Bool)
    public var text: String { if case .message(let text, _) = self { return text }; return "" }
    public var offline: Bool { if case .message(_, let offline) = self { return offline }; return false }
}
