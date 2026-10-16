# Building and installing OTtracker

## Requirements

* A Mac with Xcode 16 or newer (Xcode 26 is fine).
* A paid Apple Developer account (for App Groups, iCloud, Live Activities and 1-year install signing).
* iPhone on iOS 17 or newer.

## First time

1. Clone the repo and open `OTtracker.xcodeproj`.
2. Select the **OTtracker** target → *Signing & Capabilities* → pick your Team.
   Xcode registers the bundle ID `com.diakonindustries.ottracker`, the App Group and the
   iCloud container on your account automatically. Do the same for the
   **OTtrackerWidgetsExtension** target (same Team).
   If you want different identifiers, change `PRODUCT_BUNDLE_IDENTIFIER` on both targets and the
   constants in `Packages/OTCore/Sources/OTModels/Shared.swift`, plus both `.entitlements` files.
3. Plug in the phone, choose it as the run destination, press Run.
4. On the phone, allow notifications, then **Location → Always** (iOS asks twice: first
   "While Using", later "Always"; you can also set it in Settings → OTtracker → Location).
5. Complete onboarding: schedule, first work location, permissions.

## Logic tests without a Mac

```
tools/swift test          # runs Swift 6.1 in Docker if swift is not installed
```

## CI

`.github/workflows/ci.yml` runs the package tests on Linux and macOS and builds the app for the
iOS Simulator on every push.

## Where data lives

* `Application Support/OTtracker/store.json` — the one document that is the whole app state.
* `Documents/Exports/OTtracker-YYYY-MM.xlsx` — automatic monthly exports (visible in the Files app).
* iCloud Drive → OTtracker → Backups — JSON snapshots, restorable from Settings → Backup.
