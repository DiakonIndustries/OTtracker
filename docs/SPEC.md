# OTtracker — Specification

Personal iOS app that keeps an honest ledger of extra time worked and time off taken.
No pay math. No server. Everything lives on the phone, backed up to iCloud Drive.

This document is the single source of truth for behaviour. Code follows it; when the
code and this file disagree, this file wins and the code gets fixed.

---

## 1. Mental model

The app is a **flex-time bank**.

* A **schedule** says when you are expected to be at work on each weekday.
* Three kinds of **facts** are recorded:
  1. **Presence** at a work location (arrive / leave), detected by geofence or entered by hand.
  2. **Manual sessions** — a start/pause/stop timer, or a block entered after the fact,
     for work done anywhere (home, after hours, travel).
  3. **Time off** — PTO, personal time, flex days taken from the bank, holidays.
* Every calendar day resolves to a signed **delta** (seconds). Staying late, arriving early
  when you ask for it to count, and manual extra work push the delta up. Arriving late,
  leaving early, and being away mid-day push it down.
* **Balance** = starting balance + Σ deltas over all days. This is "the tally".
* Nothing is hidden. Every deviation is logged, even when it is tiny or later excused.
* The ledger is **derived, never stored**. Facts and user decisions are stored; every
  number on screen or in the Excel is recomputed from them. Export, import, and tests
  all become simple because of this.

---

## 2. Decisions from the owner (locked)

| Topic | Decision |
|---|---|
| Schedule | Per-weekday start/end set by the user; days differ. Optional unpaid break per day (owner takes none). |
| Week | Starts Sunday for display. No pay periods. |
| What counts | Any deviation from scheduled times. Late exit adds. Late arrival, early exit, mid-day absence subtract. |
| Early arrival | Does **not** count unless the user taps "Count early arrival" for that day. |
| Grace | 5 minutes at the scheduled start and end boundaries. Configurable. |
| Precision | Exact. Store seconds, display h:mm. No rounding. |
| Pay | None. Hours only. Overtime converts to extra time off, so the bank is the point. |
| Mid-day leave & return (same site) | Logged and **deducted by default**, with an Inbox question "was this a work trip?" |
| Leave site A, arrive site B | Logged and **counts by default**, Inbox question offered. |
| Weekend / holiday / day off presence | All of it counts. |
| Auto-detected exit | Posted immediately. Notification with an Adjust button. |
| Site size | Large; leaving the lot means leaving. Radius is per location. |
| Manual timer | Categories (Home work, After hours, Travel, Other, editable). Note optional. Paused time never counts. Lock-screen Live Activity. |
| Manual time on a workday | Counts as **extra** by default. Entry can be switched to "regular" to fill the schedule instead (e.g., a remote day). |
| Forgot to stop | Notification + Inbox item after 4 h running. Never auto-stop. |
| Retroactive entries | Yes, for presence, manual, time off, adjustments. |
| Time off types | PTO and Personal built in. Flex (from the bank) built in. More types can be added. |
| Leave balances | Tracked: starting balance, accrual rule, used, remaining. Per type. |
| Flex day | Reduces expected hours **and** subtracts from the bank. |
| Holidays | Entered by hand and importable from a file. |
| Partial time off | Hours and minutes. |
| Inbox | A to-do list of the app's questions: confirm / adjust / remove / decide. |
| Home screen | Current balance, this month's gross extra time (positives only), timer card, today. |
| Charts | Yes. Weekly bars and monthly trend. |
| Export | Excel (.xlsx), whole history or a date range, via the Share sheet. |
| Import | The app's own Excel, a documented CSV template, the app's JSON backup. Merge by default; Replace behind confirmation. |
| Widgets | Home-screen balance widget with a start-timer button; Live Activity for the running timer. |
| iCloud | Automatic JSON backups to iCloud Drive; restore on a new phone. |
| Monthly export | Generated automatically on the first launch after a month ends; notification; one tap opens a prefilled email with the file attached. |
| Devices | iPhone 16 Pro now; deployment target iOS 17.0 so older phones work; only long-lived APIs so newer iOS keeps working. |
| Not wanted | Watch app, Siri, weekly digest, OT cap, protected days, project codes, still-at-work ping, audit trail UI, calendar integration. |

---

## 3. Domain model (package `OTModels`)

All types are `struct`/`enum`, `Codable`, `Hashable`, `Sendable`. IDs are `UUID`.
Dates are `Date` (UTC instants). Calendar days are `DayKey` (year, month, day) in the
user's current time zone. Durations are `Int` seconds unless named `Minutes`.

```
TimeOfDay            minutesFromMidnight: Int            // 0...1439
DayKey               year, month, day                    // Comparable, Strideable by day
Weekday              sunday=1 ... saturday=7             // matches Calendar
Interval             start: Date, end: Date              // end >= start; duration

WeekdaySchedule      isWorkday: Bool, start: TimeOfDay, end: TimeOfDay, unpaidBreakMinutes: Int
ScheduleVersion      id, effectiveFrom: DayKey, days: [Weekday: WeekdaySchedule], note
DayOverride          id, day: DayKey,
                     kind: .dayOff | .schedule(WeekdaySchedule) | .none,
                     countEarlyArrival: Bool, excused: Bool, note
Holiday              id, day: DayKey, name

WorkLocation         id, name, latitude, longitude, radiusMeters, isActive, createdAt
LocationEvent        id, locationID, kind: .enter | .exit, at: Date, source: .geofence | .manual | .imported   // append-only audit log
PresenceSession      id, locationID, enteredAt: Date, exitedAt: Date?, source,
                     followingGapIsWork: Bool?,          // nil = undecided → default applies
                     note

ManualSession        id, category: String, note: String?, countsAs: .extra | .regular,
                     segments: [Segment{start: Date, end: Date?}], isStopped: Bool, createdAt
                     // running  = !isStopped && last segment open
                     // paused   = !isStopped && all segments closed
                     // stopped  = isStopped
TimeOffType          id, name, kind: .pto | .personal | .flex | .other,
                     tracksBalance: Bool, deductsFromBank: Bool     // flex: deductsFromBank = true
TimeOffEntry         id, day: DayKey, typeID, seconds: Int, note
LeaveBalanceConfig   typeID, startingSeconds: Int, asOf: DayKey,
                     accrual: AccrualRule?  { seconds: Int, period: .weekly|.biweekly|.monthly|.yearly, anchor: DayKey }
Adjustment           id, day: DayKey, seconds: Int (signed), reason

Settings             graceMinutes = 5, weekStartsOn = .sunday, timerNudgeMinutes = 240,
                     bankStartingSeconds = 0, bankStartingAsOf: DayKey,
                     staleOpenSessionHours = 16, flapMergeMinutes = 3,
                     manualCategories = ["Home work","After hours","Travel","Other"],
                     defaultManualCategory = "Home work",
                     exportEmail: String?, monthlyExportEnabled = true,
                     iCloudBackupEnabled = true, timeZoneIdentifier: String

Store                schedules: [ScheduleVersion], overrides: [DayOverride], holidays: [Holiday],
                     locations: [WorkLocation], locationEvents: [LocationEvent],
                     presence: [PresenceSession], manual: [ManualSession],
                     timeOffTypes: [TimeOffType], timeOff: [TimeOffEntry],
                     leaveBalances: [LeaveBalanceConfig], adjustments: [Adjustment],
                     dismissedInboxKeys: Set<String>, settings: Settings,
                     schemaVersion: Int
```

`Store` is the entire app state. It is persisted as one JSON document (atomic write,
debounced) in Application Support, mirrored to the App Group container for widgets,
and snapshotted to iCloud Drive for backup.

Derived result types (also in `OTModels` so every module can use them):

```
DayKind              .workday | .weekend | .holiday | .dayOff | .excused
DayResult            day, kind, scheduledWindow: Interval?, expectedSeconds,
                     firstIn: Date?, lastOut: Date?,
                     presenceSeconds, presenceInsideSeconds,
                     extraAfterSeconds, extraBeforeSeconds, extraBeforeCounted: Bool,
                     gapsDeductedSeconds, gapsWorkSeconds,
                     lateArrivalSeconds, earlyExitSeconds,
                     manualExtraSeconds, manualRegularSeconds,
                     timeOffSeconds, flexSpentSeconds, adjustmentSeconds,
                     deltaSeconds, grossExtraSeconds,
                     flags: [DayFlag]   // .noShow, .openPresence, .earlyArrivalUncounted, .gapUndecided, .graceApplied...
LedgerSummary        balanceSeconds, monthGrossExtraSeconds, weekDeltaSeconds, ytdDeltaSeconds, todayDeltaSeconds
LeaveBalance         typeID, accruedSeconds, usedSeconds, remainingSeconds
```

---

## 4. Ledger rules (package `OTLedger`)

All computation is pure: `(Store, DayKey range, now: Date, calendar/timeZone) → [DayResult]`.

### 4.1 Which schedule applies to a day
1. `DayOverride.kind == .dayOff` → no window, expected 0, kind `.dayOff`.
2. `DayOverride.kind == .schedule(s)` → window from `s`.
3. Holiday on that day → no window, kind `.holiday`.
4. Otherwise the `ScheduleVersion` with the latest `effectiveFrom <= day`; its `days[weekday]`.
   `isWorkday == false` → no window, kind `.weekend`. (Any non-workday reads as `.weekend` for ledger purposes.)
5. No schedule version yet → treat every day as no window.
6. `DayOverride.excused == true` → kind `.excused`, delta forced to 0 (components still computed and shown).

A window is `[S, E]` on that calendar day in the user's time zone. `S < E` required; a
schedule crossing midnight is not supported in v1 (validation rejects it).
Expected seconds = `(E − S) − unpaidBreak`, floor 0. (Break only affects the Excel
"expected paid hours" column; the ledger works on presence, see 4.3.)

### 4.2 Presence on a day
* A presence interval is `[enteredAt, exitedAt]`. Open sessions (`exitedAt == nil`) use
  `min(now, endOfDay)` and set flag `.openPresence`.
* Sessions are clipped to the day. A session crossing midnight contributes to both days.
* **Regular** manual segments (`countsAs == .regular`) are treated exactly like presence.
* Intervals are merged (union). First entry = earliest start, last exit = latest end.

### 4.3 Delta on a day **with** a window `[S, E]`, grace `g`
Let `P` be the merged presence intervals.

```
before   = presence time in (−∞, S)
after    = presence time in (E, +∞)
inside   = presence time in [S, E]
gaps     = (E − S) − inside                  // late arrival + early exit + mid-day absences
```

Grace (applies to boundaries only, never to mid-day gaps):
* First entry in `(S, S + g]`  → treated as `S` (that late-arrival part of `gaps` is forgiven).
* Last exit in `[E − g, E)`    → treated as `E` (that early-exit part of `gaps` is forgiven).
* Last exit in `(E, E + g]`    → `after` becomes 0 for that trailing piece.
* First entry in `[S − g, S)`  → `before` becomes 0 for that leading piece.
Flag `.graceApplied` when any of these fire.

Mid-day gaps: for each pair of consecutive merged intervals `(a_i.end, a_{i+1}.start)`,
the part inside `[S, E]` is a **gap**. Its decision comes from the earlier session's
`followingGapIsWork`:
* `true`  → work gap: added back (`gapsWork`), not deducted.
* `false` → personal: deducted.
* `nil`   → default: **work** if the next interval is at a *different* location, else
  **personal**. Flag `.gapUndecided` and raise an Inbox item.

Time off on the day: `T = Σ timeOff.seconds` for that day, capped at `E − S`.

```
earlyCounted = override.countEarlyArrival ? before : 0
delta      = after + earlyCounted − (gaps − gapsWork) + T − flexSpent + manualExtra + adjustments
grossExtra = after + earlyCounted + manualExtra + max(0, adjustments)
```
`flexSpent` = Σ seconds of time-off entries whose type `deductsFromBank`. (A flex day
therefore nets to zero on the day and −T in the bank: `+T` relief, `−T` spend.)

Why this formula matches the owner's wording:
* Stay late → `after` > 0 → added.
* Leave early → `gaps` includes `E − lastExit` → subtracted.
* Arrive late → `gaps` includes `firstIn − S` → subtracted.
* Arrive early → `before` > 0 → ignored unless `countEarlyArrival`.
* Pop out for lunch → `gaps` includes it → subtracted unless marked work.
* Full day of PTO, stayed home → `gaps = E − S`, `T = E − S` → 0. Balance untouched, PTO −8h.
* Full day of PTO but came in 2h → `inside = 2h`, `gaps = 6h`, `T = 8h` → `+2h`. Worked on a day off: counts.
* Took a flex day → `gaps = 8h`, `T = 8h`, `flexSpent = 8h` → `−8h`. Bank paid for the day.

**In-progress day** (today in `store.calendar`, flag `.inProgress`): a deficit can only come from
time that has already elapsed. With `Ecut = min(E, now)`:
* `now <= S` → no gaps yet: `gaps = 0`, `lateArrival = 0`, `earlyExit = 0`.
* Otherwise gaps are computed against `[S, Ecut]` instead of `[S, E]`:
  `gaps = (Ecut − S) − inside(S, Ecut)`. Late arrival is `firstIn − S` after grace, as on any
  day. The early-exit part is `Ecut − lastExit` once the person has left and `now` is still before
  `E`: it is **provisional** and grows until `E` (grace for it is still judged against `E`, so a
  last exit in `[E − g, E)` is forgiven at every `now`). Mid-day gaps are clipped to `Ecut` too.
* `T` is capped at the **elapsed** window `Ecut − S` (not `E − S`), so time-off relief never
  exceeds what it is relieving: a full-day PTO entry gives `0` at 06:00 (`gaps = 0`, `T = 0`),
  `0` at 11:00 (`gaps = 4h`, `T = 4h`) and `0` after `E`, never `+8.5h` in the morning.
* `flexSpent` is **not** capped and is immediate: it is a bank withdrawal, not relief, so a flex
  day shows `−(E − S)` all day long.
* `after`, `before` / `earlyCounted`, `manualExtra` and `adjustments` are unchanged; open
  sessions and running regular timers already run to `now`.
Completed days (`E <= now`, hence `Ecut == E`) are unaffected. The identity for `delta` above
holds at every instant, with `gapsDeducted` being whatever was actually deducted so far.

### 4.4 Delta on a day **without** a window
```
delta      = presence + manualExtra + adjustments − flexSpent
grossExtra = presence + manualExtra + max(0, adjustments)
```
`T` on a no-window day only moves leave balances; it does not change delta.

### 4.5 No-show
A past workday (window end ≤ now) with `inside == 0`, no regular manual time, `T < (E − S)`,
not excused → flag `.noShow`. The deficit is applied (the day's `delta` is negative). The
Inbox offers ways to fix it (section 6). Nothing is pending; the balance always says
what the data says.

The flag still waits for `E`. On the in-progress day (4.3) the deficit of an empty day grows
with the clock: one second before `E` it is `−(E − S − 1)` without the flag; at `E` it is
`−(E − S)` with it. Full-day time off (`T == E − S` once the window has elapsed) prevents the flag
as before, because `T` is capped at the elapsed window and reaches `E − S` exactly at `E`.

### 4.6 Summaries
* `balance(asOf)`      = `settings.bankStartingSeconds` + Σ delta over `[bankStartingAsOf, asOf]`.
* `monthGrossExtra`    = Σ grossExtra for days in the current calendar month.
* `weekDelta`          = Σ delta for the current week (Sunday–Saturday).
* `ytdDelta`           = Σ delta for the current year.
* Leave balance for type t as of day d:
  `starting + accrued(asOf..d) − Σ timeOff(type t, day ≤ d)`.
  Accrual grants `seconds` on every period boundary from `anchor` through `d` inclusive.

### 4.7 Edge rules
* Overlapping presence sessions at the same location are merged.
* Overlapping sessions at different locations: time at any work location is presence, so they
  merge (union) exactly like same-site overlaps — nothing is cut, the stored facts are untouched
  — and the day is flagged `.overlappingLocations`. For the gap-default rule (4.3) a merged block
  **starts** at the location of the session that started it and **ends** at the location of the
  session that ends it: the latest exit; tie → the later `enteredAt`; tie again → the lexically
  larger UUID string, so the result never depends on the order of `store.presence`. That ending
  session also carries the `followingGapIsWork` decision for the gap after the block.
  `Ledger.gaps` reports the same `fromLocationID` / `toLocationID`. Examples (07:00–15:30
  window): A 07:00–15:30 with B 08:00–09:00 nested → presence 8h 30m, delta 0, flag, no gap;
  A 07:00–12:00 then B 11:30–15:30 → presence 8h 30m, delta 0; A 07:00–10:00 overlapping
  B 09:00–11:00, then A from 12:00 → the block ends at B, the 11:00–12:00 gap defaults to work.
* Durations are integer seconds. Dates compare with second precision.
* Day boundaries follow `settings.timeZoneIdentifier`, DST handled by `Calendar`.

---

## 5. Tracking (package `OTTracking`)

### 5.1 Geofence event interpreter
`interpret(event: LocationEvent, store: inout Store, settings)`; always appends the
event to `store.locationEvents` first (audit log), then:

| Event | Open session state | Action |
|---|---|---|
| enter L | none | open `PresenceSession(L, enteredAt: at)` |
| enter L | open at L | ignore |
| enter L | open at M ≠ L | close M at `at`, open L |
| enter L | closed session at L ended < `flapMergeMinutes` ago | reopen it (`exitedAt = nil`) — flap filter |
| exit L | open at L | close at `at` |
| exit L | open at M ≠ L | close M at `at` (device clearly moved) |
| exit L | none | nothing to close → Inbox item `orphanExit` |

Returns an `InterpretationOutcome` describing what changed so the app can post a
notification ("Left Plant A 5:42 PM: +42m", with Adjust).

### 5.2 Manual timer
Pure functions on `ManualSession`: `start(category, at)`, `pause(at)`, `resume(at)`,
`stop(at)`, `activeSeconds(asOf)`. Only one session may be running or paused at a time;
`Store.activeManualSession` returns it.

### 5.3 Inbox rule engine
`InboxEngine.items(store, dayResults, now) → [InboxItem]`, pure and derived.
Each item has a stable `key`; resolving an item mutates facts so it disappears, or adds
the key to `store.dismissedInboxKeys`.

| key | when | actions |
|---|---|---|
| `gap:<sessionID>` | gap inside a window with `followingGapIsWork == nil` | Work trip · Personal |
| `noshow:<day>` | `.noShow` flag | Add PTO · Add Personal · Remote day (creates regular manual S–E) · Enter hours · Excuse · Keep deficit (dismiss) |
| `exit:<sessionID>` | auto-detected exit that moved the delta (|effect| > 0), today or yesterday, and only the day's final departure (no presence or regular time after it). On a window day the effect is `+after` (stayed late) or else `−earlyExit` (left early; provisional while the day is in progress, 4.3). On a day **without** a window (weekend, holiday, day off) all presence counts (4.4), so the effect is the closed session's own presence on that day, clipped to the day: detail `+3h 10m`, default `Added 3h 10m`. `InboxEngine.exitEffectSeconds(for:dayResult:store:now:)` is the one source of this number, also for the exit notification. | Confirm (dismiss) · Adjust · Remove |
| `early:<day>` | `before > g` and `countEarlyArrival == false` | Count it · Don't count (dismiss) |
| `timer:<manualID>:<n>` | running manual session active ≥ n × nudgeMinutes | Still working (dismiss) · Stop now · Set stop time |
| `stale:<sessionID>` | open presence older than `staleOpenSessionHours` | Set exit time · Delete |
| `orphanExit:<eventID>` | exit without open session | Set arrival time · Ignore (dismiss) |
| `export:<yyyy-mm>` | monthly export file exists and not dismissed | Email · Share · Dismiss |

Items are sorted newest first. `InboxItem` carries `kind`, `day`, `title`, `detail`,
`defaultApplied` text ("Deducted 1h 10m") and typed `actions`.

---

## 6. Exchange (packages `OTZip`, `OTXLSX`, `OTCSV`, `OTExchange`)

### 6.1 Excel workbook (export)
One `.xlsx`, sheets in this order. Dates are real Excel dates (serial numbers with a
date/time number format), durations are both `h:mm` text and decimal hours. Header row
is bold and frozen; columns auto-widthed.

1. **Summary** — generated at, range, balance, this month gross extra, YTD delta, each leave balance.
2. **Days** — one row per day in range: Date, Weekday, Kind, Sched Start, Sched End, Expected (h), First In, Last Out, Presence, Extra After, Extra Before, Early Counted, Gaps Deducted, Gaps Work, Late Arrival, Early Exit, Manual Extra, Manual Regular, Time Off, Flex Spent, Adjustments, Delta (h:mm), Delta (hours), Running Balance (hours), Flags.
3. **Presence** — ID, Location, Entered, Exited, Duration, Source, Gap After, Note.
4. **Manual** — ID, Category, Counts As, Started, Stopped, Active Duration, Segments, Note.
5. **TimeOff** — ID, Date, Type, Hours, Minutes, Note.
6. **Holidays** — ID, Date, Name.
7. **Locations** — ID, Name, Latitude, Longitude, Radius (m), Active.
8. **Schedule** — Effective From, Weekday, Workday, Start, End, Break (min), Version ID.
9. **Overrides** — ID, Date, Kind, Start, End, Break, Count Early, Excused, Note.
10. **Adjustments** — ID, Date, Seconds, Hours, Reason.
11. **Events** — ID, Location, Kind, Time, Source.
12. **Settings** — Key, Value (one row per setting, plus `schemaVersion`, plus the leave balance configs).

Sheets 3–12 carry IDs so the same file imports back losslessly.

### 6.2 Import formats
Detected by extension then by content.
* `.xlsx` written by this app → full round trip of sheets 3–12.
* `.json` backup written by this app → full `Store`.
* `.csv` **import template** (documented in `docs/IMPORT_TEMPLATE.md`). One file, first
  column `record` selects the row type:

```
record,date,start,end,location,category,type,hours,minutes,name,note,id
presence,2026-10-14,07:02,17:42,Plant A,,,,,,,
manual,2026-10-14,19:00,20:15,,After hours,,,,,emails,
timeoff,2026-10-20,,,,,PTO,8,0,,,
holiday,2026-11-26,,,,,,,,Thanksgiving,,
adjustment,2026-10-01,,,,,,1,30,,carry-over from old sheet,
```
  Times are `HH:mm` 24-hour in the app's time zone. `id` optional; when present it is used for de-duplication.
* Holidays-only CSV: `date,name` header also accepted (import option on the Holidays screen).

### 6.3 Merge semantics
`ImportPlan = preview(store, bundle)` → counts of **new**, **updated** (same ID, different content), **unchanged**, **invalid** (with row numbers and reasons). Apply:
* **Merge** (default): new rows inserted, same-ID rows updated, unknown locations created by name, time-off types matched by name (created as `.other` if unknown).
* **Replace**: `Store` wiped except `settings`, then merged. Requires explicit confirmation in the UI.
Rows with no ID de-duplicate on (kind, day, start, end, location/category/type).

### 6.4 Zip and XLSX
`OTZip` writes **stored** (uncompressed) entries with CRC-32 and reads stored and
**deflate** entries using a pure-Swift inflate (RFC 1951) so the package builds and tests
on Linux with no C dependencies. `OTXLSX` writes OOXML (`[Content_Types].xml`,
`_rels/.rels`, `xl/workbook.xml`, `xl/_rels/workbook.xml.rels`, `xl/styles.xml`,
`xl/worksheets/sheetN.xml`, inline strings) and reads workbooks produced by Excel, Numbers,
Google Sheets and itself (shared strings, inline strings, numbers, dates by style).

---

## 7. iOS app (`OTtracker/`)

SwiftUI, iOS 17.0+, Swift 5 language mode, no third-party dependencies.

* **AppModel** (`@Observable`, main actor): owns the `Store`, persistence, and services.
  Every mutation goes through it; it saves (debounced 1 s), refreshes derived results,
  updates widgets, and schedules notifications.
* **Services**: `LocationService` (CLLocationManager region monitoring, `Always`
  permission, relaunch on region events), `NotificationService`, `LiveActivityService`
  (ActivityKit), `BackupService` (iCloud Drive via ubiquity container, daily + on
  significant change), `ExportService` (xlsx/json/csv), `MonthlyExportService`
  (first launch in a new month; file to Documents/Exports; notification; mail compose).
* **Tabs**: Home · Log · Inbox (badge) · Time Off · Settings.
  * Home: balance (big), this month gross extra, today card (schedule, first in, status),
    timer card (start / pause / resume / stop, category, note), "Count early arrival"
    button when applicable, weekly bars and monthly trend (Swift Charts).
  * Log: days list newest first, grouped by week; day detail shows every component of
    the delta and every session; everything editable; add presence / manual / adjustment.
  * Inbox: the items of section 5.3 with their actions.
  * Time Off: balances per type, book time off, book a flex day from the bank, holidays
    (list, add, import CSV), types management.
  * Settings: schedule (per weekday, effective from), day overrides, locations (map, search,
    radius), categories, grace, nudge, starting balance, iCloud backup + restore, export
    (range picker, Share), import (file picker → preview → Merge/Replace), monthly export
    email, about.
* **Onboarding**: schedule → first location → permissions (location Always, notifications).
* **Deep links**: `ottracker://timer/start`, `ottracker://inbox`, `ottracker://log/<day>`.
* **Widgets** (`OTtrackerWidgets/`): small/medium balance widget reading the App Group
  summary; "Start timer" button deep-links to the app. Live Activity shows elapsed
  time and category for a running timer with pause/stop deep links.

---

## 8. Project layout

```
OTtracker/                      iOS app (Xcode synchronized folder)
OTtrackerWidgets/               widget + Live Activity extension
OTtracker.xcodeproj/            hand-maintained, Xcode 16+ format (objectVersion 77)
Packages/OTCore/                Swift package: OTModels, OTLedger, OTTracking, OTZip, OTXLSX, OTCSV, OTExchange, OTCore (umbrella)
docs/                           SPEC.md (this), IMPORT_TEMPLATE.md, BUILD.md
.github/workflows/ci.yml        Linux: swift test · macOS: swift test + xcodebuild
```

Identifiers: bundle `com.diakonindustries.ottracker`, widgets
`com.diakonindustries.ottracker.widgets`, App Group `group.com.diakonindustries.ottracker`,
iCloud container `iCloud.com.diakonindustries.ottracker`.
