# 001b — Caption to the bottom, trim Settings text, remove Pending badge

Follow-up to [001](001-default-start-date.md), after testing on the phone.

## Goal

1. The "Reconciling from …" caption sits at the **bottom** of the main list,
   not the top, so it no longer pushes the balance card down.
2. Settings loses the explanatory footer line added in 001.
3. The **Pending** badge is removed everywhere. The user doesn't need to see
   which Up transactions are still held.

## Why

At the top, the caption is a full list row with its own spacing above the
balance card. After a refresh it takes a large band of the first screen for a
line of secondary information. The Settings footer line repeats what the
behaviour already makes obvious.

## Scope

App target only. Files expected to change: `ReconcileView.swift`,
`SettingsView.swift`, `RowDetailView.swift`, `ReconcileViewModel.swift`,
`AppTheme.swift`, `PreviewData.swift`.

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
- The caption always reads `Reconciling from <date>`. Remove the
  `· custom until you close the app` suffix: in `ReconcileViewModel.swift`,
  `startDateCaption` returns the same text whether or not the date is custom.
  Keep `isStartDateCustom`, which the Settings button still uses.

### 2. Settings footer — `SettingsView.swift`

- Remove the line *"Defaults to the 1st of this month. A change applies until
  you close the app."* from the Accounts section footer. The footer goes back
  to its original single line: *"Plan and account IDs are not secret and are
  stored in app settings."*
- Keep the **"Use 1st of this month"** button. It still appears only while the
  date is custom.

### 3. Remove the Pending badge

- Delete the `PendingBadge` view (`AppTheme.swift`) and every use of it:
  the list row in `ReconcileView.swift` and `pendingRow` in
  `RowDetailView.swift` (remove both places it is inserted).
- Remove `isPending` from `ActionRow` and its three assignments in
  `ReconcileViewModel.swift` (add, share and amend rows), plus the
  `isPending: true` in `PreviewData.swift`.
- Remove the `", pending in Up"` part of the row accessibility label in
  `ReconcileView.swift`.
- The preview `"Row detail · Pending add"` in `RowDetailView.swift`: point it
  at any add row, and rename it `"Row detail · Add"`.
- **Keep** these, which are not the badge:
  - the "Was pending at $X, settled at $Y" cause text for settled-differently
    corrections (`RowDetailView.swift`);
  - the "Pending transactions" setting in `SettingsView.swift`, which decides
    the cleared status sent to YNAB for held transactions;
  - every use of `status == "HELD"` that feeds sending (`heldStatus`).

## Must not change

- The start-date behaviour in `ReconcileViewModel.swift` from 001 is correct.
  Only the `isPending` lines and `startDateCaption` may change in that file.
- Anything under `TransactionKit/`, `scripts/`, `Fixtures/`.

## Acceptance criteria

1. After a refresh, the balance card is the first thing under the navigation
   title, with no caption row above it.
2. Scrolled to the bottom, the caption is the last line, readable and fully
   above the tab bar. After picking a custom date in Settings it shows that
   date with no suffix.
3. Before the first refresh, the caption appears under the "Ready to
   reconcile" card.
4. The Settings Accounts footer shows only the original line. The "Use 1st of
   this month" button still appears after changing the date, and only then.
5. No row, in the list or in its detail screen, shows a Pending badge. A held
   transaction looks like any other row and can still be sent.
6. A search of `YNAB Reconciler/` for `PendingBadge` and `isPending` finds
   nothing.

## Tests

- Build `YNAB Reconciler` for an iPhone simulator: no new warnings.
- `swift test --package-path TransactionKit`: all pass.
- Manual: acceptance criteria 1–6 in the simulator, including the largest
  Dynamic Type size for criterion 2.
