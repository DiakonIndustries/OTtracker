import SwiftUI
import OTCore

/// A tinted banner pointing at the Inbox while questions are waiting.
struct HomeInboxNudge: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button {
            model.selectedTab = .inbox
        } label: {
            HStack(spacing: 14) {
                IconBadge(systemImage: "tray.full.fill", color: .orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(HomeInboxNudge.title(count: model.inboxCount))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text("Confirm, adjust or dismiss in the Inbox")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .card()
    }

    static func title(count: Int) -> String {
        count == 1 ? "1 thing to review" : "\(count) things to review"
    }
}

#Preview {
    HomeInboxNudge().padding().environment(AppModel.preview())
}
