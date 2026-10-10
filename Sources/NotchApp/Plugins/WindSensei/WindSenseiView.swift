import SwiftUI

/// The Wind tab: one row per favourite spot, each with the latest reading, the next rideable
/// block, and a bar for every hour of today's session window painted with the server's grade.
/// The layout follows WindSensei's day-graph widget, trimmed to notch height.
struct WindSenseiView: View {
    @ObservedObject var plugin: WindSenseiPlugin

    var body: some View {
        // Ages ("12m ago") and the current-hour highlight move with the clock, not with the
        // data, so the rows are re-evaluated once a minute.
        TimelineView(.periodic(from: .now, by: 60)) { context in
            VStack(spacing: 6) {
                if plugin.spots.isEmpty {
                    placeholder
                } else {
                    ScrollView(.vertical) {
                        VStack(spacing: 8) {
                            ForEach(plugin.spots) { spot in
                                SpotRow(spot: spot, now: context.date)
                            }
                        }
                        .padding(.trailing, 4)
                    }
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
        .font(.system(size: 11))
        .foregroundStyle(.white.opacity(0.5))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func footer(now: Date) -> some View {
        HStack(spacing: 6) {
            if let error = plugin.lastError, !plugin.spots.isEmpty {
                Text(error).foregroundStyle(.red.opacity(0.9)).lineLimit(1)
            } else if let fetchedAt = plugin.fetchedAt {
                Text("Updated \(WindSenseiFormat.age(fetchedAt, now: now))")
            }
            Spacer()
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
        .font(.system(size: 9))
        .foregroundStyle(.white.opacity(0.4))
    }
}

private struct SpotRow: View {
    let spot: WindSenseiSpot
    let now: Date

    var body: some View {
        let strip = Self.strip(for: spot, now: now)
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(spot.name)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                reading
                Spacer(minLength: 4)
                nextBlock
            }
            WindStrip(hours: strip.hours, now: now, label: strip.label)
                .frame(height: 22)
        }
    }

    /// The station reading, aged; the current forecast hour when the spot has no station.
    @ViewBuilder
    private var reading: some View {
        if let observed = spot.observed, let date = observed.date {
            let stale = now.timeIntervalSince(date) > WindSenseiObserved.freshness
            wind(observed.windSpeed, gust: observed.windGust, direction: observed.windDirection, quality: observed.quality)
            Text(WindSenseiFormat.age(date, now: now))
                .font(.system(size: 9))
                .foregroundStyle(stale ? Color.orange : .white.opacity(0.45))
        } else {
            wind(spot.current.windSpeed, gust: spot.current.windGust, direction: spot.current.windDirection, quality: spot.current.quality)
            Text("forecast")
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.45))
        }
    }

    private func wind(_ speed: Int, gust: Int?, direction: Int, quality: String?) -> some View {
        HStack(spacing: 3) {
            Text("\(speed)")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(WindSenseiFormat.color(quality))
            if let gust, gust > speed {
                Text("G\(gust)")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
            }
            Text("kn")
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.5))
            // Wind direction is where it blows from; the arrow points where it goes.
            Image(systemName: "arrow.up")
                .font(.system(size: 9, weight: .semibold))
                .rotationEffect(.degrees(Double(direction) + 180))
                .foregroundStyle(.white.opacity(0.7))
        }
    }

    /// The first block still ahead. Started blocks read as "until", coming ones as a range.
    @ViewBuilder
    private var nextBlock: some View {
        let next = (spot.timeBlocks ?? []).first { block in
            guard let end = WindSenseiTime.parse(block.endTime) else { return false }
            return end > now
        }
        if let next {
            let started = WindSenseiTime.parse(next.startTime).map { $0 <= now } ?? false
            let when = started
                ? "until \(WindSenseiTime.clock(next.endHour))"
                : "\(WindSenseiTime.clock(next.startHour))–\(WindSenseiTime.clock(next.endHour))"
            Text("\(next.quality.capitalized) \(when)")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(WindSenseiFormat.color(next.quality))
                .lineLimit(1)
        }
    }

    /// Today's session-window hours; once they have all gone by, tomorrow's, labelled.
    private static func strip(for spot: WindSenseiSpot, now: Date) -> (hours: [(WindSenseiHour, Date)], label: String?) {
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
        if !today.isEmpty, !todayIsOver { return (today, nil) }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) {
            let hours = window(on: tomorrow)
            if !hours.isEmpty { return (hours, "Tomorrow") }
        }
        return (today, nil)
    }
}

/// Wind bars, one per hour: the average in the hour's colour, the gust above it lighter, the
/// current hour on a pale backdrop. Scale is the strongest gust in view, at least 20 knots so a
/// calm day doesn't fill the strip.
private struct WindStrip: View {
    let hours: [(WindSenseiHour, Date)]
    let now: Date
    let label: String?

    var body: some View {
        if hours.isEmpty {
            Text("No session window today")
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.35))
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            let top = max(20, hours.map { max($0.0.windSpeed, $0.0.windGust ?? 0) }.max() ?? 0)
            HStack(alignment: .bottom, spacing: 4) {
                Text(WindSenseiTime.clock(Calendar.current.component(.hour, from: hours[0].1)))
                    .font(.system(size: 8))
                    .foregroundStyle(.white.opacity(0.4))
                    .frame(width: 26, alignment: .trailing)
                GeometryReader { geo in
                    HStack(alignment: .bottom, spacing: 1) {
                        ForEach(Array(hours.enumerated()), id: \.offset) { _, entry in
                            let (hour, date) = entry
                            let isCurrent = date <= now && now < date.addingTimeInterval(3600)
                            VStack(spacing: 0) {
                                Spacer(minLength: 0)
                                if let gust = hour.windGust, gust > hour.windSpeed {
                                    RoundedRectangle(cornerRadius: 1)
                                        .fill(WindSenseiFormat.color(hour.barQuality).opacity(0.4))
                                        .frame(height: CGFloat(gust - hour.windSpeed) / CGFloat(top) * geo.size.height)
                                }
                                RoundedRectangle(cornerRadius: 1)
                                    .fill(WindSenseiFormat.color(hour.barQuality))
                                    .frame(height: CGFloat(hour.windSpeed) / CGFloat(top) * geo.size.height)
                            }
                            .frame(maxWidth: .infinity)
                            .background(RoundedRectangle(cornerRadius: 2).fill(Color.white.opacity(isCurrent ? 0.18 : 0)))
                        }
                    }
                }
                Text(WindSenseiTime.clock(Calendar.current.component(.hour, from: hours[hours.count - 1].1)))
                    .font(.system(size: 8))
                    .foregroundStyle(.white.opacity(0.4))
                    .frame(width: 26, alignment: .leading)
                if let label {
                    Text(label)
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(.cyan)
                }
            }
        }
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

    static func age(_ date: Date, now: Date) -> String {
        let minutes = Int(now.timeIntervalSince(date) / 60)
        switch minutes {
        case ..<1: return "just now"
        case ..<60: return "\(minutes)m ago"
        case ..<(48 * 60): return "\(minutes / 60)h ago"
        default: return "\(minutes / (24 * 60))d ago"
        }
    }
}
