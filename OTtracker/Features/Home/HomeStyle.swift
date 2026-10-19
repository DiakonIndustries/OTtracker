import SwiftUI
import OTCore

/// Navigation values pushed from the Today tab's stack.
enum HomeRoute: Hashable {
    case day(DayKey)
}

/// The "add" editors reachable from the Today toolbar.
enum HomeAddSheet: String, Identifiable, CaseIterable {
    case presence, manual, timeOff, adjustment

    var id: String { rawValue }

    var title: String {
        switch self {
        case .presence: return "Arrival or departure"
        case .manual: return "Work elsewhere"
        case .timeOff: return "Time off"
        case .adjustment: return "Adjustment"
        }
    }

    var systemImage: String {
        switch self {
        case .presence: return "mappin.and.ellipse"
        case .manual: return "laptopcomputer"
        case .timeOff: return "beach.umbrella"
        case .adjustment: return "plusminus"
        }
    }
}
