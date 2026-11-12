# Response to 002-app-tests-and-simulator-verification

## Status
Partially done — everything is implemented and verified except acceptance criterion 3: with `-FixtureRefreshFails` the app stays in the empty state, but the failure message is not visible there (see Open questions).

## Changes
- `YNAB Reconciler/PreviewData.swift` — (DEBUG only) moved the edge-fixture loading out of `fixturePreview()` into a shared `installEdgeFixtures()`; added `fixtureLaunch(refreshFails:)` (own `FixtureLaunch` defaults suite cleared at launch, in-memory credentials and pushed log, starts empty, refresh installs the edge fixtures or sets `"Refresh failed. Try again in a moment."`) and a small weak `FixtureModelBox` so the refresh closure can reach its model. `fixturePreview()` behaves as before.
- `YNAB Reconciler/ContentView.swift` — (DEBUG only) `init()` reads `-FixtureData` / `-FixtureRefreshFails` from `ProcessInfo` and uses `fixtureLaunch`. Without the arguments it is unchanged.
- `YNAB ReconcilerTests/YNAB_ReconcilerTests.swift` — new Swift Testing suite `StartDateTests` with the nine tests from the plan, an in-memory `CredentialStore`, and a fresh `UserDefaults` suite per test (removed afterwards).
- `YNAB Reconciler.xcodeproj/project.pbxproj` — new `YNAB ReconcilerTests` unit-test target (hosted by the app: `TEST_HOST`/`BUNDLE_LOADER`, iOS only, deployment target 27.0, bundle id `com.gabrieljauregui.YNABreconcileTests`).
- `YNAB Reconciler.xcodeproj/xcshareddata/xcschemes/YNAB Reconciler.xcscheme` — new shared scheme file with the test target in its Test action. The scheme was previously only auto-generated and had no test action, so there was nothing to edit; I wrote the file by hand.
- `plans/README.md` — rule 6 and the Verification part of the response template replaced as specified; the rest unchanged.
- `plans/002-app-tests-and-simulator-verification/` — screenshots, listed below.

## Deviations from the plan
- The shared scheme file had to be created by hand (see above).
- Nothing from section 1 compiles into Release (all inside `#if DEBUG`), but I could not confirm this with a Release build: **the Release configuration already fails to build at `HEAD`** (checked on a clean `git archive` copy). The `#Preview` blocks in `ContentView`, `ReconcileView`, `ReviewSheet`, `RowDetailView`, `SettingsView` and `SplitPickerView` call the DEBUG-only fixture helpers, so Release errors with "type 'ReconcileViewModel' has no member 'fixturePreview'". My change adds no new Release errors. I did not fix it (out of scope).

## Verification
- Build: succeeded on iPhone 18 Pro (iOS 27.2 simulator). Warnings in changed files: none (build log read with severity "warning": 0 entries, after touching the changed files to force a recompile).
- Engine tests: 38 passed (22 + 16), 0 failed.
- App tests: 9 passed, 0 failed (read from the xcresult). Added: `newModelStartsOnFirstOfMonth`, `legacyStoredStartDateIsRemovedAndIgnored`, `changingTheDateMakesItCustomUntilReset`, `savingSettingsDoesNotPersistTheStartDate`, `emptyStateCaptionSaysReconciling`, `captionSaysReconciledOnceResultsAreInstalled`, `captionKeepsTheOldDateWhenSettingsChange`, `failedRefreshLeavesCaptionAndReconciledDateAlone`, `edgeFixturesSatisfyTheBalanceIdentity`.
- Simulator checks (iPhone 18 Pro, iOS 27.2):
  1. 002 criterion 1: `YNAB ReconcilerTests` exists, runs from the scheme's Test action, all nine pass — pass (test run above)
  2. 002 criterion 2: `-FixtureData` shows the empty state with `Reconciling from 1 Nov 2026` — pass — [screenshot](002-app-tests-and-simulator-verification/01-fixture-empty-state.png); pull to refresh shows the edge-fixture results — [screenshot](002-app-tests-and-simulator-verification/02-fixture-results-top.png), with `Reconciled from 1 Nov 2026` at the bottom — pass — [screenshot](002-app-tests-and-simulator-verification/03-fixture-results-bottom-caption.png)
  3. 002 criterion 3: `-FixtureData -FixtureRefreshFails`, pull to refresh stays in the empty state — pass — [screenshot](002-app-tests-and-simulator-verification/08-refresh-fails-empty-state-no-message.png); shows the failure message — **fail** on the Reconcile tab; the message is set and appears on the Settings tab — [screenshot](002-app-tests-and-simulator-verification/09-refresh-failed-message-only-in-settings.png)
  4. 002 criterion 4: normal launch (no arguments) uses live settings: empty tokens and IDs, no fixture values — pass — [screenshot](002-app-tests-and-simulator-verification/10-normal-launch-real-settings.png)
  5. 002 criterion 5: README has the new rule 6 and template, rest unchanged — pass (diff reviewed)
  6. 001c criteria redone with screenshots:
     - 001c-1 empty-state card has all four corners rounded, caption `Reconciling from 1 Nov 2026` below it as plain text — pass — [screenshot](002-app-tests-and-simulator-verification/01-fixture-empty-state.png)
     - 001c-2 after a refresh the bottom caption reads `Reconciled from 1 Nov 2026`, fully above the tab bar — pass — [screenshot](002-app-tests-and-simulator-verification/03-fixture-results-bottom-caption.png)
     - 001c-3 changed the date to 10 Nov in Settings (the "Use 1st of this month" button appears, [screenshot](002-app-tests-and-simulator-verification/05-settings-custom-date-use-1st-button.png)); back on Reconcile without refreshing, the caption still reads `Reconciled from 1 Nov 2026` — pass — [screenshot](002-app-tests-and-simulator-verification/06-custom-date-caption-unchanged-before-refresh.png); after a refresh it reads `Reconciled from 10 Nov 2026` — pass — [screenshot](002-app-tests-and-simulator-verification/07-custom-date-caption-after-refresh.png)
     - 001c-4 a failed refresh leaves the empty-state caption `Reconciling from 1 Nov 2026` — pass — [screenshot](002-app-tests-and-simulator-verification/08-refresh-fails-empty-state-no-message.png); the results-on-screen case is covered by app test 8.
  - Also seen: the Settings Accounts footer shows only the original single line, and no "Use 1st of this month" button while the date is automatic — [screenshot](002-app-tests-and-simulator-verification/04-settings-automatic-date.png).

## Open questions
- Criterion 3 says a failed refresh "shows the failure message", but `ReconcileView` only renders `statusMessage` inside the results branch, so in the empty state (the only place this can be reached with `-FixtureRefreshFails`) the user sees nothing. The same is true of the live app: tapping refresh with no tokens, or a real failure before any results exist, shows no message on the Reconcile tab. Should `statusMessage` also be shown in the empty state? That is a one-line change in `ReconcileView.swift`, which this plan doesn't list, so I did not make it.
- The Release configuration is already broken at `HEAD` (previews use DEBUG-only helpers outside `#if DEBUG`). Worth its own plan.

## Suggestions
- Wrap the `#Preview` blocks that use the fixture helpers in `#if DEBUG` to restore a working Release build.
