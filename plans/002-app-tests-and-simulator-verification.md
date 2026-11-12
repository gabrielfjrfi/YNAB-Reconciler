# 002 — App test target, fixture launch mode, mandatory simulator checks

## Goal

Make every future plan verifiable by the coding agent itself:

1. **Fixture launch mode.** In Debug builds, the app can start on the bundled
   sample data instead of live Up and YNAB, so the simulator can show
   reconciled results without tokens or network.
2. **App test target.** A `YNAB ReconcilerTests` target with view-model tests
   for the start-date and caption rules from plans 001–001c.
3. **Stricter verification rules** in `plans/README.md`: simulator checks are
   mandatory, with screenshots saved in the repo, and build warnings are read
   from the log.

## Why

Plans 001–001c all ended "manual checks not run". Two reasons:

- In the simulator the app can only show the empty state: it has no tokens,
  and the sample data exists only inside Xcode Previews
  (`ReconcileViewModel.fixturePreview()` in `PreviewData.swift`). Any check
  that needs results on screen is impossible.
- The only automated tests cover the engine (`TransactionKit`). App logic, such
  as which date the caption shows after a failed refresh, could only be checked
  by reading the code.

## Scope

### 1. Fixture launch mode — `PreviewData.swift`, `ContentView.swift`

Everything in this section is inside `#if DEBUG`. Release builds behave exactly
as today.

- Launch arguments, read once from `ProcessInfo.processInfo.arguments` in
  `ContentView.init()`:
  - `-FixtureData`: start on a fixture-backed model instead of the live one.
  - `-FixtureRefreshFails` (with `-FixtureData`): every refresh fails.
- The fixture-backed model, e.g. `ReconcileViewModel.fixtureLaunch(refreshFails:)`
  in `PreviewData.swift`:
  - Uses its own `UserDefaults(suiteName: "FixtureLaunch")`, cleared at
    launch, `PreviewCredentialStore()` and `MemoryPushedLogStorage()`. It must
    never read or write the real `UserDefaults.standard`, the Keychain, the
    disk pushed log, or the network.
  - Starts **empty** (no reconciliation), so the "Ready to reconcile" state can
    be checked.
  - Its `fixtureRefresh` closure installs the edge fixtures (`edge_up`,
    `edge_ynab`) through `installFixture(...)`, exactly as `fixturePreview()`
    does. Share the loading code between the two instead of duplicating it.
    The closure needs a reference to the model it belongs to; use whatever is
    cleanest (e.g. a small weak box created before the model).
  - With `-FixtureRefreshFails`, the closure installs nothing and sets
    `statusMessage` to `"Refresh failed. Try again in a moment."` (the live
    failure text).
- `fixturePreview()` and the existing previews keep working unchanged.

### 2. App test target — new `YNAB ReconcilerTests`

- Add an iOS unit-test target `YNAB ReconcilerTests`, hosted by the
  `YNAB Reconciler` app, using **Swift Testing** (`import Testing`), with
  `@testable import YNAB_Reconciler`. Add it to the Test action of the
  `YNAB Reconciler` scheme.
- Tests construct `ReconcileViewModel` with a fresh
  `UserDefaults(suiteName:)` per test (removed afterwards), an in-memory
  `CredentialStore` defined in the test target, and `MemoryPushedLogStorage()`.
  They never touch the Keychain or the network.
- Compute expected caption strings with the same
  `.dateTime.day().month(.abbreviated).year()` format, so the tests don't
  depend on the simulator's locale.
- Tests to write (one `@Test` each):
  1. A new model's start date is the 1st of the current month, and
     `isStartDateCustom` is false.
  2. A value stored under the legacy key `"reconcileStartDate"` is removed at
     init and ignored.
  3. Changing `settings.startDate` makes `isStartDateCustom` true;
     `useAutomaticStartDate()` restores the 1st of the month.
  4. `saveSettings()` does not persist the start date: a second model created
     with the same defaults starts on the 1st of the month.
  5. Empty state: `startDateCaption == "Reconciling from <1st of month>"`.
  6. After `installFixture(...)` with the edge fixtures:
     `startDateCaption == "Reconciled from <date>"`.
  7. With results installed, changing `settings.startDate` leaves the caption
     on the old date.
  8. A refresh that fails (no tokens set, no `fixtureRefresh`) leaves
     `reconciledStartDate` and the caption unchanged, and sets
     `statusMessage`. Cover both the empty state and the state with results
     already installed.
  9. After installing the edge fixtures, `reconciliation?.totals.identityHolds`
     is true and `balanceWarning` is nil.
- Reuse the fixture-loading code from section 1 where possible. The test
  target is hosted by the Debug app, so `PreviewFixtures/` is available through
  `Bundle.main`.

### 3. Verification rules — `plans/README.md`

Replace rule 6 (*Verify before reporting*) and the *Verification* part of the
response template with the following. Keep everything else in the README
unchanged.

Rule 6 becomes:

> 6. **Verify before reporting.** All of these are required.
>    - **Build** the `YNAB Reconciler` scheme for an iPhone simulator. Read the
>      build log and list every warning in files you changed, or "none".
>    - **Engine tests:** `swift test --package-path TransactionKit`. All pass.
>    - **App tests:** run the `YNAB ReconcilerTests` target. All pass. If the
>      plan changes app logic (view models, formatting, rules), add or update
>      tests there.
>    - **Simulator checks:** on a named iPhone simulator (the newest
>      installed; name it in the response), launch the app, carry out **every**
>      acceptance criterion, and take a screenshot as evidence for each. Use
>      the `-FixtureData` launch argument for anything that needs results on
>      screen, and add `-FixtureRefreshFails` to check failure paths. Save the
>      screenshots as `plans/NNN-short-name/NN-what-it-shows.png` and link
>      them in the response.
>    - A check may be skipped only if it is impossible (say exactly why), and
>      then the status is **Blocked**, not "Partially done". "I didn't run it"
>      is not a reason.

The *Verification* section of the response template becomes:

```markdown
## Verification
- Build: succeeded / failed on <simulator>. Warnings in changed files: none / list.
- Engine tests: N passed, N failed (name any failures).
- App tests: N passed, N failed (name any failures; list tests added).
- Simulator checks (<simulator name>):
  1. <criterion> — pass / fail — [screenshot](NNN-short-name/01-....png)
  2. ...
```

## Must not change

- Release-build behaviour: nothing from section 1 may compile into Release.
- `TransactionKit/` (including its tests and fixtures), `scripts/`, `Fixtures/`.
- The behaviour from plans 001–001c.
- The rest of `plans/README.md`.

## Acceptance criteria

1. `YNAB ReconcilerTests` exists, runs from the `YNAB Reconciler` scheme's
   Test action, and all nine tests pass.
2. Launching with `-FixtureData` shows the empty state with
   `Reconciling from 1 <Mon> <Year>`. A pull to refresh shows the edge-fixture
   results with `Reconciled from 1 <Mon> <Year>` at the bottom.
3. Launching with `-FixtureData -FixtureRefreshFails` and pulling to refresh
   shows the failure message and stays in the empty state.
4. A normal launch (no arguments) behaves exactly as before: live data, real
   Keychain, real settings.
5. `plans/README.md` contains the new rule 6 and response template, with the
   rest unchanged.
6. As proof the new process works, redo plan **001c**'s acceptance criteria
   1–4 in the simulator with screenshots in `plans/002-app-tests-and-simulator-verification/`.
   For 001c criterion 4, use `-FixtureRefreshFails` for the empty state; the
   "results already on screen" case is covered by app test 8.

## Tests

Follow the **new** rule 6 above for this plan's own verification, including
screenshots for criteria 2, 3 and 6.
