import SwiftUI
import Charts
import OTCore

/// One bar of the trend chart: a week or a month, net change in hours.
struct HomeBar: Identifiable, Hashable {
    let id: DayKey
    let label: String
    let seconds: Int

    var hours: Double { Double(seconds) / 3600 }
}

/// Which period the trend chart groups by.
enum HomeChartRange: String, CaseIterable, Identifiable {
    case weeks = "Weeks"
    case months = "Months"

    var id: String { rawValue }
}

/// Net change per week (last 8) or per month (last 12), green above zero and red below.
struct HomeChartsView: View {
    @Environment(AppModel.self) private var model
    @State private var range: HomeChartRange = .weeks

    var body: some View {
        let bars = range == .weeks ? weekBars : monthBars
        let total = bars.reduce(0) { $0 + $1.seconds }
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Trend")
                        .font(.headline)
                    HStack(spacing: 4) {
                        Text(range == .weeks ? "Last 8 weeks" : "Last 12 months")
                        Text("·")
                        Text(Format.hm(total, signed: true))
                            .fontWeight(.semibold)
                            .foregroundStyle(total > 0 ? Color.positive : (total < 0 ? Color.negative : Color.secondary))
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Picker("Range", selection: $range) {
                    ForEach(HomeChartRange.allCases) { r in
                        Text(r.rawValue).tag(r)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 170)
            }
            Chart(bars) { bar in
                BarMark(
                    x: .value("Period", bar.label),
                    y: .value("Hours", bar.hours),
                    width: .ratio(0.62)
                )
                .foregroundStyle(bar.seconds >= 0 ? Color.positive.gradient : Color.negative.gradient)
                .cornerRadius(6)
            }
            .chartXScale(domain: bars.map { $0.label })
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                    AxisValueLabel {
                        Text(HomeChartsView.hoursLabel(value.as(Double.self)))
                    }
                }
            }
            .chartXAxis {
                AxisMarks { _ in
                    AxisValueLabel()
                }
            }
            .frame(height: 160)
            .animation(.snappy, value: range)
        }
        .card()
    }

    /// Σ delta over each of the last 8 weeks (week start from the store's calendar), oldest first.
    private var weekBars: [HomeBar] {
        let cal = model.calendar
        let today = model.today
        let thisWeek = Format.weekStart(of: today, cal)
        let start0 = model.trackingStart
        var out: [HomeBar] = []
        for back in stride(from: 7, through: 0, by: -1) {
            let start = thisWeek.adding(days: -7 * back, calendar: cal)
            var total = 0
            for offset in 0..<7 {
                let day = start.adding(days: offset, calendar: cal)
                if day <= today && day >= start0 {
                    total += model.dayResult(for: day).deltaSeconds
                }
            }
            out.append(HomeBar(id: start, label: HomeChartFormat.weekLabel(start, cal), seconds: total))
        }
        return out
    }

    /// Σ delta per calendar month for the last 12 months, oldest first.
    private var monthBars: [HomeBar] {
        let cal = model.calendar
        let today = model.today
        var firsts: [DayKey] = []
        var cursor = Format.firstOfMonth(today)
        for _ in 0..<12 {
            firsts.append(cursor)
            cursor = HomeChartsView.previousMonth(cursor)
        }
        var out: [HomeBar] = []
        for first in firsts.reversed() {
            let last = min(Format.lastOfMonth(first, cal), today)
            var net = 0
            let from = max(first, model.trackingStart)
            if from <= last {
                for day in DayKey.days(from: from, through: last, calendar: cal) {
                    net += model.dayResult(for: day).deltaSeconds
                }
            }
            out.append(HomeBar(id: first, label: HomeChartFormat.shortMonth(first, cal), seconds: net))
        }
        return out
    }

    static func hoursLabel(_ hours: Double?) -> String {
        guard let hours else { return "" }
        return "\(Int(hours.rounded()))h"
    }

    static func previousMonth(_ first: DayKey) -> DayKey {
        if first.month == 1 { return DayKey(year: first.year - 1, month: 12, day: 1) }
        return DayKey(year: first.year, month: first.month - 1, day: 1)
    }
}

/// Axis labels in the store's calendar / time zone.
enum HomeChartFormat {
    private static var monthFormatters: [String: DateFormatter] = [:]

    /// "Oct"
    static func shortMonth(_ day: DayKey, _ calendar: Calendar) -> String {
        let key = calendar.timeZone.identifier
        if let cached = monthFormatters[key] {
            return cached.string(from: Format.noon(day, calendar))
        }
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = Locale.current
        f.setLocalizedDateFormatFromTemplate("MMM")
        monthFormatters[key] = f
        return f.string(from: Format.noon(day, calendar))
    }

    /// "Oct 12": the start day of `Format.weekRange`.
    static func weekLabel(_ start: DayKey, _ calendar: Calendar) -> String {
        let range = Format.weekRange(start: start, calendar)
        return range.components(separatedBy: " – ").first ?? range
    }
}

#Preview {
    HomeChartsView().padding().environment(AppModel.preview())
}
