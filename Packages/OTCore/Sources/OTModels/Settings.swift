import Foundation

public struct Settings: Hashable, Codable, Sendable {
    public var graceMinutes: Int
    public var weekStartsOn: Weekday
    public var timerNudgeMinutes: Int
    public var bankStartingSeconds: Int
    public var bankStartingAsOf: DayKey
    public var staleOpenSessionHours: Int
    public var flapMergeMinutes: Int
    public var manualCategories: [String]
    public var defaultManualCategory: String
    public var exportEmail: String?
    public var monthlyExportEnabled: Bool
    public var iCloudBackupEnabled: Bool
    public var timeZoneIdentifier: String
    public var onboardingCompleted: Bool

    public static let defaultCategories = ["Home work", "After hours", "Travel", "Other"]

    public init(timeZone: TimeZone = .current) {
        graceMinutes = 5
        weekStartsOn = .sunday
        timerNudgeMinutes = 240
        bankStartingSeconds = 0
        bankStartingAsOf = DayKey(year: 2000, month: 1, day: 1)
        staleOpenSessionHours = 16
        flapMergeMinutes = 3
        manualCategories = Settings.defaultCategories
        defaultManualCategory = Settings.defaultCategories[0]
        exportEmail = nil
        monthlyExportEnabled = true
        iCloudBackupEnabled = true
        timeZoneIdentifier = timeZone.identifier
        onboardingCompleted = false
    }

    public var graceSeconds: Int { graceMinutes * 60 }

    public var timeZone: TimeZone { TimeZone(identifier: timeZoneIdentifier) ?? .current }

    /// Gregorian calendar in the user's time zone with the configured first weekday.
    public var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = timeZone
        c.firstWeekday = weekStartsOn.rawValue
        return c
    }

    // Tolerant decoding: new fields get defaults so older JSON keeps loading.
    private enum CodingKeys: String, CodingKey {
        case graceMinutes, weekStartsOn, timerNudgeMinutes, bankStartingSeconds, bankStartingAsOf,
             staleOpenSessionHours, flapMergeMinutes, manualCategories, defaultManualCategory,
             exportEmail, monthlyExportEnabled, iCloudBackupEnabled, timeZoneIdentifier, onboardingCompleted
    }

    public init(from decoder: Decoder) throws {
        let d = Settings()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        graceMinutes = try c.decodeIfPresent(Int.self, forKey: .graceMinutes) ?? d.graceMinutes
        weekStartsOn = try c.decodeIfPresent(Weekday.self, forKey: .weekStartsOn) ?? d.weekStartsOn
        timerNudgeMinutes = try c.decodeIfPresent(Int.self, forKey: .timerNudgeMinutes) ?? d.timerNudgeMinutes
        bankStartingSeconds = try c.decodeIfPresent(Int.self, forKey: .bankStartingSeconds) ?? d.bankStartingSeconds
        bankStartingAsOf = try c.decodeIfPresent(DayKey.self, forKey: .bankStartingAsOf) ?? d.bankStartingAsOf
        staleOpenSessionHours = try c.decodeIfPresent(Int.self, forKey: .staleOpenSessionHours) ?? d.staleOpenSessionHours
        flapMergeMinutes = try c.decodeIfPresent(Int.self, forKey: .flapMergeMinutes) ?? d.flapMergeMinutes
        manualCategories = try c.decodeIfPresent([String].self, forKey: .manualCategories) ?? d.manualCategories
        defaultManualCategory = try c.decodeIfPresent(String.self, forKey: .defaultManualCategory) ?? d.defaultManualCategory
        exportEmail = try c.decodeIfPresent(String.self, forKey: .exportEmail)
        monthlyExportEnabled = try c.decodeIfPresent(Bool.self, forKey: .monthlyExportEnabled) ?? d.monthlyExportEnabled
        iCloudBackupEnabled = try c.decodeIfPresent(Bool.self, forKey: .iCloudBackupEnabled) ?? d.iCloudBackupEnabled
        timeZoneIdentifier = try c.decodeIfPresent(String.self, forKey: .timeZoneIdentifier) ?? d.timeZoneIdentifier
        onboardingCompleted = try c.decodeIfPresent(Bool.self, forKey: .onboardingCompleted) ?? d.onboardingCompleted
    }
}
