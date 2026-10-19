import Foundation

public enum TimeOffKind: String, Codable, Sendable, CaseIterable {
    case pto, personal, flex, other
}

public struct TimeOffType: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var name: String
    public var kind: TimeOffKind
    /// Keeps a starting balance + accrual + usage ledger.
    public var tracksBalance: Bool
    /// Hours taken are subtracted from the overtime bank (flex days).
    public var deductsFromBank: Bool

    public init(id: UUID = UUID(), name: String, kind: TimeOffKind, tracksBalance: Bool, deductsFromBank: Bool) {
        self.id = id
        self.name = name
        self.kind = kind
        self.tracksBalance = tracksBalance
        self.deductsFromBank = deductsFromBank
    }

    public static let ptoID = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    public static let personalID = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
    public static let flexID = UUID(uuidString: "00000000-0000-4000-8000-000000000003")!

    public static let pto = TimeOffType(id: ptoID, name: "PTO", kind: .pto, tracksBalance: true, deductsFromBank: false)
    public static let personal = TimeOffType(id: personalID, name: "Personal", kind: .personal, tracksBalance: true, deductsFromBank: false)
    public static let flex = TimeOffType(id: flexID, name: "Flex (from bank)", kind: .flex, tracksBalance: false, deductsFromBank: true)
    public static let builtIn: [TimeOffType] = [pto, personal, flex]
}

public struct TimeOffEntry: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var day: DayKey
    public var typeID: UUID
    public var seconds: Int
    public var note: String

    public init(id: UUID = UUID(), day: DayKey, typeID: UUID, seconds: Int, note: String = "") {
        self.id = id
        self.day = day
        self.typeID = typeID
        self.seconds = max(0, seconds)
        self.note = note
    }
}

public enum AccrualPeriod: String, Codable, Sendable, CaseIterable {
    case weekly, biweekly, monthly, yearly
}

/// `seconds` are granted on `anchor` and on every period boundary after it.
public struct AccrualRule: Hashable, Codable, Sendable {
    public var seconds: Int
    public var period: AccrualPeriod
    public var anchor: DayKey

    public init(seconds: Int, period: AccrualPeriod, anchor: DayKey) {
        self.seconds = seconds
        self.period = period
        self.anchor = anchor
    }
}

public struct LeaveBalanceConfig: Identifiable, Hashable, Codable, Sendable {
    public var typeID: UUID
    public var startingSeconds: Int
    public var asOf: DayKey
    public var accrual: AccrualRule?

    public var id: UUID { typeID }

    public init(typeID: UUID, startingSeconds: Int = 0, asOf: DayKey = DayKey(year: 2000, month: 1, day: 1), accrual: AccrualRule? = nil) {
        self.typeID = typeID
        self.startingSeconds = startingSeconds
        self.asOf = asOf
        self.accrual = accrual
    }
}

/// A signed correction to the bank on a given day.
public struct Adjustment: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var day: DayKey
    public var seconds: Int
    public var reason: String

    public init(id: UUID = UUID(), day: DayKey, seconds: Int, reason: String = "") {
        self.id = id
        self.day = day
        self.seconds = seconds
        self.reason = reason
    }
}
