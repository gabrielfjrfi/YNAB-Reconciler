# 001c — Caption in its own section; "Reconciled" after a refresh

Follow-up to [001b](001b-start-date-caption-placement.md), after testing on the
phone.

## Goal

1. The "Ready to reconcile" card shows in full, with all four corners rounded.
2. After a successful refresh, the caption reads **"Reconciled from …"**
   instead of "Reconciling from …".

## Why

1. In 001b the caption was placed after the `Group` in the same implicit list
   section as the "Ready to reconcile" card. The card styling rounds only the
   outer corners of a section, so the card lost its bottom corners (in 001 it
   lost its top corners for the same reason). After a refresh the problem
   doesn't show, because the action groups are their own sections.
2. "Reconciling" reads as if work is still in progress after the results are on
   screen.

## Scope

App target only. Files expected to change: `ReconcileView.swift`,
`ReconcileViewModel.swift`.

### 1. Caption in its own section — `ReconcileView.swift`

- Wrap `StartDateCaption` in its **own** `Section`, so it is never part of the
  same section as the "Ready to reconcile" card or any other card.
- Keep its look from 001b: footnote, secondary, centred, clear row background,
  no separator, compact insets. The section should add no visible card or
  background of its own.
- It stays the last item in the list in both states.

### 2. "Reconciled" wording — `ReconcileViewModel.swift`

- Add `private(set) var reconciledStartDate: Date?`: the start date used by the
  last **successful** refresh.
  - Set it in `refresh()` at the point where a fetched result is installed
    (alongside `lastRefreshDate`), using the start date that refresh actually
    used.
  - Set it in `installFixture(...)` too, so previews behave the same.
  - Do not change it when a refresh fails or is cancelled.
  - Re-running the engine on existing data (`reconcile()`, e.g. after a split
    pick or Save in Settings) does not change it.
- `startDateCaption`:
  - `Reconciled from <date>` when `reconciliation != nil`,
    `reconciledStartDate != nil`, and `reconciledStartDate` is the same
    calendar day as `settings.startDate`;
  - otherwise `Reconciling from <date>` (before the first refresh, or after
    the date was changed and not yet refreshed).
  - `<date>` is `settings.startDate`, formatted as now.

## Must not change

- The start-date behaviour from 001 (automatic 1st of month, session-only
  custom date, "Use 1st of this month").
- Anything under `TransactionKit/`, `scripts/`, `Fixtures/`.
- Everything else on the main screen.

## Acceptance criteria

1. Before the first refresh, the "Ready to reconcile" card has all four corners
   rounded, and the caption `Reconciling from 1 <Mon> <Year>` sits below it as
   plain text.
2. After a successful refresh, the caption at the bottom reads
   `Reconciled from 1 <Mon> <Year>`.
3. Change the date in Settings and return without refreshing: the caption
   reads `Reconciling from <new date>`. Refresh: it reads
   `Reconciled from <new date>`.
4. A failed refresh (e.g. airplane mode) does not turn "Reconciling" into
   "Reconciled".

## Tests

- Build `YNAB Reconciler` for an iPhone simulator: no new warnings.
- `swift test --package-path TransactionKit`: all pass.
- Manual: acceptance criteria 1–4 in the simulator. Use the empty state for
  criterion 1. For criteria 2 and 3, the fixture preview or a real refresh is
  fine.
