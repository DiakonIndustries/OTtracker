import SwiftUI
import UIKit
import CoreLocation
import OTCore

// MARK: - Permission wording

/// Status text shared by the Permissions and Done steps.
enum OnboardingStatus {
    static let systemSettingsURL = URL(string: UIApplication.openSettingsURLString)!

    static func location(_ status: CLAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "Not asked"
        case .authorizedWhenInUse: return "While using (tap again for Always)"
        case .authorizedAlways: return "Always ✓"
        case .denied, .restricted: return "Denied"
        default: return "Unknown"
        }
    }

    static func notifications(_ authorized: Bool) -> String {
        authorized ? "Allowed ✓" : "Not allowed"
    }
}

// MARK: - Step 3: Permissions

struct OnboardingPermissionsStep: View {
    @Environment(AppModel.self) private var model
    /// Set after the first tap on Allow so a refusal can offer the Settings link instead.
    @State private var notificationsAsked = false

    var body: some View {
        Form {
            Section {
                Text("Two permissions make the tracking automatic. Both are optional, and you can change them any time in Settings.")
            }

            Section {
                LabeledContent("Location") {
                    Text(OnboardingStatus.location(model.locationStatus))
                        .foregroundStyle(model.locationAlwaysGranted ? Color.positive : Color.secondary)
                }
                locationAction
            } footer: {
                Text("“Always” lets the app notice arrivals and departures while it is closed. iOS asks for “While Using” first; tap the button again to upgrade to Always.")
            }

            Section {
                LabeledContent("Notifications") {
                    Text(OnboardingStatus.notifications(model.notificationsAuthorized))
                        .foregroundStyle(model.notificationsAuthorized ? Color.positive : Color.secondary)
                }
                notificationAction
            } footer: {
                Text("Notifications tell you when a departure was logged (with an Adjust button) and when a timer has been running for a long time.")
            }
        }
    }

    @ViewBuilder
    private var locationAction: some View {
        switch model.locationStatus {
        case .authorizedAlways:
            EmptyView()
        case .denied, .restricted:
            Link("Open Settings", destination: OnboardingStatus.systemSettingsURL)
        default:
            Button("Allow Always") {
                model.requestLocationAccess()
            }
        }
    }

    @ViewBuilder
    private var notificationAction: some View {
        if model.notificationsAuthorized {
            EmptyView()
        } else if notificationsAsked {
            Link("Open Settings", destination: OnboardingStatus.systemSettingsURL)
        } else {
            Button("Allow") {
                Task {
                    await model.requestNotificationAccess()
                    notificationsAsked = true
                }
            }
        }
    }
}

// MARK: - Step 4: Starting balance

struct OnboardingBalanceStep: View {
    @Environment(AppModel.self) private var model
    @Binding var isPositive: Bool
    @Binding var seconds: Int
    @Binding var asOf: Date?

    private var signedSeconds: Int { isPositive ? seconds : -seconds }

    /// Noon today in the store's calendar, so a date-only pick lands on the intended day.
    private var defaultAsOf: Date { Format.noon(model.today, model.calendar) }

    private var asOfBinding: Binding<Date> {
        Binding(get: { asOf ?? defaultAsOf }, set: { asOf = $0 })
    }

    private var asOfDay: DayKey { DayKey(asOf ?? defaultAsOf, calendar: model.calendar) }

    var body: some View {
        Form {
            Section {
                Text("If you already have banked time, enter it so the tally starts right. Leave it at zero to start fresh.")
            }

            Section {
                Picker("Direction", selection: $isPositive) {
                    Text("Ahead (+)").tag(true)
                    Text("Behind (−)").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                DurationPicker(seconds: $seconds, maxHours: 400)
            } header: {
                Text("Banked time")
            }

            Section {
                DatePicker("As of", selection: asOfBinding, in: ...defaultAsOf, displayedComponents: .date)
                    .environment(\.calendar, model.calendar)
                    .environment(\.timeZone, model.calendar.timeZone)
            } footer: {
                Text("Days before this date are ignored for the balance. This day and every day after it are added to it.")
            }

            Section {
                LabeledContent("Starting balance") {
                    DeltaText(seconds: signedSeconds)
                }
                ValueRow("Counting from", Format.dayWithYear(asOfDay, model.calendar))
            }
        }
    }
}

// MARK: - Step 5: Done

struct OnboardingDoneStep: View {
    @Environment(AppModel.self) private var model
    let startingBalanceSeconds: Int
    let startingAsOf: DayKey
    let writesBalance: Bool

    var body: some View {
        Form {
            Section {
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 56))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(Color.positive)
                    Text("You're set")
                        .font(.title.bold())
                    Text("Tap Finish to start the tally. Everything here can be changed later in Settings.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .listRowBackground(Color.clear)
            }

            Section("Summary") {
                ValueRow("Schedule", scheduleText)
                ValueRow("Work locations", locationsText)
                ValueRow("Location access", OnboardingStatus.location(model.locationStatus))
                ValueRow("Notifications", OnboardingStatus.notifications(model.notificationsAuthorized))
                if writesBalance {
                    LabeledContent("Starting balance") {
                        DeltaText(seconds: startingBalanceSeconds)
                    }
                    ValueRow("Counting from", Format.dayWithYear(startingAsOf, model.calendar))
                } else {
                    ValueRow("Starting balance", "None")
                }
            }
        }
    }

    private var scheduleText: String {
        let current = model.store.scheduleVersion(for: model.today)
        let latest = model.store.schedules.max { $0.effectiveFrom < $1.effectiveFrom }
        guard let version = current ?? latest else { return "Not set" }
        let workdays = Weekday.allCases.filter { version[$0].isWorkday }
        let total = workdays.reduce(0) { $0 + version[$1].expectedSeconds }
        return "\(workdays.count) workdays, \(Format.hm(total)) a week"
    }

    private var locationsText: String {
        let count = model.store.locations.count
        if count == 0 { return "None yet" }
        if count == 1 { return model.store.locations[0].name }
        return "\(count) locations"
    }
}

#Preview("Balance step") {
    OnboardingBalanceStep(isPositive: .constant(true), seconds: .constant(6 * 3600 + 1800), asOf: .constant(nil))
        .environment(AppModel.preview())
}
