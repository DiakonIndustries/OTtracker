import SwiftUI
import UIKit

/// The app's visual system: page and card colours, the hero gradient, spacing and shape.
enum Theme {
    static let page = Color(uiColor: .systemGroupedBackground)
    static let card = Color(uiColor: .secondarySystemGroupedBackground)
    static let radius: CGFloat = 22
    static let padding: CGFloat = 18
    static let spacing: CGFloat = 14

    /// Blue when the bank is in credit, warm red when it is in debt.
    static func heroGradient(negative: Bool) -> LinearGradient {
        let colors: [Color] = negative
            ? [Color(red: 0.55, green: 0.14, blue: 0.20), Color(red: 0.88, green: 0.36, blue: 0.30)]
            : [Color(red: 0.08, green: 0.22, blue: 0.55), Color(red: 0.18, green: 0.46, blue: 0.93)]
        return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

/// A rounded, softly shadowed surface on the grouped page background.
struct CardModifier: ViewModifier {
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content
            .padding(Theme.padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .shadow(color: .black.opacity(scheme == .dark ? 0 : 0.06), radius: 14, x: 0, y: 6)
    }
}

extension View {
    /// Wraps the view in a card.
    func card() -> some View { modifier(CardModifier()) }
}

/// Small coloured dot used for live status ("at work", "running").
struct StatusDot: View {
    let color: Color

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 9, height: 9)
            .overlay(Circle().stroke(color.opacity(0.3), lineWidth: 5))
    }
}

/// A symbol inside a softly tinted circle.
struct IconBadge: View {
    let systemImage: String
    var color: Color = .accentColor
    var size: CGFloat = 40

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .background(color.opacity(0.15), in: Circle())
    }
}

/// A signed duration in a tinted capsule: green for extra, red for deficit, grey for zero.
struct DeltaPill: View {
    let seconds: Int
    var font: Font = .subheadline.weight(.semibold)

    var body: some View {
        let color: Color = seconds > 0 ? .positive : (seconds < 0 ? .negative : .secondary)
        Text(Format.hm(seconds, signed: true))
            .font(font)
            .monospacedDigit()
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(color.opacity(0.13), in: Capsule())
    }
}
