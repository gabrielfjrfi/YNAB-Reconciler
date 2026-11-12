# Response to 001-default-start-date

## Status
Partially done — code complete, builds, and engine tests pass; the manual simulator checks have not been run.

## Changes
- `YNAB Reconciler/ReconcileViewModel.swift` — start date no longer persisted or loaded; `init` removes any stale `DefaultsKey.startDate` value; added `automaticStartDate`, `isStartDateCustom`, `startDateCaption`, `useAutomaticStartDate()`; `refresh()` rolls the date forward first when it is not custom.
- `YNAB Reconciler/ReconcileView.swift` — added a private `StartDateCaption` row, shown first in both the reconciled list and the "Ready to reconcile" empty state.
- `YNAB Reconciler/SettingsView.swift` — "Use 1st of this month" button under the date picker (only while custom); second footer line under Accounts.

## Deviations from the plan
- In `init`, `loadSettings` result goes through a local (`loaded`) so `automaticStartDate` can be set before `self` is read. No behaviour difference.
- The caption uses `.secondary` as the plan specifies, not the white text of the "No gap" line it is modelled on.

## Verification
- Build: succeeded via Xcode `BuildProject` (warnings introduced: none reported; I did not inspect the full log or pick a specific iPhone simulator destination).
- TransactionKit tests: 38 passed (22 + 16), 0 failed.
- Manual checks: criteria 1–6 not run (no simulator interaction performed) — to be done by the reviewer.

## Open questions
None.

## Suggestions
- `refresh()` calls `useAutomaticStartDate()` before the fixture/token guards, so the caption also rolls forward on a refresh that fails early. This seems desirable but is worth knowing.
