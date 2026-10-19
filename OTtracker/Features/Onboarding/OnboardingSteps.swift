import SwiftUI
import OTCore

// MARK: - Progress

/// Segmented bar plus "Step n of m" under the navigation title.
struct OnboardingProgressBar: View {
    let step: Int
    let count: Int

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                ForEach(0..<count, id: \.self) { index in
                    Capsule()
                        .fill(index <= step ? Color.accentColor : Color.secondary.opacity(0.25))
                        .frame(height: 4)
                }
            }
            Text("Step \(step + 1) of \(count)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }
}

// MARK: - Step 0: Welcome

struct OnboardingWelcomeStep: View {
    var body: some View {
        Form {
            Section {
                VStack(spacing: 12) {
                    Image(systemName: "clock.badge.checkmark")
                        .font(.system(size: 64))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(Color.accentColor)
                    Text("OTtracker")
                        .font(.largeTitle.bold())
                    Text("An honest ledger of extra time worked and time off taken.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .listRowBackground(Color.clear)
            }
            Section {
                OnboardingBullet(systemImage: "location.fill",
                                 text: "Your work locations log arrivals and departures automatically")
                OnboardingBullet(systemImage: "timer",
                                 text: "Timers for work anywhere else")
                OnboardingBullet(systemImage: "tablecells",
                                 text: "Everything rolls into one time bank you can export to Excel")
            } footer: {
                Text("Everything stays on your phone (and in your own iCloud Drive if you keep backups on); nothing is ever sent to a server.")
            }
        }
    }
}

/// Icon + sentence row used on the Welcome step.
struct OnboardingBullet: View {
    let systemImage: String
    let text: String

    var body: some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(Color.accentColor)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Step 1: Schedule

private enum OnboardingScheduleSheet: Identifiable {
    case new
    case edit(ScheduleVersion)

    var id: String {
        switch self {
        case .new: return "new"
        case .edit(let version): return version.id.uuidString
        }
    }
}

struct OnboardingScheduleStep: View {
    @Environment(AppModel.self) private var model
    @State private var sheet: OnboardingScheduleSheet?

    /// The version in force today, else the latest one (a new version may start in the future).
    private var currentVersion: ScheduleVersion? {
        if let today = model.store.scheduleVersion(for: model.today) { return today }
        return model.store.schedules.max { $0.effectiveFrom < $1.effectiveFrom }
    }

    var body: some View {
        Form {
            Section {
                Text("Set the hours you are expected to be at work. Anything outside them is counted.")
            } footer: {
                Text("Staying late adds to your balance. Arriving late, leaving early or stepping out mid-day subtracts. Arriving early only counts when you ask for it that day.")
            }

            if let version = currentVersion {
                Section {
                    ForEach(Weekday.ordered(startingOn: .sunday), id: \.self) { weekday in
                        LabeledContent(weekday.name) {
                            Text(hoursText(version[weekday]))
                                .monospacedDigit()
                                .foregroundStyle(version[weekday].isWorkday ? Color.primary : Color.secondary)
                        }
                    }
                } header: {
                    Text("Your week")
                } footer: {
                    Text("Effective from \(Format.dayWithYear(version.effectiveFrom, model.calendar)). \(Format.hm(weeklyExpected(version))) expected per week.")
                }
                Section {
                    Button {
                        sheet = .edit(version)
                    } label: {
                        Label("Edit schedule", systemImage: "pencil")
                    }
                }
            } else {
                Section {
                    Button {
                        sheet = .new
                    } label: {
                        Label("Set up schedule", systemImage: "calendar.badge.plus")
                    }
                } footer: {
                    Text("Required before you continue. Days you do not work stay off, and each weekday can have its own hours.")
                }
            }
        }
        .sheet(item: $sheet) { item in
            switch item {
            case .new:
                ScheduleEditorView(version: nil)
            case .edit(let version):
                ScheduleEditorView(version: version)
            }
        }
    }

    /// "7:00 AM – 3:30 PM" or "Off".
    private func hoursText(_ schedule: WeekdaySchedule) -> String {
        guard schedule.isWorkday else { return "Off" }
        let start = Format.time(schedule.start.date(on: model.today, calendar: model.calendar), model.calendar)
        let end = Format.time(schedule.end.date(on: model.today, calendar: model.calendar), model.calendar)
        return "\(start) – \(end)"
    }

    private func weeklyExpected(_ version: ScheduleVersion) -> Int {
        version.days.reduce(0) { $0 + $1.expectedSeconds }
    }
}

// MARK: - Step 2: Work location

private enum OnboardingLocationSheet: Identifiable {
    case new
    case edit(WorkLocation)

    var id: String {
        switch self {
        case .new: return "new"
        case .edit(let location): return location.id.uuidString
        }
    }
}

struct OnboardingLocationStep: View {
    @Environment(AppModel.self) private var model
    @State private var sheet: OnboardingLocationSheet?

    var body: some View {
        Form {
            Section {
                Text("A work location is a circle on the map: when your phone enters it you have arrived, and when it leaves you have left. For a big site, use a radius that covers the parking lot, because leaving the lot counts as leaving.")
            }

            if !model.store.locations.isEmpty {
                Section("Your locations") {
                    ForEach(model.store.locations) { location in
                        Button {
                            sheet = .edit(location)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(location.name)
                                    Text("\(Int(location.radiusMeters.rounded())) m radius")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if !location.isActive {
                                    TagView(text: "Inactive", color: .secondary)
                                }
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                }
            }

            Section {
                Button {
                    sheet = .new
                } label: {
                    Label("Add work location", systemImage: "mappin.and.ellipse")
                }
            } footer: {
                if model.store.locations.isEmpty {
                    Text("You can add it later in Settings.")
                } else {
                    Text("Add every site you work at. Going straight from one site to another counts as work time.")
                }
            }
        }
        .sheet(item: $sheet) { item in
            switch item {
            case .new:
                LocationEditorView(location: nil)
            case .edit(let location):
                LocationEditorView(location: location)
            }
        }
    }
}
