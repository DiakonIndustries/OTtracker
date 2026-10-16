# OTtracker CSV import template

One CSV file, one row per record. The first column says what kind of record the row is.
Written for a person filling it in by hand **and** for an AI that is handed someone's own
spreadsheet (a timesheet, a PTO list, a holiday calendar) and asked to convert it into this
template. Everything below is the whole contract; nothing else is needed.

## The columns

```
record,date,start,end,location,category,type,hours,minutes,name,note,id
```

| column | meaning |
|---|---|
| `record` | Row kind: `presence`, `manual`, `timeoff`, `holiday`, `adjustment`. Shorthands `pto`, `personal`, `flex` mean `timeoff` of that type. Case does not matter. |
| `date` | Calendar day, `yyyy-MM-dd` (e.g. `2026-10-14`). `M/d/yyyy` is accepted too. Required on every row. |
| `start`, `end` | Wall-clock times, 24-hour `HH:mm` (`07:02`, `17:42`); `7:02 am` / `5:42 pm` also work. In the app's own time zone. |
| `location` | Work-site name for `presence` rows (`Plant A`). Matched to the app's locations by name, case-insensitive. |
| `category` | Category for `manual` rows (`Home work`, `After hours`, `Travel`, `Other`, or any text). |
| `type` | Time-off type name for `timeoff` rows (`PTO`, `Personal`, `Flex`, or a custom name). For `manual` rows, optionally `regular` (fills the schedule) or `extra` (default). |
| `hours`, `minutes` | A duration. Either may be empty; decimals are fine (`7.5`). Negative values are only meaningful for `adjustment`. |
| `name` | Holiday name for `holiday` rows. |
| `note` | Free text. For `adjustment` rows this is the reason. |
| `id` | Optional UUID. Leave empty unless the row came out of this app. |

Columns may be in any order; the header names are what matter. Extra columns are ignored.
Blank rows are skipped. Quote a field that contains a comma, a quote or a line break
(standard CSV, `""` for a literal quote). UTF-8, with or without BOM; LF or CRLF.

## Record kinds and the columns each one uses

| record | required | optional | result |
|---|---|---|---|
| `presence` | `date`, `start`, `end`, `location` | `note`, `id` | Time at a work site. A location name the app does not know is created as an inactive placeholder (0, 0, 200 m) that you can fix on the map later. |
| `manual` | `date`, `start`, `end` | `category` (default: the app's default category), `type` (`extra`/`regular`), `note`, `id` | Work done anywhere else (home, after hours, travel). Counts as extra unless `type` is `regular`. |
| `timeoff` | `date`, `type`, `hours` and/or `minutes` | `note`, `id` | Time off of that type. Total must be more than zero. Unknown type names are created as a plain "other" type. |
| `pto` / `personal` / `flex` | `date`, `hours` and/or `minutes` | `type` (overrides the shorthand), `note`, `id` | Same as `timeoff` with the type implied. `flex` is paid from the overtime bank. |
| `holiday` | `date` | `name` (default `Holiday`), `id` | A holiday: no hours expected that day. |
| `adjustment` | `date`, `hours` and/or `minutes` (non-zero, signed) | `note` (the reason), `id` | A signed correction to the bank, e.g. a carried-over balance. `-1`,`30` means −1 h 30 m. |

Anything else in `record` is reported as an invalid row (with its line number) and skipped;
the valid rows still import.

## Times, days and the next-day rule

* Times are the wall clock in the app's time zone on `date`. DST is handled by the calendar:
  `01:30`–`03:30` on 2026-03-08 in New York is one hour.
* If `end` is earlier than `start`, the block ends on the **next** day:
  `presence,2026-11-01,22:00,01:30,Plant A` runs from 22:00 on Nov 1 to 01:30 on Nov 2.
  `end` equal to `start` is an error.
* `hours`/`minutes` are a duration, not a clock time: `8`,`0` is eight hours; `0`,`45` is 45 minutes; `1.5`,`` is 1 h 30 m.

## IDs, merge and replace

* **Without an `id`** a row is matched to what the app already has by its content: presence by
  location + start + end; manual by category + start + end; time off by day + type + duration;
  holiday by day; adjustment by day + duration + reason. Importing the same file twice therefore
  changes nothing.
* **With an `id`** (a UUID the app wrote in an earlier export) the row updates that record even if
  its times changed. An unknown id falls back to content matching.
* The preview shows, per kind: **new**, **updated** (matched but different), **unchanged**,
  and **invalid** rows with line numbers and reasons.
* **Merge** (default) adds new rows and updates matched ones; nothing is deleted.
* **Replace** first wipes every fact (presence, manual, time off, holidays, adjustments, locations,
  schedule, overrides, events) but keeps the settings and the built-in time-off types, then imports
  the file. Needs explicit confirmation in the app.

## Holidays-only file

A two-column file is also accepted (Time Off → Holidays → Import):

```
date,name
2026-11-26,Thanksgiving
2026-12-25,Christmas
```

## Full example

```
record,date,start,end,location,category,type,hours,minutes,name,note,id
presence,2026-10-14,07:02,17:42,Plant A,,,,,,,
manual,2026-10-14,19:00,20:15,,After hours,,,,,emails,
timeoff,2026-10-20,,,,,PTO,8,0,,,
holiday,2026-11-26,,,,,,,,Thanksgiving,,
adjustment,2026-10-01,,,,,,1,30,,carry-over from old sheet,
```

More rows that are valid:

```
pto,2026-10-21,,,,,,4,,,half day,
personal,2026-10-22,,,,,,,30,,,
flex,2026-10-23,,,,,,8,,,,
manual,2026-10-24,09:00,17:00,,Home work,regular,,,,remote day,
presence,2026-11-01,22:00,01:30,Plant A,,,,,,night shift,
adjustment,2026-11-05,,,,,,-1,30,,gave back time,
```

## Converting someone's spreadsheet (notes for an AI)

1. Decide the record kind per source row: time at a site → `presence`; work from home or after
   hours → `manual`; vacation/sick/personal days → `timeoff` (or `pto`/`personal`); public holidays
   → `holiday`; an opening balance or a one-off correction → `adjustment`.
2. Normalise dates to `yyyy-MM-dd` and times to `HH:mm`; drop seconds. A full day of PTO is
   `hours` = the person's scheduled hours (ask or use 8). Round minutes to whole numbers.
3. Put the site name the person uses in `location`; keep it identical across rows.
4. Never invent `id`s. Leave the column empty.
5. Emit exactly the header above, then one line per record, nothing else (no totals, no blank
   lines in between, no comments). Quote fields that contain commas.
6. The app's own Excel export (.xlsx) and JSON backup are also importable, but those are written by
   the app itself; a converted spreadsheet should use this CSV.
