import Foundation
import Observation
import CoreLocation
import BackgroundTasks
import OTCore

struct AppAlert: Identifiable, Hashable {
    var id = UUID()
    var title: String
    var message: String
}

/// Where a deep link or notification tap wants the UI to go, consumed by the feature views.
enum Route: Hashable {
    case day(DayKey)
    case editPresence(UUID)
    case editManual(UUID)
    case exportMonth(String, email: Bool)
    case locations
    case importFile
}

struct ImportPreview {
    var plan: ImportPlan
    var format: ImportFormat
    var filename: String
    var mode: ImportMode
}

/// The one object every screen talks to. Owns the `Store`, derives every number from it,
/// persists it, and drives the device services. Main actor only.
@MainActor
@Observable
final class AppModel {
    enum Tab: Hashable { case home, log, inbox, timeOff, settings }

    // MARK: Dependencies

    @ObservationIgnored private let repository: StoreRepository
    @ObservationIgnored let location: LocationServicing
    @ObservationIgnored let notifications: NotificationServicing
    @ObservationIgnored let liveActivity: LiveActivityServicing
    @ObservationIgnored let backup: BackupServicing
    @ObservationIgnored let widgets: WidgetBridging
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var backupTask: Task<Void, Never>?

    // MARK: State

    private(set) var store: Store
    /// Day results for roughly the last 400 days through next week. Use `dayResult(for:)`.
    private(set) var results: [DayKey: DayResult] = [:]
    private(set) var summary = LedgerSummary()
    private(set) var leaveBalances: [LeaveBalance] = []
    private(set) var inbox: [InboxItem] = []
    private(set) var monthlyExports: [MonthlyExportFile] = []
    private(set) var locationStatus: CLAuthorizationStatus = .notDetermined
    private(set) var notificationsAuthorized = false
    private(set) var lastBackupAt: Date?
    private(set) var iCloudAvailable = false

    var selectedTab: Tab = .home
    /// Set by deep links and notification actions; the destination view consumes and clears it.
    var pendingRoute: Route?
    var alert: AppAlert?

    // MARK: Init

    init(repository: StoreRepository, location: LocationServicing, notifications: NotificationServicing,
         liveActivity: LiveActivityServicing, backup: BackupServicing, widgets: WidgetBridging) {
        self.repository = repository
        self.location = location
        self.notifications = notifications
        self.liveActivity = liveActivity
        self.backup = backup
        self.widgets = widgets
        var loaded = (try? repository.load()) ?? nil
        if loaded == nil { loaded = Store() }
        self.store = loaded ?? Store()
        self.locationStatus = location.authorizationStatus
        self.lastBackupAt = UserDefaults.standard.object(forKey: "lastBackupAt") as? Date

        location.onAuthorizationChange = { [weak self] status in
            guard let self else { return }
            self.locationStatus = status
            self.syncRegions()
        }
        location.onCrossing = { [weak self] crossing in self?.handle(crossing: crossing) }
        notifications.onResponse = { [weak self] response in self?.handle(notificationResponse: response) }

        monthlyExports = ExportService.existingMonthlyExports()
        recompute()
        syncRegions()
        Task { [weak self] in
            guard let self else { return }
            self.iCloudAvailable = await self.backup.isAvailable()
            self.notificationsAuthorized = self.notifications.isAuthorized
        }
    }

    /// Real services, real file store.
    static func live() -> AppModel {
        AppModel(repository: FileStoreRepository.default(), location: LocationService(), notifications: NotificationService(),
                 liveActivity: LiveActivityService(), backup: ICloudBackupService(), widgets: WidgetBridge())
    }

    /// In-memory model for SwiftUI previews.
    static func preview(_ store: Store = SampleData.store()) -> AppModel {
        AppModel(repository: InMemoryStoreRepository(store: store), location: NoopLocationService(), notifications: NoopNotificationService(),
                 liveActivity: NoopLiveActivityService(), backup: NoopBackupService(), widgets: NoopWidgetBridge())
    }

    // MARK: Derived conveniences

    var now: Date { Date() }
    var calendar: Calendar { store.calendar }
    var today: DayKey { DayKey(now, calendar: calendar) }
    var settings: Settings { store.settings }
    var needsOnboarding: Bool { !store.settings.onboardingCompleted }
    var activeTimer: ManualSession? { store.activeManualSession }
    var openPresence: PresenceSession? { store.openPresenceSession }
    var todayResult: DayResult { dayResult(for: today) }
    var inboxCount: Int { inbox.count }

    func dayResult(for day: DayKey) -> DayResult {
        results[day] ?? Ledger.dayResult(store: store, day: day, now: now)
    }

    /// Fresh results for any range (used by export and long lists).
    func dayResults(from: DayKey, through: DayKey) -> [DayResult] {
        Ledger.dayResults(store: store, from: from, through: through, now: now)
    }

    func locationName(_ id: UUID) -> String { store.location(id: id)?.name ?? "Unknown location" }

    func timeOffTypeName(_ id: UUID) -> String { store.timeOffType(id: id)?.name ?? "Time off" }

    var earliestDay: DayKey { Ledger.earliestDay(store: store, now: now) }

    // MARK: Mutation core

    /// Every change goes through here: apply, recompute, save (debounced), back up (debounced).
    func mutate(_ body: (inout Store) -> Void) {
        var s = store
        body(&s)
        guard s != store else { return }
        store = s
        recompute()
        scheduleSave()
    }

    func mutateThrowing(_ body: (inout Store) throws -> Void) throws {
        var s = store
        try body(&s)
        guard s != store else { return }
        store = s
        recompute()
        scheduleSave()
    }

    /// Replaces the whole store (restore / import replace).
    func replaceStore(_ s: Store) {
        store = s
        recompute()
        saveNow()
        syncRegions()
    }

    private func recompute() {
        let now = self.now
        let today = self.today
        let cal = calendar
        let earliest = Ledger.earliestDay(store: store, now: now)
        let from = min(max(earliest, today.adding(days: -400, calendar: cal)), today)
        let through = today.adding(days: 7, calendar: cal)
        let list = Ledger.dayResults(store: store, from: from, through: through, now: now)
        results = Dictionary(list.map { ($0.day, $0) }, uniquingKeysWith: { a, _ in a })
        summary = Ledger.summary(store: store, now: now)
        leaveBalances = Ledger.leaveBalances(store: store, asOf: today)
        let recent = list.filter { $0.day >= today.adding(days: -60, calendar: cal) && $0.day <= today }
        inbox = InboxEngine.items(store: store, dayResults: recent, now: now, monthlyExports: monthlyExports.map { $0.month })
        liveActivity.sync(with: store.activeManualSession, now: now)
        publishWidget()
    }

    private func publishWidget() {
        let timer = store.activeManualSession
        let closed = timer?.segments.filter { !$0.isOpen }.reduce(0) { $0 + $1.interval(now: now).seconds } ?? 0
        widgets.publish(WidgetSnapshot(generatedAt: now, balanceSeconds: summary.balanceSeconds,
                                       monthGrossExtraSeconds: summary.monthGrossExtraSeconds, todayDeltaSeconds: summary.todayDeltaSeconds,
                                       timerRunning: timer?.state == .running, timerCategory: timer?.category,
                                       timerStartedAt: timer?.segments.last?.isOpen == true ? timer?.segments.last?.start : nil,
                                       timerAccumulatedSeconds: closed, inboxCount: inbox.count))
    }

    // MARK: Persistence

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        saveTask?.cancel()
        do {
            try repository.save(store)
        } catch {
            alert = AppAlert(title: "Could not save", message: error.localizedDescription)
        }
        scheduleBackup()
    }

    /// Called when the app goes to the background.
    func flush() {
        saveNow()
        backupTask?.cancel()
        if store.settings.iCloudBackupEnabled {
            Task { await backupNow(quiet: true) }
        }
    }

    private func scheduleBackup() {
        guard store.settings.iCloudBackupEnabled else { return }
        backupTask?.cancel()
        backupTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300 * 1_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.backupNow(quiet: true)
        }
    }

    func backupNow(quiet: Bool = false) async {
        guard let data = try? StoreCodec.encode(store) else { return }
        do {
            _ = try await backup.write(data, now: now)
            lastBackupAt = now
            UserDefaults.standard.set(lastBackupAt, forKey: "lastBackupAt")
            iCloudAvailable = true
        } catch {
            if !quiet { alert = AppAlert(title: "Backup failed", message: error.localizedDescription) }
        }
    }

    func listBackups() async throws -> [BackupInfo] { try await backup.list() }

    func restore(from info: BackupInfo) async throws {
        let data = try await backup.read(info)
        let s = try StoreCodec.decode(data)
        replaceStore(s)
    }

    // MARK: Scene lifecycle

    func sceneBecameActive() {
        monthlyExports = ExportService.existingMonthlyExports()
        recompute()
        generateMonthlyExportIfNeeded()
        location.refreshCurrentState()
        Task { [weak self] in
            guard let self else { return }
            self.notificationsAuthorized = self.notifications.isAuthorized
            self.iCloudAvailable = await self.backup.isAvailable()
        }
    }

    func sceneEnteredBackground() {
        flush()
        scheduleRefreshTask()
    }

    func scheduleRefreshTask() {
        let request = BGAppRefreshTaskRequest(identifier: AppIdentifiers.refreshTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 4 * 3600)
        try? BGTaskScheduler.shared.submit(request)
    }

    /// Runs from the SwiftUI `.backgroundTask(.appRefresh)` handler.
    func performBackgroundRefresh() async {
        recompute()
        generateMonthlyExportIfNeeded()
        if store.settings.iCloudBackupEnabled, let last = lastBackupAt, now.timeIntervalSince(last) > 20 * 3600 {
            await backupNow(quiet: true)
        } else if store.settings.iCloudBackupEnabled, lastBackupAt == nil {
            await backupNow(quiet: true)
        }
        scheduleRefreshTask()
    }

    // MARK: Permissions

    func requestLocationAccess() {
        switch locationStatus {
        case .notDetermined: location.requestAlways()
        case .authorizedWhenInUse: location.requestAlways()
        default: break
        }
    }

    func requestNotificationAccess() async {
        notificationsAuthorized = await notifications.requestAuthorization()
    }

    var locationAlwaysGranted: Bool { locationStatus == .authorizedAlways }

    private func syncRegions() {
        guard locationStatus == .authorizedAlways || locationStatus == .authorizedWhenInUse else { return }
        location.syncRegions(store.locations)
    }

    // MARK: Geofence events

    private func handle(crossing: RegionCrossing) {
        if crossing.inferredFromState {
            let open = store.openPresenceSession
            switch crossing.kind {
            case .enter:
                if let open, open.locationID == crossing.locationID { return }
            case .exit:
                guard let open, open.locationID == crossing.locationID else { return }
            }
        }
        guard store.location(id: crossing.locationID) != nil else { return }
        let event = LocationEvent(locationID: crossing.locationID, kind: crossing.kind, at: crossing.at, source: .geofence)
        var outcome: InterpretationOutcome? = nil
        mutate { s in outcome = GeofenceInterpreter.apply(event, to: &s) }
        guard let outcome else { return }
        notify(after: outcome)
    }

    private func notify(after outcome: InterpretationOutcome) {
        let name = locationName(outcome.event.locationID)
        if let closed = outcome.closed, let exit = closed.exitedAt {
            let r = dayResult(for: DayKey(exit, calendar: calendar))
            if r.extraAfterSeconds > 0 || r.earlyExitSeconds > 0 {
                let effect = r.extraAfterSeconds > 0 ? r.extraAfterSeconds : -r.earlyExitSeconds
                notifications.post(.exitPosted(sessionID: closed.id,
                                               title: "Left \(name) at \(Format.time(exit, calendar))",
                                               body: "\(Format.hm(effect, signed: true)) logged. Balance now \(Format.hm(summary.balanceSeconds, signed: true))."))
            }
        }
        if let opened = outcome.opened {
            let day = DayKey(opened.enteredAt, calendar: calendar)
            let r = dayResult(for: day)
            if r.flags.contains(.earlyArrivalUncounted), r.extraBeforeSeconds > 0 {
                notifications.post(.earlyArrival(day: day, title: "Arrived \(Format.hm(r.extraBeforeSeconds)) early",
                                                 body: "Early arrivals do not count unless you say so. Count it toward your balance?"))
            }
        }
        if outcome.orphanExit {
            notifications.post(.orphanExit(eventID: outcome.event.id, title: "Left \(name) at \(Format.time(outcome.event.at, calendar))",
                                           body: "No arrival was recorded for this visit. Add the arrival time from the Inbox."))
        }
    }

    // MARK: Timer

    func startTimer(category: String? = nil, note: String = "", countsAs: ManualCountsAs = .extra) {
        do {
            try mutateThrowing { s in
                _ = try ManualTimer.start(store: &s, category: category ?? s.settings.defaultManualCategory, note: note, countsAs: countsAs, at: now)
            }
            scheduleTimerNudge()
        } catch {
            alert = AppAlert(title: "Timer", message: "A timer is already running.")
        }
    }

    func pauseTimer() {
        do { try mutateThrowing { s in _ = try ManualTimer.pause(store: &s, at: now) } } catch { }
        notifications.cancelTimerNudge()
    }

    func resumeTimer() {
        do { try mutateThrowing { s in _ = try ManualTimer.resume(store: &s, at: now) } } catch { }
        scheduleTimerNudge()
    }

    func stopTimer() {
        do { try mutateThrowing { s in _ = try ManualTimer.stop(store: &s, at: now) } } catch { }
        notifications.cancelTimerNudge()
    }

    func discardTimer() {
        do { try mutateThrowing { s in _ = try ManualTimer.discard(store: &s) } } catch { }
        notifications.cancelTimerNudge()
    }

    private func scheduleTimerNudge() {
        guard let t = store.activeManualSession, t.state == .running else { notifications.cancelTimerNudge(); return }
        let period = max(60, store.settings.timerNudgeMinutes * 60)
        let active = t.activeSeconds(now: now)
        let untilNext = period - (active % period)
        notifications.post(.timerNudge(sessionID: t.id, fireAt: now.addingTimeInterval(TimeInterval(untilNext)),
                                       title: "Timer still running",
                                       body: "\(t.category) has been running \(Format.hm(active + untilNext)). Still working?"))
    }

    func saveManual(_ m: ManualSession) { mutate { $0.upsert(m) } }

    func deleteManual(id: UUID) { mutate { $0.manual.removeAll { $0.id == id } } }

    // MARK: Presence

    func savePresence(_ p: PresenceSession) { mutate { $0.upsert(p) } }

    func deletePresence(id: UUID) { mutate { $0.presence.removeAll { $0.id == id } } }

    /// Hand-entered arrival/departure (also logs the events).
    func addPresence(locationID: UUID, enteredAt: Date, exitedAt: Date?, note: String = "") {
        mutate { s in
            s.locationEvents.append(LocationEvent(locationID: locationID, kind: .enter, at: enteredAt, source: .manual))
            if let exitedAt { s.locationEvents.append(LocationEvent(locationID: locationID, kind: .exit, at: exitedAt, source: .manual)) }
            s.presence.append(PresenceSession(locationID: locationID, enteredAt: enteredAt, exitedAt: exitedAt, source: .manual, note: note))
        }
    }

    // MARK: Schedule, overrides, holidays

    func saveSchedule(_ v: ScheduleVersion) { mutate { $0.upsert(v) } }

    func deleteSchedule(id: UUID) { mutate { $0.schedules.removeAll { $0.id == id } } }

    func setOverride(_ o: DayOverride) { mutate { $0.setOverride(o) } }

    func removeOverride(day: DayKey) { mutate { $0.overrides.removeAll { $0.day == day } } }

    func countEarlyArrival(day: DayKey, _ count: Bool = true) {
        mutate { s in
            var o = s.overrideOrNew(for: day)
            o.countEarlyArrival = count
            s.setOverride(o)
            if count { s.dismissInbox("early:\(day.isoString)") }
        }
    }

    func saveHoliday(_ h: Holiday) { mutate { $0.upsert(h) } }

    func deleteHoliday(id: UUID) { mutate { $0.holidays.removeAll { $0.id == id } } }

    // MARK: Locations

    func saveLocation(_ l: WorkLocation) {
        mutate { $0.upsert(l) }
        syncRegions()
    }

    func deleteLocation(id: UUID) {
        mutate { $0.locations.removeAll { $0.id == id } }
        syncRegions()
    }

    // MARK: Time off

    func saveTimeOff(_ t: TimeOffEntry) { mutate { $0.upsert(t) } }

    func deleteTimeOff(id: UUID) { mutate { $0.timeOff.removeAll { $0.id == id } } }

    func saveTimeOffType(_ t: TimeOffType) { mutate { $0.upsert(t) } }

    func deleteTimeOffType(id: UUID) {
        guard !TimeOffType.builtIn.contains(where: { $0.id == id }) else { return }
        mutate { s in
            s.timeOffTypes.removeAll { $0.id == id }
            s.leaveBalances.removeAll { $0.typeID == id }
        }
    }

    func saveLeaveBalance(_ b: LeaveBalanceConfig) { mutate { $0.upsert(b) } }

    func leaveBalance(for typeID: UUID) -> LeaveBalance? { leaveBalances.first { $0.typeID == typeID } }

    // MARK: Adjustments

    func saveAdjustment(_ a: Adjustment) { mutate { $0.upsert(a) } }

    func deleteAdjustment(id: UUID) { mutate { $0.adjustments.removeAll { $0.id == id } } }

    // MARK: Settings

    func updateSettings(_ body: (inout Settings) -> Void) {
        mutate { body(&$0.settings) }
    }

    func completeOnboarding() {
        updateSettings { $0.onboardingCompleted = true }
        syncRegions()
    }

    // MARK: Inbox

    /// Applies an Inbox action. `.needsInput` means the view must collect a date/duration/form first and call again.
    @discardableResult
    func resolve(_ item: InboxItem, with action: InboxAction, date: Date? = nil, seconds: Int? = nil) -> ResolutionOutcome {
        let window = dayResult(for: item.day).scheduledWindow
        var outcome: ResolutionOutcome = .notApplicable
        mutate { s in
            outcome = InboxResolver.apply(action, item: item, store: &s, now: now, date: date, seconds: seconds, window: window)
        }
        if action == .stopTimerNow || action == .setTimerStop { notifications.cancelTimerNudge() }
        if action == .stillWorking { scheduleTimerNudge() }
        return outcome
    }

    func dismissInbox(key: String) { mutate { $0.dismissInbox(key) } }

    // MARK: Export

    private var allHistoryStart: DayKey { min(earliestDay, store.settings.bankStartingAsOf > DayKey(year: 2000, month: 1, day: 1) ? store.settings.bankStartingAsOf : earliestDay) }

    func exportXLSX(from: DayKey? = nil, through: DayKey? = nil) throws -> URL {
        let from = from ?? allHistoryStart
        let through = through ?? today
        let name = "OTtracker \(from.isoString) to \(through.isoString).xlsx"
        return try ExportService.writeXLSX(store: store, from: from, through: through, now: now, summary: summary,
                                           leaveBalances: leaveBalances, to: AppFiles.shareScratch, filename: name)
    }

    func exportJSON() throws -> URL {
        try ExportService.writeJSON(store: store, to: AppFiles.shareScratch, filename: "OTtracker-backup-\(today.isoString).json")
    }

    func csvTemplateURL() throws -> URL { try ExportService.writeCSVTemplate(to: AppFiles.shareScratch) }

    /// Creates last month's Excel once per month, then notifies.
    func generateMonthlyExportIfNeeded() {
        guard store.settings.monthlyExportEnabled, store.hasSchedule else { return }
        let firstOfThisMonth = Format.firstOfMonth(today)
        let lastOfPrev = firstOfThisMonth.adding(days: -1, calendar: calendar)
        let firstOfPrev = Format.firstOfMonth(lastOfPrev)
        let key = Format.monthKey(firstOfPrev)
        guard !monthlyExports.contains(where: { $0.month == key }),
              !store.dismissedInboxKeys.contains("export:\(key)"),
              earliestDay <= lastOfPrev else { return }
        do {
            _ = try ExportService.writeXLSX(store: store, from: firstOfPrev, through: lastOfPrev, now: now, summary: summary,
                                            leaveBalances: leaveBalances, to: AppFiles.exports, filename: "OTtracker-\(key).xlsx")
            monthlyExports = ExportService.existingMonthlyExports()
            recompute()
            notifications.post(.monthlyExport(month: key, title: "\(Format.month(firstOfPrev, calendar)) export ready",
                                              body: "Your Excel file for last month is ready to email or share."))
        } catch {
            alert = AppAlert(title: "Monthly export failed", message: error.localizedDescription)
        }
    }

    func monthlyExport(for month: String) -> MonthlyExportFile? { monthlyExports.first { $0.month == month } }

    // MARK: Import

    func previewImport(url: URL, mode: ImportMode) throws -> ImportPreview {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        guard let format = ImportParser.detectFormat(data: data, filename: url.lastPathComponent) else { throw ImportError.unrecognizedFormat }
        let bundle = try ImportParser.parse(data: data, filename: url.lastPathComponent, store: store)
        let plan = Importer.plan(store: store, bundle: bundle, mode: mode)
        return ImportPreview(plan: plan, format: format, filename: url.lastPathComponent, mode: mode)
    }

    func applyImport(_ preview: ImportPreview) {
        mutate { Importer.apply(plan: preview.plan, mode: preview.mode, to: &$0) }
        syncRegions()
    }

    // MARK: Deep links and notification actions

    func handle(url: URL) {
        guard let link = DeepLink(url: url) else { return }
        handle(deepLink: link)
    }

    func handle(deepLink link: DeepLink) {
        switch link {
        case .home: selectedTab = .home
        case .timerStart: selectedTab = .home; if activeTimer == nil { startTimer() }
        case .timerPause: pauseTimer()
        case .timerResume: resumeTimer()
        case .timerStop: stopTimer()
        case .inbox: selectedTab = .inbox
        case .log(let day): selectedTab = .log; pendingRoute = .day(day)
        }
    }

    private func handle(notificationResponse r: NotificationResponse) {
        switch r {
        case .open(let link): handle(deepLink: link)
        case .confirmExit(let id): dismissInbox(key: "exit:\(id.uuidString)")
        case .adjustExit(let id): selectedTab = .log; pendingRoute = .editPresence(id)
        case .countEarlyArrival(let day): countEarlyArrival(day: day)
        case .stopTimer: stopTimer()
        case .timerStillWorking: scheduleTimerNudge()
        case .emailExport(let month): selectedTab = .inbox; pendingRoute = .exportMonth(month, email: true)
        case .shareExport(let month): selectedTab = .inbox; pendingRoute = .exportMonth(month, email: false)
        }
    }

    /// Views call this after acting on `pendingRoute`.
    func consumeRoute() { pendingRoute = nil }
}
