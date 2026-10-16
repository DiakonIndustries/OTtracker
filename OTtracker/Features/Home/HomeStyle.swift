import SwiftUI
import UIKit
import OTCore

/// Navigation values pushed from the Home tab's stack.
enum HomeRoute: Hashable {
    case day(DayKey)
}

/// Shared colours and metrics for the Home cards.
enum HomeStyle {
    static let pageBackground = Color(uiColor: .systemGroupedBackground)
    static let cardBackground = Color(uiColor: .secondarySystemGroupedBackground)
    static let cardCornerRadius: CGFloat = 16
    static let cardSpacing: CGFloat = 16

    /// Capsule colour for a day flag.
    static func color(for flag: DayFlag) -> Color {
        switch flag {
        case .noShow: return .negative
        case .openPresence: return .blue
        case .earlyArrivalUncounted: return .orange
        case .gapUndecided: return .orange
        case .graceApplied: return .secondary
        case .overlappingLocations: return .orange
        case .future: return .secondary
        case .inProgress: return .blue
        }
    }
}

/// Rounded, grouped-background container used by every Home card.
struct HomeCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(HomeStyle.cardBackground,
                        in: RoundedRectangle(cornerRadius: HomeStyle.cardCornerRadius, style: .continuous))
    }
}

extension View {
    /// Wraps the view in a Home card.
    func homeCard() -> some View {
        modifier(HomeCardModifier())
    }
}
