# 003 — Start date in the "Ready" card, caption only after success; fix Release

Replaces the earlier draft of this plan (which also showed `statusMessage` in
the empty state; that part was dropped).

## Goal

1. **Empty state.** The "Ready to reconcile" card shows the start date itself,
   and the bottom caption is hidden.
2. **Bottom caption.** It appears only after a **successful** refresh, as
   `Reconciled from <date>`, and disappears again when a later refresh fails.
3. **Release build** compiles again, and stays compiling.

## Why

- In the empty state, the separate "Reconciling from …" line repeats what the
  card should say, and floats far below it.
- The caption should describe results the user can trust. After a failed
  refresh, the results on screen may be out of date, so the caption goes.
- Release fails to compile: the `#Preview` blocks call fixture helpers that
  exist only in Debug (`PreviewData.swift` is inside `#if DEBUG`). Debug runs
  on the phone are unaffected, but an archive or a Release run is impossible.

## Scope

App target only. Files expected to change: `ReconcileView.swift`,
`ReconcileViewModel.swift`, `PreviewData.swift`,
`YNAB ReconcilerTests/YNAB_ReconcilerTests.swift`, every file with a
`#Preview` that uses Debug-only helpers (`ContentView.swift`,
`ReconcileView.swift`, `ReviewSheet.swift`, `RowDetailView.swift`,
`SettingsView.swift`, `SplitPickerView.swift`), and `plans/README.md`.

### 1. "Ready to reconcile" card — `ReconcileView.swift`, `ReconcileViewModel.swift`

The card's text becomes three lines:

```
Ready to reconcile
from 1 Nov 2026
Add credentials in Settings, then pull down to refresh.
```

- **"Ready to reconcile"**: unchanged (font, weight, colour).
- **"from 1 Nov 2026"** (new):
  - same **font size** as the "Add credentials…" line;
  - same **colour** as "Ready to reconcile" (not secondary);
  - the date is `settings.startDate` with the existing format
    (`.dateTime.day().month(.abbreviated).year()`), and follows changes made
    in Settings straight away.
  - Expose it from the view model as
    `var readyCardDateLine: String` (`"from <date>"`) so it can be tested.
- **"Add credentials in Settings, then pull down to refresh."**: unchanged
  text and style, with a small extra gap above it (about 8 pt more than
  now) so the three lines don't look cramped. "Ready to reconcile" and the
  date line stay tight together.
- The card keeps all four rounded corners.

### 2. Bottom caption — `ReconcileViewModel.swift`, `ReconcileView.swift`

- `startDateCaption` becomes `String?`:
  - `"Reconciled from <reconciledStartDate>"` when results are on screen
    **and** the most recent refresh succeeded (`reconciledStartDate != nil`);
  - `nil` otherwise, including the whole empty state.
- The view shows the caption section only when `startDateCaption` is non-nil.
  Its look and position stay as they are (own section, last in the list).
- The text "Reconciling from …" is no longer used anywhere.
- **Success** (fetched results installed, or `installFixture(...)`): set
  `reconciledStartDate` to the start date that refresh used, as now.
- **Failure**: any refresh attempt that ends **without** installing new
  results, other than a cancellation, sets `reconciledStartDate = nil`. That
  covers:
  - the early returns in `refresh()` (missing tokens, missing plan or account
    IDs);
  - every `catch` that sets a failure `statusMessage` (timeouts, invalid
    token, wrong plan or account, rate limit, pagination loop, other errors);
  - the fixture launch mode's failing refresh (`-FixtureRefreshFails`).
  Put this in one small helper (e.g. `markRefreshFailed(_ message: String)`
  that sets both `statusMessage` and `reconciledStartDate = nil`) and use it
  everywhere, including the fixture closure in `PreviewData.swift`.
- **Cancellation** (`CancellationError`, the Cancel button) changes nothing.
- Results already on screen **stay** after a failed refresh. Only the caption
  goes. The next successful refresh brings it back with its own date.
- Re-running the engine on existing data (`reconcile()`, split picks, Save in
  Settings) doesn't change `reconciledStartDate`.

### 3. App tests — `YNAB ReconcilerTests/YNAB_ReconcilerTests.swift`

Update the tests that relied on the old wording, and add new ones:

- **5 (rewrite):** empty state, `startDateCaption == nil`, and
  `readyCardDateLine == "from <1st of month>"`.
- **New:** changing `settings.startDate` in the empty state updates
  `readyCardDateLine` to the new date.
- **6, 7:** unchanged (`Reconciled from <date>` after install, and it keeps
  the old date when Settings changes).
- **8 (rewrite):** a failed refresh (no tokens):
  - empty state: caption stays `nil`, `statusMessage` set;
  - with results installed: the results remain (`reconciliation != nil`), but
    `reconciledStartDate == nil` and `startDateCaption == nil`.
- **New:** after a failed refresh with results on screen, installing results
  again (`installEdgeFixtures()`) brings the caption back as
  `Reconciled from <date>`.

### 4. Release build — `#Preview` blocks

- Wrap each `#Preview` that uses a Debug-only helper (`fixturePreview()`,
  `dryRunFixturePreview()`, `settledDifferentlyPreview()`, `SendReview`
  fixtures, and so on) in `#if DEBUG … #endif`. Wrapping all previews is fine
  and simplest.
- No preview may change what it shows, apart from the new card and caption
  behaviour above.

### 5. Keep Release building — `plans/README.md`

In rule 6, after the **Build** bullet, add:

> - **Release build:** also build the `YNAB Reconciler` scheme with the
>   Release configuration for an iPhone simulator. It must succeed.

Add a matching line to the response template's *Verification* section, right
after the Build line:

```markdown
- Release build: succeeded / failed.
```

Change nothing else in the README.

## Must not change

- The start-date rules from 001 (1st of the month on launch, session-only
  custom date, "Use 1st of this month").
- Where `statusMessage` is displayed today.
- Anything under `TransactionKit/`, `scripts/`, `Fixtures/`.
- Debug-only fixture code stays Debug-only.

## Acceptance criteria

1. `-FixtureData` launch, before any refresh: the card reads "Ready to
   reconcile / from 1 \<Mon\> \<Year\> / Add credentials…", with the date line
   in the title's colour at the body text size, a visible gap before "Add
   credentials…", all four corners rounded, and **no** caption below the card.
2. Change the date in Settings and return (still empty): the card's date line
   shows the new date.
3. Pull to refresh (`-FixtureData`): results appear, with
   `Reconciled from <date>` as the last line above the tab bar.
4. `-FixtureData -FixtureRefreshFails`, pull to refresh: the card stays, with
   no caption. (Failure with results on screen is covered by app tests.)
5. The Release configuration builds for an iPhone simulator with no errors.
6. All app tests pass (updated and new ones), and every Xcode preview still
   renders in Debug.
7. `plans/README.md` has the Release-build bullet and template line, and
   nothing else changed.

## Tests

Follow `plans/README.md` rule 6, including the new Release-build step.
Screenshots for criteria 1–4 go in
`plans/003-ready-card-date-and-release-build/`.
