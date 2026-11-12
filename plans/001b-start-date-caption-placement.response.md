# Response to 001b-start-date-caption-placement

## Status
Partially done — all code changes made, build and engine tests pass; manual simulator checks not run.

## Changes
- `YNAB Reconciler/ReconcileView.swift` — caption moved to the last list row (after the Group, so it is below the Sent section and below the "Ready to reconcile" card), with `listRowInsets(top 4, leading 16, bottom 4, trailing 16)`; removed `ReconciledSection`, `ReconciledGroupHeader`, `ReconciledRowLabel` and the two "Reconciled · Expanded" previews; removed the Pending badge use and the ", pending in Up" accessibility text.
- `YNAB Reconciler/ReconcileViewModel.swift` — `startDateCaption` no longer has the "custom" suffix; removed `isPending` (and its three assignments), `ReconciledRow`, `ReconciledGroup`, `reconciledGroups`, `matchedRow`, `splitRow`, `zeroNetRow`.
- `YNAB Reconciler/SettingsView.swift` — Accounts footer back to its original single line; "Use 1st of this month" button unchanged.
- `YNAB Reconciler/RowDetailView.swift` — removed `pendingRow` and both uses; preview renamed "Row detail · Add" and pointed at the first add row.
- `YNAB Reconciler/AppTheme.swift` — removed `PendingBadge`.
- `YNAB Reconciler/PreviewData.swift` — removed `isPending: true`.

## Deviations from the plan
- One caption row placed after the `Group` serves both states, rather than two separate insertions. Same result.

## Verification
- Build: succeeded via Xcode `BuildProject`; no warnings from the code (the only warning in the log is the AppIntents metadata-extraction notice from the build tooling). No specific iPhone simulator destination was picked.
- Search of `YNAB Reconciler/` for `PendingBadge`, `isPending`, `ReconciledSection`, `reconciledGroups` (and `ReconciledRow`/`ReconciledGroup`): no matches (criterion 6 pass).
- TransactionKit tests: 38 passed (22 + 16), 0 failed.
- Manual checks: criteria 1–5 and 7 not run in the simulator. In particular, whether the caption clears the floating tab bar at the bottom (criterion 2, including the largest Dynamic Type) is unverified; I relied on the List's automatic safe-area inset and added no extra padding.

## Open questions
None.

## Suggestions
- `hasPendingTransactions` in `ReconcileViewModel.swift` is unrelated to the removed badge (it means "has rows needing action"), so I left it, but the name is now easy to confuse with held transactions.
