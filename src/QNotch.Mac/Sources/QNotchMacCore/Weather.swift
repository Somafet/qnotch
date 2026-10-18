import Foundation

// MET Norway Locationforecast 2.0 and the yr.no location search, as on Windows.

public enum WeatherUnits: String, Codable { case metric, imperial }

/// A place from the yr.no location search.
public struct WeatherPlace: Codable, Equatable {
    public var id: String
    public var name: String
    /// "Budapest, Hungary": region and country, whichever differ from the name.
    public var detail: String
    public var lat: Double
    public var lon: Double
    public var elevation: Int?
    public var timeZone: String
    public var urlPath: String

    public init(id: String, name: String, detail: String, lat: Double, lon: Double, elevation: Int?, timeZone: String, urlPath: String) {
        self.id = id; self.name = name; self.detail = detail; self.lat = lat; self.lon = lon
        self.elevation = elevation; self.timeZone = timeZone; self.urlPath = urlPath
    }

    public var yrURL: URL? {
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
        let tail = urlPath.isEmpty ? "" : "/" + urlPath.split(separator: "/").map { String($0).addingPercentEncoding(withAllowedCharacters: allowed) ?? "" }.joined(separator: "/")
        return URL(string: "https://www.yr.no/en/forecast/daily-table/" + (id.addingPercentEncoding(withAllowedCharacters: allowed) ?? "") + tail)
    }

    public var forecastURL: URL? {
        var text = String(format: "https://api.met.no/weatherapi/locationforecast/2.0/complete?lat=%.4f&lon=%.4f", lat, lon)
        if let elevation { text += "&altitude=\(elevation)" }
        return URL(string: text)
    }

    public func sameSpot(_ forecast: WeatherForecast) -> Bool { abs(forecast.lat - lat) < 0.0001 && abs(forecast.lon - lon) < 0.0001 }

    public static func searchURL(_ query: String) -> URL? {
        URL(string: "https://www.yr.no/api/v0/locations/search?language=en&q=" + (query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+"))) ?? ""))
    }

    /// Up to 8 places from a search response.
    public static func parseSearch(_ data: Data) throws -> [WeatherPlace] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw WeatherError.unexpected }
        guard let list = (root["_embedded"] as? [String: Any])?["location"] as? [[String: Any]] else { return [] }
        return list.prefix(8).compactMap { item in
            guard let position = item["position"] as? [String: Any], let lat = position["lat"] as? Double, let lon = position["lon"] as? Double else { return nil }
            let name = item["name"] as? String ?? ""
            func sub(_ key: String) -> String { (item[key] as? [String: Any])?["name"] as? String ?? "" }
            var detail: [String] = []
            for part in [sub("region"), sub("country")] where !part.isEmpty && part != name && !detail.contains(part) { detail.append(part) }
            return WeatherPlace(id: item["id"] as? String ?? "", name: name, detail: detail.joined(separator: ", "), lat: lat, lon: lon,
                                elevation: (item["elevation"] as? Double).map { Int($0.rounded()) }, timeZone: item["timeZone"] as? String ?? "",
                                urlPath: item["urlPath"] as? String ?? "")
        }
    }
}

public enum WeatherError: Error, Equatable { case unexpected, empty }

/// One forecast step: hourly for about two days, then every six hours. °C, m/s, mm.
public struct WeatherPoint: Codable, Equatable {
    public var time: Date
    public var temp: Double
    public var feels: Double?
    public var wind: Double?
    public var symbol1: String?
    public var symbol6: String?
    public var precip1: Double?
    public var max6: Double?
    public var min6: Double?

    public init(time: Date, temp: Double, feels: Double? = nil, wind: Double? = nil, symbol1: String? = nil, symbol6: String? = nil,
                precip1: Double? = nil, max6: Double? = nil, min6: Double? = nil) {
        self.time = time; self.temp = temp; self.feels = feels; self.wind = wind; self.symbol1 = symbol1; self.symbol6 = symbol6
        self.precip1 = precip1; self.max6 = max6; self.min6 = min6
    }
}

/// The parsed forecast, also the disk cache (weather-cache.json).
public struct WeatherForecast: Codable, Equatable {
    public var lat: Double
    public var lon: Double
    public var fetched: Date
    /// When MET says the data may change; no request before that.
    public var expires: Date
    /// Sent back as If-Modified-Since.
    public var lastModified: String
    public var points: [WeatherPoint]

    public init(lat: Double, lon: Double, fetched: Date, expires: Date, lastModified: String, points: [WeatherPoint]) {
        self.lat = lat; self.lon = lon; self.fetched = fetched; self.expires = expires; self.lastModified = lastModified; self.points = points
    }

    public static func parse(_ data: Data, lat: Double, lon: Double, fetched: Date, expires: Date, lastModified: String) throws -> WeatherForecast {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let series = (root["properties"] as? [String: Any])?["timeseries"] as? [[String: Any]] else { throw WeatherError.unexpected }
        let iso = ISO8601DateFormatter()
        var points: [WeatherPoint] = []
        for step in series {
            guard let time = (step["time"] as? String).flatMap(iso.date), let data = step["data"] as? [String: Any],
                  let now = (data["instant"] as? [String: Any])?["details"] as? [String: Any], let temp = now["air_temperature"] as? Double else {
                throw WeatherError.unexpected
            }
            var point = WeatherPoint(time: time, temp: temp, feels: now["apparent_air_temperature"] as? Double, wind: now["wind_speed"] as? Double)
            if let next1 = data["next_1_hours"] as? [String: Any] {
                point.symbol1 = (next1["summary"] as? [String: Any])?["symbol_code"] as? String
                point.precip1 = (next1["details"] as? [String: Any])?["precipitation_amount"] as? Double
            }
            if let next6 = data["next_6_hours"] as? [String: Any] {
                point.symbol6 = (next6["summary"] as? [String: Any])?["symbol_code"] as? String
                let details = next6["details"] as? [String: Any]
                point.max6 = details?["air_temperature_max"] as? Double
                point.min6 = details?["air_temperature_min"] as? Double
            }
            points.append(point)
        }
        guard !points.isEmpty else { throw WeatherError.empty }
        return WeatherForecast(lat: lat, lon: lon, fetched: fetched, expires: expires, lastModified: lastModified, points: points)
    }
}

public struct WeatherDay: Equatable {
    public var name: String
    public var symbol: String
    public var high: String
    public var low: String
    public var tip: String
}

/// Everything the views show, formatted for one moment.
public struct WeatherView: Equatable {
    public var symbol: String
    public var temp: String
    public var condition: String
    public var detail: String
    public var days: [WeatherDay]
}

public enum WeatherFormat {
    /// Nil when the forecast no longer covers `now` (more than six hours old).
    public static func build(_ forecast: WeatherForecast, place: WeatherPlace, units: WeatherUnits, now: Date, dayCount: Int = 4) -> WeatherView? {
        var current: WeatherPoint?
        for point in forecast.points {
            if point.time > now { if current == nil { current = point }; break }
            current = point
        }
        guard let current, now.timeIntervalSince(current.time) <= 6 * 3600 else { return nil }
        let symbol = current.symbol1 ?? current.symbol6 ?? ""
        var detail: [String] = []
        if let feels = current.feels, degrees(feels, units) != degrees(current.temp, units) { detail.append("Feels " + degrees(feels, units)) }
        if let wind = current.wind { detail.append(units == .imperial ? "\(Int((wind * 2.23694).rounded())) mph" : "\(Int(wind.rounded())) m/s") }
        if let rain = current.precip1, rain > 0 {
            detail.append(units == .imperial ? String(format: "%.2g in", rain / 25.4) : String(format: rain < 10 ? "%.1f mm" : "%.0f mm", rain))
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: place.timeZone) ?? .current
        let today = calendar.startOfDay(for: now)
        let weekday = DateFormatter()
        weekday.timeZone = calendar.timeZone
        weekday.setLocalizedDateFormatFromTemplate("EEE")
        let long = DateFormatter()
        long.timeZone = calendar.timeZone
        long.setLocalizedDateFormatFromTemplate("EEEEdMMMM")
        var days: [WeatherDay] = []
        for offset in 0..<dayCount {
            guard let date = calendar.date(byAdding: .day, value: offset, to: today) else { break }
            var high = -Double.infinity, low = Double.infinity
            var pick: WeatherPoint?
            var distance = Int.max
            for point in forecast.points where point.time >= current.time && calendar.isDate(point.time, inSameDayAs: date) {
                high = max(high, point.temp, point.max6 ?? point.temp)
                low = min(low, point.temp, point.min6 ?? point.temp)
                // The day's symbol: the six-hour period starting closest to noon.
                let hour = calendar.component(.hour, from: point.time)
                if point.symbol6 != nil, abs(hour - 12) < distance { pick = point; distance = abs(hour - 12) }
            }
            guard high > -Double.infinity else { break }
            let daySymbol = pick?.symbol6 ?? symbol
            days.append(WeatherDay(name: offset == 0 ? "Today" : weekday.string(from: date), symbol: daySymbol,
                                   high: degrees(high, units), low: degrees(low, units),
                                   tip: "\(long.string(from: date)): \(condition(daySymbol)), \(degrees(high, units)) / \(degrees(low, units))"))
        }
        return WeatherView(symbol: symbol, temp: degrees(current.temp, units), condition: condition(symbol), detail: detail.joined(separator: " · "), days: days)
    }

    public static func degrees(_ celsius: Double, _ units: WeatherUnits) -> String {
        let value = units == .imperial ? celsius * 9 / 5 + 32 : celsius
        return "\(Int(value.rounded(.toNearestOrAwayFromZero)))°"
    }

    /// "Light rain showers" for "lightrainshowers_day" (MET Norway's symbol legend).
    public static func condition(_ symbol: String) -> String {
        let base = symbol.split(separator: "_").first.map(String.init) ?? symbol
        if let name = names[base] { return name }
        return ""
    }

    static let names: [String: String] = {
        var table = ["clearsky": "Clear sky", "fair": "Fair", "partlycloudy": "Partly cloudy", "cloudy": "Cloudy", "fog": "Fog"]
        for (kind, label) in [("rain", "rain"), ("sleet", "sleet"), ("snow", "snow")] {
            for (prefix, adjective) in [("light", "Light "), ("", ""), ("heavy", "Heavy ")] {
                let first = adjective.isEmpty ? label.prefix(1).uppercased() + label.dropFirst() : adjective + label
                table[prefix + kind] = first
                table[prefix + kind + "showers"] = first + " showers"
                table[prefix + kind + "andthunder"] = first + " and thunder"
                table[prefix + kind + "showersandthunder"] = first + " showers and thunder"
            }
        }
        return table
    }()

    /// MET symbol code to a multicolor SF Symbol.
    public static func sfSymbol(_ symbol: String) -> String {
        let night = symbol.hasSuffix("_night"), twilight = symbol.hasSuffix("_polartwilight")
        let base = symbol.split(separator: "_").first.map(String.init) ?? symbol
        switch base {
        case "clearsky": return night ? "moon.stars.fill" : twilight ? "sun.horizon.fill" : "sun.max.fill"
        case "fair": return night ? "moon.fill" : "sun.min.fill"
        case "partlycloudy": return night ? "cloud.moon.fill" : "cloud.sun.fill"
        case "cloudy": return "cloud.fill"
        case "fog": return "cloud.fog.fill"
        default: break
        }
        if base.contains("thunder") { return base.contains("rain") ? "cloud.bolt.rain.fill" : "cloud.bolt.fill" }
        if base.contains("snow") { return "cloud.snow.fill" }
        if base.contains("sleet") { return "cloud.sleet.fill" }
        if base.contains("rainshowers") { return base.hasPrefix("heavy") ? "cloud.heavyrain.fill" : night ? "cloud.moon.rain.fill" : "cloud.sun.rain.fill" }
        if base.contains("rain") { return base.hasPrefix("light") ? "cloud.drizzle.fill" : base.hasPrefix("heavy") ? "cloud.heavyrain.fill" : "cloud.rain.fill" }
        return "cloud.fill"
    }

    /// Next refresh: at Expires plus 30 s, within 10 minutes and 2 hours.
    public static func nextRefresh(expires: Date, now: Date) -> TimeInterval {
        min(2 * 3600, max(600, expires.timeIntervalSince(now) + 30))
    }

    public static func ago(_ date: Date, now: Date = Date()) -> String {
        let age = now.timeIntervalSince(date)
        if age < 60 { return "just now" }
        if age < 3600 { return "\(Int(age / 60)) min ago" }
        if age < 86400 { return "\(Int(age / 3600)) h ago" }
        return "\(Int(age / 86400)) d ago"
    }
}

public struct WeatherSettings: Codable, Equatable {
    public var place: WeatherPlace?
    public var units = WeatherUnits.metric
    public var showInPill = true
    public init() {}
    private enum CodingKeys: String, CodingKey { case place, units, showInPill }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        place = c.value(.place, WeatherPlace?.none)
        units = c.value(.units, WeatherUnits.metric)
        showInPill = c.value(.showInPill, true)
    }
}
