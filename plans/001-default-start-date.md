# 001 — Start date defaults to the 1st of the current month

## Goal

The reconciliation start date should be the **1st of the current month** every
time the app starts. The user can change it in Settings for the current session
only; it goes back to the 1st of the month the next time the app is launched.
The main screen shows, subtly, which date is in use.

## Why

The start date is currently saved to `UserDefaults` and survives relaunches. It
was left on an October date, and the phone silently reconciled from October
while the user expected November. That produced different results from the
command-line report (which defaults to the 1st of the month) and looked like an
engine bug. Starting at the 1st of the month is also the safest window:
everything earlier has normally been reconciled already, so it cannot compete
with this month's transactions (see SPEC.md §3 and the October discussion).

## Scope

App target only (`YNAB Reconciler/`). Files expected to change:
`ReconcileViewModel.swift`, `ReconcileView.swift`, `SettingsView.swift`.

### 1. Stop persisting the start date — `ReconcileViewModel.swift`

- `persistParameters()`: remove the line that writes `settings.startDate`.
- `loadSettings(defaults:accountSettings:)`: remove the line that reads
  `DefaultsKey.startDate`; keep the value from `ReconcileSettings.defaults()`
  (already the 1st of the current month).
- In `init`, remove any value left under `DefaultsKey.startDate`
  (`defaults.removeObject(forKey: DefaultsKey.startDate)`) so old installs stop
  carrying a stale date. Keep the `DefaultsKey.startDate` constant for that
  purpose.
- All other persisted settings are unchanged.

### 2. Track automatic vs custom — `ReconcileViewModel.swift`

- Store the automatic date the model last applied, e.g.
  `private var automaticStartDate: Date`, set to the month start at init.
- Add `var isStartDateCustom: Bool` — true when `settings.startDate` is not on
  the same calendar day as `automaticStartDate`
  (`Calendar.current.isDate(_:inSameDayAs:)`).
- Add `func useAutomaticStartDate()` — sets `automaticStartDate` to the 1st of
  the current month and `settings.startDate` to the same value.
- At the start of `refresh()` (before anything reads `settings.startDate`): if
  the date is **not** custom, call `useAutomaticStartDate()`. This rolls the
  window forward when the app stays open across a month boundary, and leaves a
  manual choice alone.
- Add `var startDateCaption: String` for the main screen:
  - automatic: `Reconciling from 1 Nov 2026`
  - custom: `Reconciling from 1 Oct 2026 · custom until you close the app`
  Format the date with `Date.FormatStyle`
  (`.dateTime.day().month(.abbreviated).year()`), so it follows the device
  locale.

### 3. Main screen caption — `ReconcileView.swift`

- Show `model.startDateCaption` as the first row of the list, in **both**
  states: with a reconciliation, above `BalanceSummaryView`, and in the "Ready
  to reconcile" empty state.
- Subtle: `.font(.footnote)`, `.foregroundStyle(.secondary)`, centred, clear
  row background, no separator — the same treatment as the existing "No gap
  between UP and YNAB." line.
- Accessibility label: the caption text.

### 4. Settings — `SettingsView.swift`

- Keep the existing `DatePicker` bound to `model.settings.startDate`.
- Add a footer line under it (the Accounts section footer may gain a second
  line): *"Defaults to the 1st of this month. A change applies until you close
  the app."*
- When `model.isStartDateCustom` is true, show a button below the picker:
  **"Use 1st of this month"**, calling `model.useAutomaticStartDate()`.

## Must not change

- Anything under `TransactionKit/`, `scripts/`, `Fixtures/`.
- How `settings.startDate` is used by the refresh (`localDate(from:)`, the Up
  and YNAB `since` parameters).
- Persistence of every other setting, the Keychain, the pushed log.
- The command-line report already defaults to the 1st of the month; leave it.

## Acceptance criteria

1. Fresh launch: Settings shows the 1st of the current month; the main screen
   caption reads `Reconciling from 1 <Mon> <Year>` with no "custom" suffix.
2. Change the date in Settings, return to Reconcile: the caption shows the new
   date with `· custom until you close the app`, and a refresh uses that date.
3. "Use 1st of this month" appears only while the date is custom and restores
   the automatic date and caption.
4. Pressing Save in Settings does not make the custom date survive a relaunch.
5. Quit the app completely (swipe away) and relaunch: back to the 1st of the
   month, no suffix — including on an install that previously had a saved
   October date.
6. The caption is visible both before the first refresh and after it, and
   reads well in light mode, dark mode and the largest Dynamic Type size.

## Tests

The app target has no unit-test target; do not add one in this plan.

- Build `YNAB Reconciler` for an iPhone simulator: no new warnings.
- `swift test --package-path TransactionKit`: all pass (nothing there should
  change).
- Manual: acceptance criteria 1–6 in the simulator (criterion 5: stop the app
  from Xcode and run it again).
