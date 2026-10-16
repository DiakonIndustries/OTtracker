import SwiftUI
import UIKit
import CoreLocation
import OTCore

/// Destinations pushed from the Settings root. Value-based so deep links (`Route.locations`,
/// `Route.importFile`) can push them programmatically.
enum SettingsDestination: Hashable {
    case schedules
    case locations
    case categories
    case startingBalance
    case export
    case importFile
    case backup
    case howCounting
}

enum SettingsURLs {
    /// Opens this app's page in the system Settings app.
    static let system = URL(string: UIApplication.openSettingsURLString)!
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var path: [SettingsDestination] = []
    @State private var email = ""
    @FocusState private var emailFocused: Bool

    var body: some View {
        NavigationStack(path: $path) {
            Form {
                scheduleSection
                locationsSection
                timerSection
                rulesSection
                bankSection
                notificationsSection
                dataSection
                aboutSection
            }
            .navigationTitle("Settings")
            .navigationDestination(for: SettingsDestination.self) { destination in
                switch destination {
                case .schedules:
                    SettingsSchedulesListView()
                case .locations:
                    LocationsView()
                case .categories:
                    SettingsCategoriesView()
                case .startingBalance:
                    SettingsStartingBalanceView(initialSeconds: model.settings.bankStartingSeconds,
                                                initialAsOf: Format.noon(model.settings.bankStartingAsOf, model.calendar))
                case .export:
                    ExportView()
                case .importFile:
                    ImportView()
                case .backup:
                    BackupView()
                case .howCounting:
                    SettingsHowCountingWorksView()
                }
            }
        }
        .onAppear {
            email = model.settings.exportEmail ?? ""
            handle(route: model.pendingRoute)
        }
        .onChange(of: model.pendingRoute) { _, route in
            handle(route: route)
        }
    }

    // MARK: Sections

    private var scheduleSection: some View {
        Section {
            NavigationLink(value: SettingsDestination.schedules) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Work schedule")
                    Text(scheduleSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Schedule")
        }
    }

    private var scheduleSummary: String {
        guard let version = model.store.scheduleVersion(for: model.today) else { return "Not set" }
        return SettingsScheduleSummary.text(version, day: model.today, calendar: model.calendar)
    }

    private var locationsSection: some View {
        Section {
            NavigationLink(value: SettingsDestination.locations) {
                ValueRow("Work locations", "\(model.store.locations.count)")
            }
            SettingsLocationPermissionRow()
        } header: {
            Text("Locations")
        } footer: {
            Text("Always is required so arrivals and departures are logged while the app is closed.")
        }
    }

    private var timerSection: some View {
        Section {
            NavigationLink(value: SettingsDestination.categories) {
                ValueRow("Categories", "\(model.settings.manualCategories.count)")
            }
            Stepper(value: nudgeBinding, in: 60...720, step: 30) {
                ValueRow("Remind me after", Format.hm(model.settings.timerNudgeMinutes * 60))
            }
        } header: {
            Text("Timer")
        } footer: {
            Text("A running timer reminds you after this long, and again at each multiple, in case you forgot to stop it. It is never stopped for you. Paused time never counts.")
        }
    }

    private var rulesSection: some View {
        Section {
            Stepper(value: graceBinding, in: 0...30) {
                ValueRow("Grace at start and end", "\(model.settings.graceMinutes) min")
            }
            Stepper(value: staleBinding, in: 4...48) {
                ValueRow("Open arrival is stale after", "\(model.settings.staleOpenSessionHours) h")
            }
            Stepper(value: flapBinding, in: 0...15) {
                ValueRow("Merge quick re-entries within", "\(model.settings.flapMergeMinutes) min")
            }
            Picker("Week starts on", selection: weekStartBinding) {
                Text("Sunday").tag(Weekday.sunday)
                Text("Monday").tag(Weekday.monday)
            }
        } header: {
            Text("Rules")
        } footer: {
            Text("Grace forgives small deviations at the scheduled start and end only. Mid-day gaps are always exact.")
        }
    }

    private var bankSection: some View {
        Section {
            NavigationLink(value: SettingsDestination.startingBalance) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Starting balance")
                        Text("as of \(Format.dayWithYear(model.settings.bankStartingAsOf, model.calendar))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    DeltaText(seconds: model.settings.bankStartingSeconds)
                }
            }
        } header: {
            Text("Bank")
        }
    }

    private var notificationsSection: some View {
        Section {
            SettingsNotificationRow()
        } header: {
            Text("Notifications")
        } footer: {
            Text("Used when a departure is posted, when you arrive early, when a timer keeps running, and when a monthly export is ready.")
        }
    }

    private var dataSection: some View {
        Section {
            NavigationLink(value: SettingsDestination.export) {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            NavigationLink(value: SettingsDestination.importFile) {
                Label("Import", systemImage: "square.and.arrow.down")
            }
            NavigationLink(value: SettingsDestination.backup) {
                Label("Backup", systemImage: "icloud")
            }
            Toggle("Monthly Excel export", isOn: monthlyExportBinding)
            TextField("Email it to", text: $email)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($emailFocused)
                .onSubmit(commitEmail)
                .onChange(of: emailFocused) { _, focused in
                    if !focused { commitEmail() }
                }
        } header: {
            Text("Data")
        } footer: {
            Text("On the first launch after a month ends, OTtracker builds last month's Excel file and notifies you. iOS does not let apps send email on their own, so one tap opens a prefilled message with the file attached.")
        }
    }

    private var aboutSection: some View {
        Section {
            ValueRow("Version", "\(appVersion) (\(appBuild))")
            NavigationLink(value: SettingsDestination.howCounting) {
                Text("How counting works")
            }
        } header: {
            Text("About")
        } footer: {
            Text("Everything stays on this phone. Backups go to your own iCloud Drive.")
        }
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    private var appBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }

    // MARK: Bindings into Settings

    private var nudgeBinding: Binding<Int> {
        Binding(get: { model.settings.timerNudgeMinutes },
                set: { value in model.updateSettings { $0.timerNudgeMinutes = value } })
    }

    private var graceBinding: Binding<Int> {
        Binding(get: { model.settings.graceMinutes },
                set: { value in model.updateSettings { $0.graceMinutes = value } })
    }

    private var staleBinding: Binding<Int> {
        Binding(get: { model.settings.staleOpenSessionHours },
                set: { value in model.updateSettings { $0.staleOpenSessionHours = value } })
    }

    private var flapBinding: Binding<Int> {
        Binding(get: { model.settings.flapMergeMinutes },
                set: { value in model.updateSettings { $0.flapMergeMinutes = value } })
    }

    private var weekStartBinding: Binding<Weekday> {
        Binding(get: { model.settings.weekStartsOn },
                set: { value in model.updateSettings { $0.weekStartsOn = value } })
    }

    private var monthlyExportBinding: Binding<Bool> {
        Binding(get: { model.settings.monthlyExportEnabled },
                set: { value in model.updateSettings { $0.monthlyExportEnabled = value } })
    }

    private func commitEmail() {
        let trimmed = email.trimmingCharacters(in: .whitespaces)
        let value: String? = trimmed.isEmpty ? nil : trimmed
        guard value != model.settings.exportEmail else { return }
        model.updateSettings { $0.exportEmail = value }
    }

    // MARK: Deep links

    private func handle(route: Route?) {
        guard let route else { return }
        switch route {
        case .locations:
            model.selectedTab = .settings
            path = [.locations]
            model.consumeRoute()
        case .importFile:
            model.selectedTab = .settings
            path = [.importFile]
            model.consumeRoute()
        default:
            break
        }
    }
}

// MARK: - Permission rows

/// Location permission status with the fitting call to action. Used in Settings and Locations.
struct SettingsLocationPermissionRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.locationStatus {
        case .authorizedAlways:
            Label("Location: Always", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .authorizedWhenInUse:
            HStack {
                Text("Location: While using")
                Spacer()
                Button("Allow Always") { model.requestLocationAccess() }
                    .buttonStyle(.borderless)
            }
        case .notDetermined:
            HStack {
                Text("Location: Not set")
                Spacer()
                Button("Allow") { model.requestLocationAccess() }
                    .buttonStyle(.borderless)
            }
        case .denied, .restricted:
            HStack {
                Text("Location: Off")
                Spacer()
                Link("Open Settings", destination: SettingsURLs.system)
            }
        @unknown default:
            Text("Location: Unknown")
        }
    }
}

/// Notification permission status with an Allow button or a link to the system Settings.
struct SettingsNotificationRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.notificationsAuthorized {
            Label("Notifications allowed", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        } else {
            HStack {
                Text("Notifications off")
                Spacer()
                Button("Allow") {
                    Task { await model.requestNotificationAccess() }
                }
                .buttonStyle(.borderless)
            }
            Link("Open Settings", destination: SettingsURLs.system)
        }
    }
}

// MARK: - Starting balance

struct SettingsStartingBalanceView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var sign: Int
    @State private var magnitude: Int
    @State private var asOfDate: Date

    init(initialSeconds: Int, initialAsOf: Date) {
        _sign = State(initialValue: initialSeconds < 0 ? -1 : 1)
        _magnitude = State(initialValue: abs(initialSeconds))
        _asOfDate = State(initialValue: initialAsOf)
    }

    var body: some View {
        Form {
            Section {
                Picker("Direction", selection: $sign) {
                    Text("Extra (+)").tag(1)
                    Text("Owed (−)").tag(-1)
                }
                .pickerStyle(.segmented)
                DurationPicker(seconds: $magnitude, maxHours: 999)
                LabeledContent("Starting balance") {
                    DeltaText(seconds: sign * magnitude, font: .title3)
                }
            } footer: {
                Text("What the bank already held before you started tracking with this app.")
            }
            Section {
                DatePicker("As of", selection: $asOfDate, displayedComponents: .date)
                    .environment(\.calendar, model.calendar)
                    .environment(\.timeZone, model.calendar.timeZone)
            } footer: {
                Text("Days before this date do not count toward the balance.")
            }
        }
        .navigationTitle("Starting balance")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: save)
            }
        }
    }

    private func save() {
        let day = DayKey(asOfDate, calendar: model.calendar)
        let seconds = sign * magnitude
        model.updateSettings { s in
            s.bankStartingSeconds = seconds
            s.bankStartingAsOf = day
        }
        dismiss()
    }
}

// MARK: - How counting works

/// SPEC section 4.3 in the owner's words.
struct SettingsHowCountingWorksView: View {
    @Environment(AppModel.self) private var model

    private let bullets: [String] = [
        "Stay late → the time after your scheduled end is added.",
        "Leave early → the time before your scheduled end is subtracted.",
        "Arrive late → the time after your scheduled start is subtracted.",
        "Arrive early → ignored unless you tap Count early arrival for that day.",
        "Pop out mid-day → the gap is subtracted unless you mark it a work trip. Leaving one site straight for another counts as work by default.",
        "Full day of PTO, stayed home → the bank does not move; PTO drops by the day.",
        "Full day of PTO but came in for 2 hours → +2h. Work on a day off always counts.",
        "Took a flex day → the day nets to zero and the bank pays for it: −8h.",
    ]

    var body: some View {
        List {
            Section {
                Text("Every calendar day gets a signed delta. Balance = starting balance + the sum of every day's delta. Nothing is rounded and nothing is hidden: every deviation is logged, even when it is tiny or later excused.")
            }
            Section("On a scheduled day") {
                ForEach(Array(bullets.enumerated()), id: \.offset) { item in
                    Label {
                        Text(item.element)
                    } icon: {
                        Image(systemName: "\(item.offset + 1).circle")
                    }
                }
            }
            Section("Also") {
                Text("\(model.settings.graceMinutes) minutes of grace apply at the scheduled start and end. Mid-day gaps are exact.")
                Text("On weekends, holidays and days off every minute of presence and every manual session counts.")
                Text("Manual sessions count as extra unless you switch one to regular, which fills the schedule instead (a remote day). Paused timer time never counts.")
                Text("Overtime is not paid. Extra time becomes time off, so the bank is the point.")
            }
        }
        .navigationTitle("How counting works")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    SettingsView().environment(AppModel.preview())
}
