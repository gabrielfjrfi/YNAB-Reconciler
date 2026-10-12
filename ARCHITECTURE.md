# iOS architecture

The target shape for the app. Read this before writing code — it exists mainly
to stop the wrong parts of the reference implementation being ported.

## What this app is

An iPhone app that fetches transactions from Up Bank and YNAB, reconciles them,
shows what is missing, and enters the missing ones into YNAB. YNAB is
maintained **entirely by hand** — no direct import, no file import, payee names
typed from scratch and often shortened. The reconciler never assumes the two
sides agree on anything except the amount.

## What NOT to port

The reference implementation (`ynab_gap.py`) is a command-line tool that
generates an HTML page and serves it over localhost so a browser can push. On
iOS, almost all of that machinery disappears:

| Reference | iOS |
|---|---|
| `.env` file | Keychain |
| Local HTTP server | gone — the app calls YNAB directly |
| One-time push secret, `127.0.0.1` binding | gone — no browser, no cross-origin risk |
| Generated HTML, CSS, embedded JavaScript | SwiftUI |
| Category combobox in JS | native searchable picker |
| Payee `<datalist>` | native text field with suggestions |
| Confirmation modal | `.sheet` or `.confirmationDialog` |
| `.ynab_pushed.json` | SwiftData, or a JSON file in Application Support |
| `localStorage` for picks | in-memory, persisted with the rest of app state |
| argparse flags | Settings screen |

**Treat `ynab_gap.py` as reference only.** Use it to disambiguate the spec, not
as a porting target. If you find yourself writing an HTTP server or generating
HTML, stop.

One invariant from the reference **is** worth keeping, restated for this
context: the view layer never decides what a transaction is worth. Amounts and
dates come from the reconciler's own model, derived from Up. The UI chooses a
category, edits a payee, and re-pairs a shortlist — nothing else.

## Layers

```
TransactionKit        pure Swift, no UIKit, no networking, no I/O
  Money               integer cents
  UpTransaction, YnabTransaction, Reconciliation
  Reconciler          the six passes from SPEC.md
  SplitScorer         bands, evidence classes, ties

Networking            URLSession, behind protocols so tests can fake it
  UpClient            pagination, de-dup by id
  YnabClient          transactions, categories, payees, create
  Credentials         Keychain

App                   SwiftUI
  ReconcileView       the four action groups
  SplitPickerView     the ranked shortlist
  ReviewSheet         confirm before sending
  SettingsView        tokens, plan and account ids, parameters
```

`TransactionKit` is the part that must be right, and the only part with golden
tests. Keep it free of everything else so those tests stay fast and total.

## Data flow

1. Settings hold tokens in Keychain and ids in `UserDefaults` (ids are not
   secret).
2. A refresh fetches Up (paginated) and YNAB concurrently, plus categories and
   payees, and caches the last successful responses to disk.
3. `Reconciler` turns the two arrays into a `Reconciliation` value — pure, and
   fast enough to re-run whenever the user changes a shortlist pick.
4. The UI renders the four action groups from that value.
5. Selected rows become a create request; on success their Up ids go into the
   pushed log and the rows lock.

Re-running the reconciler on every pick change is simpler than mutating the
result in place, and cheap at this scale.

## The picker on a phone

The shared-cost shortlist is the most intricate part of the UI and it is wanted
on the phone, not deferred to desktop. Suggested shape:

- The row shows the pre-selected purchase, your share, and the repayment it was
  paired with. A block with nothing pre-selected shows the repayment itself and
  is visibly flagged.
- Tapping opens a sheet listing every candidate, best first, each showing its
  score, the resulting share, and its reason strings in plain words. Ties are
  labelled joint best and nothing is pre-selected.
- A "not a split" option puts the bill and the repayment back as separate rows.
- Changing a pick re-runs the reconciler and the totals update.

Reason strings from the scorer (`exactly half`, `same category`, `leaves a
round 37.00`) are already human-readable. Show them; the point of the score is
that it can be argued with.

## Sending

Tick rows to include them, then review before sending. The review sheet shows
date, payee, category and amount per row, plus **the total the YNAB balance
will move by** and **what is still outstanding afterwards** — both of which
must stay visible while the list scrolls.

A row cannot be sent without a category: a category has to resolve to a real
id, so typing alone is not a choice. A payee, by contrast, is free text — the
suggestion list is a convenience, not a constraint.

### Duplicate protection

Since `import_id` is omitted (see API.md), the pushed log is the only thing
preventing duplicates. It maps Up transaction id to a timestamp.

**A share logs two ids** — the purchase and the repayment — or the repayment
could be sent again on its own afterwards.

Provide a way to clear it, with a warning that re-sending duplicates in YNAB.
The self-correcting property is worth surfacing: anything already pushed will
match on the next refresh and drop off the list by itself.

## Security and privacy

Both tokens live in the Keychain, with an accessibility of
`kSecAttrAccessibleWhenUnlockedThisDeviceOnly` — these are bank and budget
credentials and should not migrate to a new device via backup.

Never log a token, never put one in an error message, never write one to the
cached responses on disk. Consider protecting the app itself behind
`LocalAuthentication`.

Cached API responses contain the user's full transaction history. Store them in
Application Support with file protection, not in Documents, and exclude them
from iCloud backup unless the user opts in.

## Testing

`TransactionKit` is tested against `Fixtures/` and the expected output, as
described in SPEC.md §11. Those tests are the contract: if the port disagrees
with the fixtures, the port is wrong.

Networking is tested against the same fixture JSON through a faked protocol —
decoding, pagination across a synthetic `links.next`, and de-duplication.

The UI needs no golden tests, but the balance identity should be asserted in
the view model after every reconcile, because it catches a whole class of
mistake for one line of code.

## Deliberately out of scope for v1

Multiple accounts on either side, amount corrections pushed via `PATCH`,
deleting YNAB rows, widgets, notifications, and delta sync via
`last_knowledge_of_server`. Corrections and deletions touch rows the user
entered by hand and are safer left to the YNAB app.
