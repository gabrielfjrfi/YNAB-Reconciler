# Response to 001c-caption-section-and-reconciled-wording

## Status
Partially done — code complete, build and engine tests pass; manual simulator checks not run.

## Changes
- `YNAB Reconciler/ReconcileView.swift` — `StartDateCaption` is wrapped in its own `Section`, still the last item in the list in both states.
- `YNAB Reconciler/ReconcileViewModel.swift` — added `private(set) var reconciledStartDate: Date?`, set in `refresh()` next to `lastRefreshDate` (using the start date captured when that refresh began) and in `installFixture(...)`; `startDateCaption` reads `Reconciled from <reconciledStartDate>` when `reconciliation != nil` (falling back to `settings.startDate`) and `Reconciling from <settings.startDate>` otherwise.

## Deviations from the plan
None.

## Verification
- Build: succeeded via Xcode `BuildProject`, no errors (warnings introduced: none seen; I did not re-read the log, and no specific iPhone simulator destination was picked).
- TransactionKit tests: 38 passed (22 + 16), 0 failed.
- Manual checks: criteria 1–4 not run in the simulator.
  - Not exercised: that the section adds no visible background or spacing of its own. `StartDateCaption` already has a clear row background and no separator, but I haven't seen it rendered.
  - Failed and cancelled refreshes leave `reconciledStartDate` untouched, and `reconcile()` never sets it. I checked this by reading the code, not by running it.

## Open questions
None.

## Suggestions
None.
