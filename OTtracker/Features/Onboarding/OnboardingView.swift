import SwiftUI
import OTCore

/// First-run flow: welcome → schedule → work location → permissions → starting balance → done.
/// `RootView` shows it while `model.needsOnboarding` is true and switches to the tabs on its own
/// once `completeOnboarding()` has run.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model

    @State private var step = 0
    // The starting balance lives here so it survives Back/Next and is written once, on Finish.
    @State private var balanceIsPositive = true
    @State private var balanceSeconds = 0
    /// nil until the user touches the "as of" picker; resolves to today against the model.
    @State private var balanceAsOf: Date?

    private static let stepCount = 6

    init() {}

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                OnboardingProgressBar(step: step, count: OnboardingView.stepCount)
                content
                footer
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: Steps

    private var lastStep: Int { OnboardingView.stepCount - 1 }

    @ViewBuilder
    private var content: some View {
        switch step {
        case 0:
            OnboardingWelcomeStep()
        case 1:
            OnboardingScheduleStep()
        case 2:
            OnboardingLocationStep()
        case 3:
            OnboardingPermissionsStep()
        case 4:
            OnboardingBalanceStep(isPositive: $balanceIsPositive, seconds: $balanceSeconds, asOf: $balanceAsOf)
        default:
            OnboardingDoneStep(startingBalanceSeconds: signedBalance, startingAsOf: balanceAsOfDay, writesBalance: writesBalance)
        }
    }

    private var title: String {
        switch step {
        case 0: return "Welcome"
        case 1: return "Schedule"
        case 2: return "Work location"
        case 3: return "Permissions"
        case 4: return "Starting balance"
        default: return "All set"
        }
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12) {
                if step > 0 {
                    Button("Back") {
                        withAnimation { step -= 1 }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
                Button {
                    advance()
                } label: {
                    Text(step == lastStep ? "Finish" : "Next")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!canAdvance)
            }
            .padding(.horizontal)
            .padding(.vertical, 12)
        }
        .background(.bar)
    }

    /// The schedule step is the only gate: the ledger has nothing to measure against without one.
    private var canAdvance: Bool {
        if step == 1 { return model.store.hasSchedule }
        return true
    }

    private func advance() {
        if step < lastStep {
            withAnimation { step += 1 }
        } else {
            finish()
        }
    }

    // MARK: Starting balance

    private var signedBalance: Int { balanceIsPositive ? balanceSeconds : -balanceSeconds }

    private var balanceAsOfDay: DayKey { DayKey(balanceAsOf ?? model.now, calendar: model.calendar) }

    /// Only touch the bank settings when the user entered something; an untouched step keeps the
    /// defaults so history imported later still counts toward the balance.
    private var writesBalance: Bool { signedBalance != 0 || balanceAsOf != nil }

    private func finish() {
        if writesBalance {
            let seconds = signedBalance
            let day = balanceAsOfDay
            model.updateSettings { settings in
                settings.bankStartingSeconds = seconds
                settings.bankStartingAsOf = day
            }
        }
        model.completeOnboarding()
    }
}

#Preview("Sample data") {
    OnboardingView().environment(AppModel.preview())
}

#Preview("Fresh install") {
    OnboardingView().environment(AppModel.preview(Store()))
}
