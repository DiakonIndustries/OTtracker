import SwiftUI
import OTCore

extension Color {
    /// Positive balance / extra time.
    static let positive = Color.green
    /// Deficit / deducted time.
    static let negative = Color.red
}

/// A signed duration coloured by sign: green for extra, red for deficit, secondary for zero.
struct DeltaText: View {
    let seconds: Int
    var font: Font = .body
    var style: Style = .hm

    enum Style { case hm, clock }

    var body: some View {
        Text(style == .hm ? Format.hm(seconds, signed: true) : Format.clock(seconds, signed: true))
            .font(font)
            .monospacedDigit()
            .foregroundStyle(seconds > 0 ? Color.positive : (seconds < 0 ? Color.negative : Color.secondary))
    }
}

/// Hours and minutes wheels bound to a number of seconds.
struct DurationPicker: View {
    @Binding var seconds: Int
    var maxHours: Int = 24

    var body: some View {
        HStack(spacing: 0) {
            Picker("Hours", selection: hours) {
                ForEach(0...maxHours, id: \.self) { Text("\($0) h").tag($0) }
            }
            .pickerStyle(.wheel)
            .frame(maxWidth: .infinity)
            .clipped()
            Picker("Minutes", selection: minutes) {
                ForEach(0..<60, id: \.self) { Text("\($0) m").tag($0) }
            }
            .pickerStyle(.wheel)
            .frame(maxWidth: .infinity)
            .clipped()
        }
        .frame(height: 140)
    }

    private var hours: Binding<Int> {
        Binding(get: { max(0, seconds) / 3600 }, set: { seconds = $0 * 3600 + (max(0, seconds) % 3600) })
    }

    private var minutes: Binding<Int> {
        Binding(get: { (max(0, seconds) % 3600) / 60 }, set: { seconds = (max(0, seconds) / 3600) * 3600 + $0 * 60 })
    }
}

/// Label + value on one line, value in secondary colour.
struct ValueRow: View {
    let title: String
    let value: String

    init(_ title: String, _ value: String) {
        self.title = title
        self.value = value
    }

    var body: some View {
        LabeledContent(title) {
            Text(value).monospacedDigit().foregroundStyle(.secondary)
        }
    }
}

/// Label + signed duration on one line.
struct DeltaRow: View {
    let title: String
    let seconds: Int

    init(_ title: String, _ seconds: Int) {
        self.title = title
        self.seconds = seconds
    }

    var body: some View {
        LabeledContent(title) { DeltaText(seconds: seconds) }
    }
}

/// Centered placeholder for empty lists.
struct EmptyStateView: View {
    let systemImage: String
    let title: String
    let message: String

    var body: some View {
        ContentUnavailableView(title, systemImage: systemImage, description: Text(message))
    }
}

/// A date-and-time picker that keeps the calendar/time zone of the store.
struct DateTimeField: View {
    let title: String
    @Binding var date: Date
    var calendar: Calendar

    var body: some View {
        DatePicker(title, selection: $date, displayedComponents: [.date, .hourAndMinute])
            .environment(\.calendar, calendar)
            .environment(\.timeZone, calendar.timeZone)
    }
}

/// Small coloured capsule used for day kinds and flags.
struct TagView: View {
    let text: String
    var color: Color = .secondary

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}

extension DayKind {
    var color: Color {
        switch self {
        case .workday: return .blue
        case .weekend: return .secondary
        case .holiday: return .orange
        case .dayOff: return .purple
        case .excused: return .gray
        }
    }
}

extension DayFlag {
    var label: String {
        switch self {
        case .noShow: return "No show"
        case .openPresence: return "Still here"
        case .earlyArrivalUncounted: return "Early, not counted"
        case .gapUndecided: return "Gap to decide"
        case .graceApplied: return "Grace"
        case .overlappingLocations: return "Overlap"
        case .future: return "Upcoming"
        case .inProgress: return "In progress"
        }
    }
}
