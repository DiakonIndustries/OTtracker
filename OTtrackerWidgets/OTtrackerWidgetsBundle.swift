import SwiftUI
import WidgetKit
import OTCore

@main
struct OTtrackerWidgetsBundle: WidgetBundle {
    var body: some Widget {
        BalanceWidget()
    }
}

struct BalanceEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

struct BalanceProvider: TimelineProvider {
    func placeholder(in context: Context) -> BalanceEntry {
        BalanceEntry(date: Date(), snapshot: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (BalanceEntry) -> Void) {
        completion(BalanceEntry(date: Date(), snapshot: .placeholder))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<BalanceEntry>) -> Void) {
        let entry = BalanceEntry(date: Date(), snapshot: .placeholder)
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(1800))))
    }
}

struct BalanceWidgetView: View {
    let entry: BalanceEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Balance").font(.caption).foregroundStyle(.secondary)
            Text(DurationFormat.hm(entry.snapshot.balanceSeconds, signed: true))
                .font(.title2.bold().monospacedDigit())
            Spacer(minLength: 0)
            Text("This month " + DurationFormat.hm(entry.snapshot.monthGrossExtraSeconds, signed: true))
                .font(.caption2).foregroundStyle(.secondary)
        }
        .containerBackground(for: .widget) { Color("WidgetBackground") }
    }
}

struct BalanceWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: AppIdentifiers.widgetKind, provider: BalanceProvider()) { entry in
            BalanceWidgetView(entry: entry)
        }
        .configurationDisplayName("Overtime balance")
        .description("Your current bank balance and this month's extra time.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
