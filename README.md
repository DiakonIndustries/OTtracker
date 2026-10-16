# OTtracker

Personal iOS app that keeps an honest ledger of extra time worked and time off taken.
Geofenced work locations, manual timers, PTO/personal/flex balances, Excel export and import.

* `docs/SPEC.md` — how the app thinks: rules, data model, screens.
* `docs/IMPORT_TEMPLATE.md` — the CSV format the import button accepts.
* `docs/BUILD.md` — how to build and install on your iPhone.
* `Packages/OTCore` — all the logic, as a Swift package with tests (runs on Linux and macOS).
* `OTtracker/`, `OTtrackerWidgets/` — the SwiftUI app and its widget extension.

```
tools/swift test        # run the logic tests (uses Docker if swift is not installed)
```
