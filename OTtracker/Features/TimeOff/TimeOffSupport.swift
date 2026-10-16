import SwiftUI
import OTCore

/// Labels shared by the Time Off screens.
enum TimeOffFormat {
    static func kindLabel(_ kind: TimeOffKind) -> String {
        switch kind {
        case .pto: return "PTO"
        case .personal: return "Personal"
        case .flex: return "Flex (from bank)"
        case .other: return "Other"
        }
    }

    static func periodLabel(_ period: AccrualPeriod) -> String {
        switch period {
        case .weekly: return "Weekly"
        case .biweekly: return "Every 2 weeks"
        case .monthly: return "Monthly"
        case .yearly: return "Yearly"
        }
    }

    /// "week", "2 weeks", "month", "year" — for sentences like "6h 40m every month".
    static func periodNoun(_ period: AccrualPeriod) -> String {
        switch period {
        case .weekly: return "week"
        case .biweekly: return "2 weeks"
        case .monthly: return "month"
        case .yearly: return "year"
        }
    }
}

/// DayKey <-> Date bridging for date-only pickers, always in the store's calendar.
enum TimeOffDates {
    static func dateBinding(_ day: Binding<DayKey>, calendar: Calendar) -> Binding<Date> {
        Binding(
            get: { Format.noon(day.wrappedValue, calendar) },
            set: { newValue in day.wrappedValue = DayKey(newValue, calendar: calendar) }
        )
    }
}

/// Sheet payload for the time-off editor: new entry, new flex day, or edit.
struct TimeOffEditorPayload: Identifiable {
    let id = UUID()
    var entry: TimeOffEntry?
    var defaultDay: DayKey
    var defaultKind: TimeOffKind?
}

/// Sheet payload for the holiday editor (nil holiday = new).
struct TimeOffHolidayPayload: Identifiable {
    let id = UUID()
    var holiday: Holiday?
}

/// Sheet payload for the type editor (nil type = new).
struct TimeOffTypePayload: Identifiable {
    let id = UUID()
    var type: TimeOffType?
}

/// A file handed to the share sheet.
struct TimeOffShareFile: Identifiable {
    let id = UUID()
    var url: URL
}

/// Wraps the model's import preview so it can drive `.sheet(item:)`.
struct TimeOffHolidayImportPreview: Identifiable {
    let id = UUID()
    var preview: ImportPreview
}
