# 003 — Show refresh errors in the empty state; fix the Release build

Follow-up to the open questions in
[002's response](002-app-tests-and-simulator-verification.response.md).

## Goal

1. When a refresh fails before any results exist, the Reconcile tab says so.
2. The Release configuration builds again, and stays building.

## Why

1. `ReconcileView` renders `statusMessage` only when a reconciliation exists.
   If the first refresh of a session fails (no tokens, wrong plan or account,
   network down, timeout), the Reconcile tab silently stays on "Ready to
   reconcile". The message only appears on the Settings tab
   ([screenshot](002-app-tests-and-simulator-verification/09-refresh-failed-message-only-in-settings.png)).
2. Release fails to compile: the `#Preview` blocks call fixture helpers that
   exist only in Debug (`PreviewData.swift` is inside `#if DEBUG`). Debug runs
   on the phone are unaffected, but an archive or a Release run is impossible.

## Scope

App target only. Files expected to change: `ReconcileView.swift`, every file
with a `#Preview` that uses Debug-only helpers (`ContentView.swift`,
`ReconcileView.swift`, `ReviewSheet.swift`, `RowDetailView.swift`,
`SettingsView.swift`, `SplitPickerView.swift`), and `plans/README.md`.

### 1. Status message in the empty state — `ReconcileView.swift`

- In the empty state (`model.reconciliation == nil`), when
  `model.statusMessage` is non-nil, show it directly **below** the "Ready to
  reconcile" card and above the start-date caption.
- Use the same presentation as the results branch:
  `Label(message, systemImage: "info.circle")`, secondary style, in its own
  `Section`, so the card keeps all four rounded corners.
- When results exist, keep showing it exactly where it is today.
- Don't change where or when `statusMessage` is set. The Settings tab may keep
  showing it as it does now.

### 2. Release build — `#Preview` blocks

- Wrap each `#Preview` that uses a Debug-only helper (`fixturePreview()`,
  `dryRunFixturePreview()`, `settledDifferentlyPreview()`, `SendReview`
  fixtures, and so on) in `#if DEBUG … #endif`. Wrapping all previews is fine
  and simplest.
- No preview may change what it shows.

### 3. Keep Release building — `plans/README.md`

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

- `ReconcileViewModel.swift` and the rules from plans 001–002.
- Anything under `TransactionKit/`, `scripts/`, `Fixtures/`.
- Debug-only fixture code stays Debug-only.

## Acceptance criteria

1. Launch with `-FixtureData -FixtureRefreshFails` and pull to refresh: the
   Reconcile tab shows "Refresh failed. Try again in a moment." below the
   "Ready to reconcile" card, which keeps four rounded corners, with the
   start-date caption below the message.
2. Launch with `-FixtureData` (no failure) and pull to refresh: results appear
   as before, with no stray message.
3. Normal launch with no tokens, pull to refresh: the Reconcile tab shows "Add
   both API tokens in Settings before refreshing."
4. The Release configuration builds for an iPhone simulator with no errors.
5. Every Xcode preview still renders in Debug.
6. `plans/README.md` has the Release-build bullet and template line, and
   nothing else changed.

## Tests

Follow `plans/README.md` rule 6, including the new Release-build step.
Screenshots for criteria 1–3 go in `plans/003-empty-state-errors-and-release-build/`.
No app tests are needed: no view-model logic changes.
