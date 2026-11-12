# 001b — Move the start-date caption to the bottom; trim Settings text

Follow-up to [001](001-default-start-date.md), after testing on the phone.

## Goal

1. The "Reconciling from …" caption sits at the **bottom** of the main list,
   not the top, so it no longer pushes the balance card down.
2. Settings loses the explanatory footer line added in 001.

## Why

At the top, the caption is a full list row with its own spacing above the
balance card. After a refresh it takes a large band of the first screen for a
line of secondary information. The Settings footer line repeats what the
behaviour already makes obvious.

## Scope

App target only. Files expected to change: `ReconcileView.swift`,
`SettingsView.swift`.

### 1. Caption placement — `ReconcileView.swift`

- **With a reconciliation:** remove `StartDateCaption` from above
  `BalanceSummaryView`. Show it as the **last** item in the list, after
  `ReconciledSection`.
- **Empty state ("Ready to reconcile"):** show it **below** the "Ready to
  reconcile" card, not above it.
- Keep the caption's styling from 001 (footnote, secondary, centred, clear row
  background, no separator). Tighten the row so it takes about one line of
  height, e.g. `.listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))`.
- When scrolled to the very bottom, the caption must be fully visible above
  the floating tab bar, not hidden behind it.
- Keep the caption text unchanged, including the
  `· custom until you close the app` suffix when the date is custom.

### 2. Settings footer — `SettingsView.swift`

- Remove the line *"Defaults to the 1st of this month. A change applies until
  you close the app."* from the Accounts section footer. The footer goes back
  to its original single line: *"Plan and account IDs are not secret and are
  stored in app settings."*
- Keep the **"Use 1st of this month"** button. It still appears only while the
  date is custom.

## Must not change

- Anything in `ReconcileViewModel.swift`: the start-date behaviour from 001 is
  correct.
- Anything under `TransactionKit/`, `scripts/`, `Fixtures/`.
- The Pending badge logic. Showing it only on rows whose Up transaction is
  still `HELD` is correct.

## Acceptance criteria

1. After a refresh, the balance card is the first thing under the navigation
   title, with no caption row above it.
2. Scrolled to the bottom, the caption is the last line, readable and fully
   above the tab bar.
3. Before the first refresh, the caption appears under the "Ready to
   reconcile" card.
4. The Settings Accounts footer shows only the original line. The "Use 1st of
   this month" button still appears after changing the date, and only then.

## Tests

- Build `YNAB Reconciler` for an iPhone simulator: no new warnings.
- `swift test --package-path TransactionKit`: all pass.
- Manual: acceptance criteria 1–4 in the simulator, including the largest
  Dynamic Type size for criterion 2.
