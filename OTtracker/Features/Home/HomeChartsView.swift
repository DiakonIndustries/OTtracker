import SwiftUI
import Charts
import OTCore

/// One bar of the weekly chart: the week starting `start`, net delta in hours.
struct HomeWeekBar: Identifiable, Hashable {
    let start: DayKey
    let label: String
    let hours: Double

    var id: DayKey { start }
}

/// One month of the trend chart.
struct HomeMonthPoint: Identifiable, Hashable {
    let month: DayKey
    let label: String
    let grossExtraHours: Double
    let netHours: Double

    var id: DayKey { month }
}

private let homeGrossSeries = "Gross extra"
private let homeNetSeries = "Net delta"

/// Weekly bars for the last 8 weeks and the monthly trend for the last 12 months.
struct HomeChartsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            weeklySection
            monthlySection
        }
        .homeCard()
    }

    // MARK: Weekly bars

    private var weeklySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Weekly")
                .font(.headline)
            Text("Net hours per week, last 8 weeks")
                .font(.caption)
                .foregroundStyle(.secondary)
            let bars = weekBars
            Chart(bars) { bar in
                BarMark(
                    x: .value("Week", bar.label),
                    y: .value("Hours", bar.hours)
                )
                .foregroundStyle(bar.hours >= 0 ? Color.positive : Color.negative)
                .cornerRadius(3)
            }
            .chartXScale(domain: bars.map { $0.label })
            .chartYAxisLabel("hours")
            .frame(height: 170)
        }
    }

    /// Σ delta over each of the last 8 weeks (week start from the store's calendar), oldest first.
    private var weekBars: [HomeWeekBar] {
        let cal = model.calendar
        let today = model.today
        let thisWeek = Format.weekStart(of: today, cal)
        var out: [HomeWeekBar] = []
        for back in stride(from: 7, through: 0, by: -1) {
            let start = thisWeek.adding(days: -7 * back, calendar: cal)
            var total = 0
            for offset in 0..<7 {
                let day = start.adding(days: offset, calendar: cal)
                if day <= today {
                    total += model.dayResult(for: day).deltaSeconds
                }
            }
            out.append(HomeWeekBar(start: start,
                                   label: HomeChartFormat.weekLabel(start, cal),
                                   hours: Double(total) / 3600))
        }
        return out
    }

    // MARK: Monthly trend

    private var monthlySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Monthly trend")
                .font(.headline)
            Text("Gross extra time vs net change, last 12 months")
                .font(.caption)
                .foregroundStyle(.secondary)
            let points = monthPoints
            Chart {
                ForEach(points) { point in
                    BarMark(
                        x: .value("Month", point.label),
                        y: .value("Net hours", point.netHours)
                    )
                    .foregroundStyle(by: .value("Series", homeNetSeries))
                    .opacity(0.35)
                    LineMark(
                        x: .value("Month", point.label),
                        y: .value("Gross extra hours", point.grossExtraHours)
                    )
                    .foregroundStyle(by: .value("Series", homeGrossSeries))
                    PointMark(
                        x: .value("Month", point.label),
                        y: .value("Gross extra hours", point.grossExtraHours)
                    )
                    .foregroundStyle(by: .value("Series", homeGrossSeries))
                }
            }
            .chartForegroundStyleScale([homeGrossSeries: Color.positive, homeNetSeries: Color.blue])
            .chartXScale(domain: points.map { $0.label })
            .chartYAxisLabel("hours")
            .frame(height: 190)
        }
    }

    /// Gross extra and net delta per calendar month for the last 12 months, oldest first.
    private var monthPoints: [HomeMonthPoint] {
        let cal = model.calendar
        let today = model.today
        var firsts: [DayKey] = []
        var cursor = Format.firstOfMonth(today)
        for _ in 0..<12 {
            firsts.append(cursor)
            cursor = HomeChartsView.previousMonth(cursor)
        }
        var out: [HomeMonthPoint] = []
        for first in firsts.reversed() {
            let last = min(Format.lastOfMonth(first, cal), today)
            var gross = 0
            var net = 0
            for day in DayKey.days(from: first, through: last, calendar: cal) {
                let r = model.dayResult(for: day)
                gross += r.grossExtraSeconds
                net += r.deltaSeconds
            }
            out.append(HomeMonthPoint(month: first,
                                      label: HomeChartFormat.shortMonth(first, cal),
                                      grossExtraHours: Double(gross) / 3600,
                                      netHours: Double(net) / 3600))
        }
        return out
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
    HomeChartsView().environment(AppModel.preview())
}
