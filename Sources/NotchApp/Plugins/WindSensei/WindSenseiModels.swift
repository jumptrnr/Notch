import Foundation

/// The body of WindSensei's `GET /api/v1/dashboard/widget`: one self-contained record per
/// favourite spot, the same payload its iOS, watch and Mac widgets render. Every grade is
/// resolved on the server; nothing is re-graded here.
struct WindSenseiResponse: Decodable {
    let spots: [WindSenseiSpot]
    /// False when a favourite failed upstream and was left out of `spots`.
    let complete: Bool?
    let generatedAt: String?
}

struct WindSenseiSpot: Decodable, Identifiable {
    var id: String { locationId }
    let locationId: String
    let name: String
    let current: WindSenseiCurrent
    let observed: WindSenseiObserved?
    let timeBlocks: [WindSenseiBlock]?
    /// Today's and tomorrow's hours, spot-local, as "yyyy-MM-dd'T'HH:mm".
    let hourly: [WindSenseiHour]?
    /// Per spot-local day ("yyyy-MM-dd"): sun times and the rider's session window.
    let days: [String: WindSenseiDay]?
}

/// Forecast for the current hour. Wind in knots.
struct WindSenseiCurrent: Decodable {
    let windSpeed: Int
    let windGust: Int?
    let windDirection: Int
    let temperature: Int
    let quality: String
}

/// The nearest station's latest reading. Wind in knots.
struct WindSenseiObserved: Decodable {
    let stationName: String?
    let observationTime: String
    let windSpeed: Int
    let windDirection: Int
    let windGust: Int?
    let temperature: Int
    /// excellent, good, medium, bad, or unknown.
    let quality: String?

    var date: Date? { WindSenseiTime.parse(observationTime) }

    /// Stations publish hourly with up to a quarter hour of lag; past this the reading is stale.
    static let freshness: TimeInterval = 75 * 60
}

/// A rideable stretch. `endHour` is exclusive: the hour after the block.
struct WindSenseiBlock: Decodable {
    let startTime: String
    let endTime: String
    let startHour: Int
    let endHour: Int
    let quality: String
}

struct WindSenseiHour: Decodable {
    let time: String
    let windSpeed: Int
    let windGust: Int?
    let windDirection: Int
    /// The grade the bar is painted with, resolved by the server.
    let barQuality: String
}

struct WindSenseiDay: Decodable {
    let sunrise: String?
    let sunset: String?
    /// Inclusive hours of the session window. A polar night has `windowEnd` below `windowStart`.
    let windowStart: Int
    let windowEnd: Int
}

/// Parses the payload's times the way WindSensei's own widgets do: full ISO timestamps as they
/// are, and the offset-less spot-local hours as this Mac's local time, since favourites are
/// local to the rider.
enum WindSenseiTime {
    private static let isoWithFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let localHour: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        return formatter
    }()

    private static let dayKey: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        return formatter
    }()

    static func parse(_ string: String) -> Date? {
        if let date = isoWithFraction.date(from: string) { return date }
        if let date = iso.date(from: string) { return date }
        return localHour.date(from: string)
    }

    /// The `days` key for a date.
    static func key(for date: Date) -> String { dayKey.string(from: date) }

    /// "2pm" from an hour of the day.
    static func clock(_ hour: Int) -> String {
        let h = ((hour % 24) + 24) % 24
        switch h {
        case 0: return "12am"
        case 1..<12: return "\(h)am"
        case 12: return "12pm"
        default: return "\(h - 12)pm"
        }
    }
}
