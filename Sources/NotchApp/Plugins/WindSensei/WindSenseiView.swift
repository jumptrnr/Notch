import SwiftUI

/// The Wind tab, after WindSensei's own Mac app: the first favourite gets a card with the big
/// reading, grade and the session window as bars; the other favourites one row each. Every
/// grade and colour is the server's.
struct WindSenseiView: View {
    @ObservedObject var plugin: WindSenseiPlugin

    var body: some View {
        // Ages and the current-hour highlight move with the clock, not with the data, so the
        // tab is re-evaluated once a minute.
        TimelineView(.periodic(from: .now, by: 60)) { context in
            VStack(spacing: 6) {
                if plugin.spots.isEmpty {
                    placeholder
                } else {
                    ScrollView(.vertical) {
                        VStack(spacing: 6) {
                            if let first = plugin.spots.first {
                                SpotCard(spot: first, now: context.date)
                            }
                            ForEach(plugin.spots.dropFirst()) { spot in
                                SpotRow(spot: spot, now: context.date)
                            }
                        }
                        .padding(.trailing, 2)
                    }
                    .scrollIndicators(.hidden)
                }
                footer(now: context.date)
            }
        }
    }

    private var placeholder: some View {
        VStack(spacing: 4) {
            if plugin.isLoading {
                Text("Loading your spots…")
            } else if let error = plugin.lastError {
                Text(error).foregroundStyle(.red.opacity(0.9))
            } else {
                Text("No favourite spots on this WindSensei account.")
            }
        }
        .font(.ui(11))
        .foregroundStyle(.white.opacity(0.5))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func footer(now: Date) -> some View {
        HStack(spacing: 8) {
            if let error = plugin.lastError, !plugin.spots.isEmpty {
                Text(error).foregroundStyle(.red.opacity(0.9)).lineLimit(1)
            } else if let fetchedAt = plugin.fetchedAt {
                Text("Updated \(WindSenseiFormat.age(fetchedAt, now: now))")
            }
            Spacer()
            Link(destination: WindSenseiPlugin.site) {
                HStack(spacing: 3) {
                    Text("windsensei.com")
                    Image(systemName: "arrow.up.right").font(.ui(7, weight: .bold))
                }
                .foregroundStyle(.white.opacity(0.55))
            }
            Button { plugin.refresh() } label: {
                Image(systemName: "arrow.clockwise")
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(plugin.isLoading)
            .opacity(plugin.isLoading ? 0.3 : 1)
            .help("Refresh")
        }
        .font(.ui(9))
        .foregroundStyle(.white.opacity(0.4))
        .frame(height: 14)
    }
}

/// What a spot shows right now: the station's reading while it is fresh, else this hour's
/// forecast, with the station named and its reading aged either way so a stale one is seen.
struct WindReading {
    var speed: Int
    var gust: Int?
    var direction: Int
    var temperature: Int
    var quality: String?
    var isForecast: Bool
    var station: String?
    var observedAt: Date?

    init(spot: WindSenseiSpot, now: Date) {
        let observed = spot.observed
        let date = observed?.date
        station = observed?.stationName
        observedAt = date
        if let observed, let date, now.timeIntervalSince(date) <= WindSenseiObserved.freshness {
            speed = observed.windSpeed
            gust = observed.windGust
            direction = observed.windDirection
            temperature = observed.temperature
            quality = observed.quality ?? spot.current.quality
            isForecast = false
        } else {
            speed = spot.current.windSpeed
            gust = spot.current.windGust
            direction = spot.current.windDirection
            temperature = spot.current.temperature
            quality = spot.current.quality
            isForecast = true
        }
    }

    var color: Color { WindSenseiFormat.color(quality) }
    var isStale: Bool { isForecast && observedAt != nil }
}

/// The rideable blocks around now: the one under way, the next one today, the best tomorrow.
struct WindOutlook {
    var current: WindSenseiBlock?
    var nextToday: WindSenseiBlock?
    var tomorrow: WindSenseiBlock?
    var todayWindowOver: Bool

    init(spot: WindSenseiSpot, now: Date) {
        let calendar = Calendar.current
        let blocks: [(WindSenseiBlock, Date, Date)] = (spot.timeBlocks ?? []).compactMap { block in
            guard let start = WindSenseiTime.parse(block.startTime), let end = WindSenseiTime.parse(block.endTime) else { return nil }
            return (block, start, end)
        }
        current = blocks.first { $0.1 <= now && now < $0.2 }?.0
        nextToday = blocks.first { calendar.isDate($0.1, inSameDayAs: now) && $0.1 > now }?.0
        let tomorrowBlocks = blocks.filter { !calendar.isDate($0.1, inSameDayAs: now) && $0.1 > now }
        tomorrow = tomorrowBlocks.max { WindSenseiFormat.rank($0.0.quality) < WindSenseiFormat.rank($1.0.quality) }?.0
        if let window = spot.days?[WindSenseiTime.key(for: now)],
           let end = calendar.date(bySettingHour: min(window.windowEnd + 1, 23), minute: 0, second: 0, of: now) {
            todayWindowOver = now >= end
        } else {
            todayWindowOver = false
        }
    }

    /// "until 17:00" while a block runs, "Good 14–17" for one still to come.
    var todayText: String? {
        if let current { return "until \(WindSenseiFormat.hour(current.endHour))" }
        if let nextToday { return "\(nextToday.quality.capitalized) \(WindSenseiFormat.range(nextToday))" }
        return nil
    }

    var tomorrowText: String {
        guard let tomorrow else { return "Nothing tomorrow" }
        return "Tomorrow \(tomorrow.quality.capitalized) \(WindSenseiFormat.range(tomorrow))"
    }
}

/// The first favourite: name and station, the reading large in its grade's colour with the
/// gust beside it, direction and temperature, the grade word and when it ends, then the
/// session window as bars.
private struct SpotCard: View {
    let spot: WindSenseiSpot
    let now: Date

    var body: some View {
        let reading = WindReading(spot: spot, now: now)
        let outlook = WindOutlook(spot: spot, now: now)
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(spot.name)
                        .font(.ui(12, weight: .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Text(source(reading))
                        .font(.ui(7.5))
                        .foregroundStyle(reading.isStale ? Color.orange : .white.opacity(0.5))
                        .lineLimit(1)
                }
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text("\(reading.speed)")
                        .font(.ui(34, weight: .heavy, design: .rounded))
                        .foregroundStyle(reading.color)
                    if let gust = reading.gust, gust > reading.speed {
                        Text("G\(gust)")
                            .font(.ui(14, weight: .semibold, design: .rounded))
                            .foregroundStyle(reading.color.opacity(0.75))
                    }
                    Text("kn")
                        .font(.ui(9))
                        .foregroundStyle(.white.opacity(0.5))
                }
                HStack(spacing: 8) {
                    HStack(spacing: 3) {
                        Image(systemName: "location.north.fill")
                            .font(.ui(9))
                            .foregroundStyle(reading.color)
                            .rotationEffect(.degrees(Double(reading.direction) + 180))
                        Text("\(reading.direction)° \(WindSenseiTabLabel.compass(reading.direction))")
                    }
                    HStack(spacing: 3) {
                        Image(systemName: "thermometer.medium")
                            .font(.ui(8))
                            .opacity(0.6)
                        Text("\(reading.temperature)°")
                    }
                }
                .font(.ui(9))
                .foregroundStyle(.white.opacity(0.7))
                HStack(spacing: 4) {
                    Circle().fill(reading.color).frame(width: 6, height: 6)
                    Text(WindSenseiFormat.word(reading.quality))
                        .font(.ui(9, weight: .semibold))
                    Text(gradeDetail(outlook))
                        .font(.ui(9))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }
                .padding(.top, 2)
                Text(outlook.todayWindowOver ? "Next: \(outlook.tomorrowText.lowercasedFirst)" : outlook.tomorrowText)
                    .font(.ui(7.5))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
            }
            .frame(width: 150)
            WindStrip(spot: spot, now: now, compact: false)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.07)))
    }

    private func source(_ reading: WindReading) -> String {
        if let date = reading.observedAt {
            let station = reading.station ?? "Station"
            return "\(station) · \(WindSenseiFormat.age(date, now: now))"
        }
        return "forecast"
    }

    private func gradeDetail(_ outlook: WindOutlook) -> String {
        if let text = outlook.todayText { return "· \(text)" }
        return outlook.todayWindowOver ? "· today's window over" : "· no window today"
    }
}

/// Every favourite after the first: name, what's next, the reading, and a thumbnail of the window.
private struct SpotRow: View {
    let spot: WindSenseiSpot
    let now: Date

    var body: some View {
        let reading = WindReading(spot: spot, now: now)
        let outlook = WindOutlook(spot: spot, now: now)
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(spot.name)
                    .font(.ui(10, weight: .semibold))
                    .lineLimit(1)
                Text(detail(reading, outlook))
                    .font(.ui(7.5))
                    .foregroundStyle(reading.isStale ? Color.orange : .white.opacity(0.5))
                    .lineLimit(1)
            }
            .frame(width: 150, alignment: .leading)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                if reading.isForecast {
                    Text("~")
                        .font(.ui(8))
                        .foregroundStyle(.white.opacity(0.45))
                }
                Text("\(reading.speed)")
                    .font(.ui(15, weight: .bold, design: .rounded))
                    .foregroundStyle(reading.color)
                Text("kn")
                    .font(.ui(7.5))
                    .foregroundStyle(.white.opacity(0.5))
                Image(systemName: "location.north.fill")
                    .font(.ui(7))
                    .foregroundStyle(.white.opacity(0.6))
                    .rotationEffect(.degrees(Double(reading.direction) + 180))
            }
            .frame(width: 60, alignment: .leading)
            WindStrip(spot: spot, now: now, compact: true)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.05)))
    }

    private func detail(_ reading: WindReading, _ outlook: WindOutlook) -> String {
        var parts: [String] = []
        if let date = reading.observedAt {
            parts.append("\(reading.station ?? "Station") · \(WindSenseiFormat.age(date, now: now))")
        } else {
            parts.append("forecast")
        }
        if let today = outlook.todayText {
            parts.append(today)
        } else if outlook.todayWindowOver {
            parts.append(outlook.tomorrowText.lowercasedFirst)
        } else {
            parts.append("no window today")
        }
        return parts.joined(separator: " · ")
    }
}

/// The session window as one bar per hour in the hour's grade colour, the gust above it
/// lighter, the hour under way outlined. Today's window until it has gone by, then tomorrow's.
/// The full form adds a header with the day and sun time, direction arrows and hour labels.
private struct WindStrip: View {
    let spot: WindSenseiSpot
    let now: Date
    let compact: Bool

    var body: some View {
        let (hours, day) = Self.window(for: spot, now: now)
        if hours.isEmpty {
            Text(compact ? "" : "No session window")
                .font(.ui(9))
                .foregroundStyle(.white.opacity(0.35))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        } else {
            let top = max(20, hours.map { max($0.0.windSpeed, $0.0.windGust ?? 0) }.max() ?? 0)
            VStack(spacing: 3) {
                if !compact {
                    header(day: day, hours: hours)
                }
                GeometryReader { geo in
                    HStack(alignment: .bottom, spacing: compact ? 2 : 3) {
                        ForEach(Array(hours.enumerated()), id: \.offset) { _, entry in
                            let (hour, date) = entry
                            let isCurrent = date <= now && now < date.addingTimeInterval(3600)
                            VStack(spacing: 1) {
                                Spacer(minLength: 0)
                                if let gust = hour.windGust, gust > hour.windSpeed {
                                    RoundedRectangle(cornerRadius: 1.5)
                                        .fill(WindSenseiFormat.color(hour.barQuality).opacity(0.38))
                                        .frame(height: CGFloat(gust - hour.windSpeed) / CGFloat(top) * geo.size.height)
                                }
                                RoundedRectangle(cornerRadius: 1.5)
                                    .fill(WindSenseiFormat.color(hour.barQuality))
                                    .frame(height: max(2, CGFloat(hour.windSpeed) / CGFloat(top) * geo.size.height))
                            }
                            .frame(maxWidth: .infinity)
                            .overlay(
                                RoundedRectangle(cornerRadius: 2)
                                    .strokeBorder(Color.white.opacity(isCurrent ? 0.9 : 0), lineWidth: 1)
                                    .padding(-2)
                            )
                        }
                    }
                }
                .frame(height: compact ? 20 : 64)
                if !compact {
                    HStack(spacing: 3) {
                        ForEach(Array(hours.enumerated()), id: \.offset) { _, entry in
                            Image(systemName: "location.north.fill")
                                .font(.ui(6))
                                .foregroundStyle(.white.opacity(0.45))
                                .rotationEffect(.degrees(Double(entry.0.windDirection) + 180))
                                .frame(maxWidth: .infinity)
                        }
                    }
                    HStack(spacing: 3) {
                        ForEach(Array(hours.enumerated()), id: \.offset) { index, entry in
                            let h = Calendar.current.component(.hour, from: entry.1)
                            let isCurrent = entry.1 <= now && now < entry.1.addingTimeInterval(3600)
                            Text(hours.count > 12 && index % 2 == 1 ? "" : "\(h)")
                                .font(.ui(6.5, weight: isCurrent ? .semibold : .regular))
                                .foregroundStyle(.white.opacity(isCurrent ? 1 : 0.5))
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func header(day: Date, hours: [(WindSenseiHour, Date)]) -> some View {
        let calendar = Calendar.current
        let isToday = calendar.isDate(day, inSameDayAs: now)
        let info = spot.days?[WindSenseiTime.key(for: day)]
        let sun: String? = {
            guard let info else { return nil }
            if isToday, let sunset = info.sunset, let date = WindSenseiTime.parse(sunset) {
                return "Sunset \(WindSenseiFormat.time(date))"
            }
            if !isToday, let sunrise = info.sunrise, let date = WindSenseiTime.parse(sunrise) {
                return "Sunrise \(WindSenseiFormat.time(date))"
            }
            return nil
        }()
        let window = info.map { "Session \(WindSenseiFormat.hour($0.windowStart))–\(WindSenseiFormat.hour($0.windowEnd + 1))" } ?? ""
        return HStack {
            Text("\(isToday ? "Today" : "Tomorrow") · \(window)")
            Spacer()
            if let sun { Text(sun) }
        }
        .font(.ui(6.5, weight: .semibold))
        .tracking(0.3)
        .textCase(.uppercase)
        .foregroundStyle(.white.opacity(0.45))
    }

    /// Today's session-window hours; once they have all gone by, tomorrow's.
    private static func window(for spot: WindSenseiSpot, now: Date) -> ([(WindSenseiHour, Date)], Date) {
        let calendar = Calendar.current
        let parsed: [(WindSenseiHour, Date)] = (spot.hourly ?? []).compactMap { hour in
            WindSenseiTime.parse(hour.time).map { (hour, $0) }
        }
        func window(on day: Date) -> [(WindSenseiHour, Date)] {
            guard let info = spot.days?[WindSenseiTime.key(for: day)], info.windowEnd >= info.windowStart else { return [] }
            return parsed.filter { _, date in
                calendar.isDate(date, inSameDayAs: day) && (info.windowStart...info.windowEnd).contains(calendar.component(.hour, from: date))
            }
        }
        let today = window(on: now)
        let todayIsOver = today.allSatisfy { $0.1.addingTimeInterval(3600) <= now }
        if !today.isEmpty, !todayIsOver { return (today, now) }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) {
            let hours = window(on: tomorrow)
            if !hours.isEmpty { return (hours, tomorrow) }
        }
        return (today, now)
    }
}

enum WindSenseiFormat {
    /// WindSensei's theme: sky for nothing, teal, green, emerald for excellent.
    static func color(_ quality: String?) -> Color {
        switch quality?.lowercased() {
        case "excellent": return Color(red: 5 / 255, green: 150 / 255, blue: 105 / 255)
        case "good": return Color(red: 34 / 255, green: 197 / 255, blue: 94 / 255)
        case "medium": return Color(red: 20 / 255, green: 184 / 255, blue: 166 / 255)
        default: return Color(red: 14 / 255, green: 165 / 255, blue: 233 / 255)
        }
    }

    /// The grade as WindSensei words it.
    static func word(_ quality: String?) -> String {
        switch quality?.lowercased() {
        case "excellent": return "Excellent"
        case "good": return "Good"
        case "medium": return "Medium"
        case "bad", "poor": return "Not rideable"
        default: return "No grade"
        }
    }

    static func rank(_ quality: String) -> Int {
        switch quality.lowercased() {
        case "excellent": return 3
        case "good": return 2
        case "medium": return 1
        default: return 0
        }
    }

    static func age(_ date: Date, now: Date) -> String {
        let minutes = Int(now.timeIntervalSince(date) / 60)
        switch minutes {
        case ..<1: return "just now"
        case ..<60: return "\(minutes) min ago"
        case ..<(48 * 60): return minutes % 60 < 5 ? "\(minutes / 60) h ago" : "\(minutes / 60) h \(minutes % 60) min ago"
        default: return "\(minutes / (24 * 60)) d ago"
        }
    }

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    static func time(_ date: Date) -> String { clock.string(from: date) }

    /// "17:00" from an hour of the day.
    static func hour(_ hour: Int) -> String {
        String(format: "%02d:00", ((hour % 24) + 24) % 24)
    }

    /// "14–17" for a block; `endHour` is exclusive, which is what a range reads as.
    static func range(_ block: WindSenseiBlock) -> String {
        "\(block.startHour)–\(block.endHour)"
    }
}

private extension String {
    var lowercasedFirst: String {
        guard let first = first else { return self }
        return first.lowercased() + dropFirst()
    }
}

/// The tab's label: the first spot's wind, as WindSensei's own menu bar item shows it. A filled
/// disc in the grade's colour when it's rideable, an open circle when marginal, the bare glyph
/// otherwise; then speed and compass direction. The station's reading while it's fresh, else
/// this hour's forecast. Before the first fetch it's just the word.
struct WindSenseiTabLabel: View {
    @ObservedObject var plugin: WindSenseiPlugin

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            if let spot = plugin.spots.first {
                let wind = WindReading(spot: spot, now: context.date)
                HStack(spacing: 4) {
                    icon(wind.quality)
                    Text("\(wind.speed) \(Self.compass(wind.direction))")
                        .monospacedDigit()
                }
                .accessibilityLabel("Wind: \(wind.speed) knots from \(Self.compass(wind.direction)), \(WindSenseiFormat.word(wind.quality))")
            } else {
                Text(plugin.title)
            }
        }
    }

    @ViewBuilder
    private func icon(_ quality: String?) -> some View {
        let color = WindSenseiFormat.color(quality)
        switch quality?.lowercased() {
        case "good", "excellent":
            Image(systemName: "wind.circle.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, color)
                .font(.ui(12, weight: .semibold))
        case "medium":
            Image(systemName: "wind.circle")
                .foregroundStyle(color)
                .font(.ui(12, weight: .semibold))
        default:
            Image(systemName: "wind")
                .font(.ui(10, weight: .semibold))
        }
    }

    static func compass(_ degrees: Int) -> String {
        let points = ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE",
                      "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"]
        let index = Int((Double(degrees) + 11.25) / 22.5) % 16
        return points[(index + 16) % 16]
    }
}
