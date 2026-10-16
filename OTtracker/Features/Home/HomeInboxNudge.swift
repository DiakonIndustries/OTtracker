import SwiftUI
import OTCore

/// One-line pointer to the Inbox tab while questions are waiting.
struct HomeInboxNudge: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button {
            model.selectedTab = .inbox
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "tray.full")
                    .font(.title3)
                    .foregroundStyle(.orange)
                Text(HomeInboxNudge.title(count: model.inboxCount))
                    .font(.subheadline.weight(.medium))
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .homeCard()
    }

    static func title(count: Int) -> String {
        count == 1 ? "1 item needs a decision" : "\(count) items need a decision"
    }
}

#Preview {
    HomeInboxNudge().environment(AppModel.preview())
}
