# Reconciliation specification

How an Up Bank account is reconciled against a hand-maintained YNAB account.
Language-agnostic: implement from this document, not by transliterating the
Python reference.

Two fixture pairs and their expected output accompany this spec. **A correct
implementation reproduces `expected.json` and `edge_expected.json` exactly.**

---

## 1. Money and dates

**Money is integer cents everywhere. Never use a floating-point type.**

- Up reports cents directly in `amount.valueInBaseUnits`.
- YNAB reports *milliunits*: divide by 10 for cents. All YNAB amounts should
  divide evenly; if one does not, round to nearest and log a warning rather
  than silently truncating.
- Negative is money out, on both sides. The conventions already agree.

**Dates are Up's local calendar day.** `createdAt` carries an explicit UTC
offset (`2026-09-14T21:30:00+10:00`). Take the calendar date *in that offset*,
not after converting to UTC — otherwise a late-evening purchase lands on the
following day and stops matching.

YNAB's `date` is already a plain calendar date.

Up's `settledAt` is never used for matching.

---

## 2. Inputs and filtering

**Up:** every transaction in the response, including `status: "HELD"`
(pending). Held transactions are real and participate in every pass.

**YNAB:** every transaction except `deleted: true`. Split parents match on
their own total; their subtransactions are ignored, because the bank only ever
saw the parent. A transaction with a `transfer_account_id` is kept — a transfer
out of the Up account is still a real Up transaction.

**Partners** is a list of Up display names belonging to people who repay you
for shared costs (for example `$partner_handle`). An inflow counts as a
possible repayment only if its description contains one of these, case
insensitively. If the list is empty, every inflow qualifies — which is
permissive and degrades accuracy; warn the user.

---

## 3. Passes, in order

Each pass consumes transactions from the pool and hands the remainder on.
**The order is load-bearing.** Running the passes in a different order produces
different, wrong answers — see §8.

| # | Pass | Consumes |
|---|------|----------|
| 1 | Direct match | one Up + one YNAB |
| 2 | Merchant reversals | two Up |
| 3 | Shared costs already in YNAB | two Up + one YNAB |
| 4 | Shared cost shortlists | claims two Up (reversible by the user) |
| 5 | Full repayments | two Up |
| 6 | Amount corrections | one Up + one YNAB |

Everything left over is a genuine gap.

### Pass 1 — Direct match

Pair an Up transaction with a YNAB transaction where:

- the **signed amounts are identical**, to the cent, and
- `|up.date − ynab.date| ≤ tolerance` days (default 7).

Payee and description text is **never** used for matching, in this or any
other pass. It appears in output only.

Matching is **one-to-one**. A set difference is wrong here: identical amounts
recur, so each transaction may be consumed by at most one partner.

Generate every candidate pair satisfying the two conditions, then claim them
greedily in order of:

1. ascending date gap (same-day pairs first)
2. ascending Up date
3. ascending Up id

Skip a candidate if either side is already claimed. The last two keys exist
only to make runs reproducible.

### Pass 2 — Merchant reversals

An Up purchase cancelled by an equal and opposite Up credit **from the same
merchant** — a refund. Nets to zero, so there is nothing to enter in YNAB.

Conditions:

- `credit.cents == −purchase.cents`
- `|credit.date − purchase.date| ≤ reimbursementWindow` days (default 14)
- descriptions are equal, case insensitively
- if both sides have a category, the category **and** parent category must match

Claim greedily by ascending date gap, then purchase id, then credit id.
One-to-one.

### Pass 3 — Shared costs already in YNAB

You paid a whole bill, someone repaid their share, and YNAB holds only your net
share. Up shows two transactions where YNAB shows one, so no single amount
matches.

For each **unmatched YNAB outflow** `y`, find an Up purchase `p` and an Up
inflow `d` where:

- `p.cents < y.cents` (both negative, so the bill exceeds your share)
- `|p.date − y.date| ≤ tolerance`
- `p.cents + d.cents == y.cents` **exactly**
- `|d.date − p.date| ≤ reimbursementWindow`

Rank candidate triples by:

1. ascending `|p.date − y.date|`
2. ascending `|d.cents − |p.cents| / 2|` — nearer an even split first
3. YNAB id, purchase id, deposit id

Claim greedily, one-to-one across all three transactions.

### Pass 4 — Shared cost shortlists

The same shape, but nothing was ever entered in YNAB. Both Up transactions are
unmatched, so passes 1–3 all miss it. Left alone, the report would ask the user
to enter the full bill *and* the repayment as two rows — two entries they would
never make. What they want is one entry for their share.

This pass does **not** consume anything outright. It produces, for each
qualifying repayment, a **ranked shortlist** of purchases it might belong to,
with at most one pre-selected. The user can re-pair or reject any of them, so
the result must remain revisable. See §4 for scoring and §5 for pre-selection.

Candidate repayments are Up inflows that:

- match the partner list (§2), **and**
- do **not** have `transactionType == "Refund"`

Candidate purchases are Up outflows where:

- `−2 ≤ (deposit.date − purchase.date) ≤ settleWindow` days (default 30) — a
  repayment follows the purchase, allowing a couple of days for someone who
  pays up front
- the descriptions differ, case insensitively — identical descriptions on both
  sides mean a reversal, not a split
- `purchase.cents + deposit.cents < 0` — your share must be positive
- the pair scores at or above `scoreFloor` (default 25)

Keep the top `shortlistSize` (default 5) candidates per repayment.

### Pass 5 — Full repayments

As pass 2, but the credit comes from someone else rather than the merchant.
Identical conditions **except** that descriptions need not match; categories
still must, where both are set.

This runs *after* pass 4 because a repayment that is exactly half of one bill
can also be equal and opposite to another — see §8.

### Pass 6 — Amount corrections

A YNAB row and an Up transaction of nearly the same amount: a mistyped figure.

- same direction (both outflows, or both inflows)
- `0 < |up.cents − ynab.cents| ≤ amendTolerance` cents (default 100)
- `|up.date − ynab.date| ≤ amendDays` days (default 3)

Rank by ascending `|delta|`, then ascending date gap, then YNAB id, then Up id.
A 4c difference two days apart is a likelier typo than a 90c difference on the
same day. Claim greedily, one-to-one.

---

## 4. Scoring a shared-cost candidate

Let `total = |purchase.cents|`, `theirs = deposit.cents`,
`yours = total − theirs`. Reject outright if `yours ≤ 0`.

Let `offset = deposit.date − purchase.date` in days, and
`nearness = max(0, 1 − max(offset, 0) / settleWindow)`.

Two transactions have the **same category** when both have a non-empty category
id, the ids are equal, and the parent category ids are equal. Two uncategorised
transactions agreeing counts for nothing.

### Band A — exactly half

If `|total − 2 × theirs| ≤ 1` cent:

```
score = 90 + round(4 × nearness)
if same category: score += 6
score = min(score, 100)
```

Reasons: `"exactly half"`, plus `"same category"` when it applied.

Halving a bill is the one pattern distinctive enough to stand alone, so it
occupies its own band and **nothing else can reach it**.

### Band B — everything else, capped at 85

Start at 0 and accumulate:

| condition | points | reason string |
|---|---|---|
| same category | +40 | `same category` |
| same category id but different parent | +26 | `same category, different parent` |
| `\|total − 3 × theirs\| ≤ 1` | +22 | `exactly a third` |
| `\|total − 4 × theirs\| ≤ 1` | +12 | `exactly a quarter` |
| `\|2 × total − 3 × theirs\| ≤ 1` | +12 | `exactly two thirds` |
| `yours % 100 == 0` | +10 | `leaves a round N.NN` |
| `theirs % 100 == 0` | +5 | `round repayment` |
| — | `+ round(8 × nearness)` | — |
| `theirs / total > 0.8` or `< 0.1` | −12 | `lopsided share` |

The first two rows are mutually exclusive. The three fraction rows are checked
in the order third → quarter → two-thirds and **only the first match applies**.

Final score is clamped to `0 … 85`.

Reason strings are asserted in the expected output, so match them exactly. The
round-share reason formats the amount with two decimals and a thousands
separator, e.g. `leaves a round 1,234.50`.

---

## 5. Pre-selection and ties

Scores rank a shortlist; they do **not** decide whether to pre-select. Bands of
evidence do, because points are the wrong instrument: an uncategorised bill
split exactly in half scores 93, below three same-category near-misses at 95+,
yet it is the one you can trust.

Assign each candidate an **evidence band**:

| band | condition |
|---|---|
| 0 | exactly half **and** same category |
| 1 | exactly half |
| 2 | same category **and** any `exactly …` fraction |
| 3 | same category **and** a round remaining share |
| none | anything else — never pre-selected |

For each repayment, let `best` be the lowest band present among its candidates,
and `contenders` be every candidate in that band.

- Exactly one contender → it is **eligible** for pre-selection.
- More than one → all contenders are flagged `joint_best`, the block is marked
  `tied`, and **nothing is pre-selected**. Their order among themselves carries
  no meaning.
- No candidate has a band → nothing is pre-selected.

Then assign claims **globally across all repayments**, so two of them can never
pre-select the same purchase. Order eligible blocks by ascending band, then
descending score, then deposit id; claim each one's purchase if still free,
otherwise leave that block unassigned.

The shortlist itself is always sorted by descending score, then ascending
purchase date, then purchase id.

---

## 6. Output

Four actionable groups, all resolved in YNAB:

| group | contents | balance effect per row |
|---|---|---|
| **Enter in YNAB** | unmatched Up transactions not represented by a shortlist | its own amount |
| **Enter your half** | one row per shortlist; if a purchase is selected, your share | `purchase + deposit`, or the deposit's own amount when unassigned |
| **Correct the amount** | pass 6 pairs | `up.cents − ynab.cents` |
| **Check these yourself** | unmatched YNAB rows | `−ynab.cents`, assuming deletion |

A repayment with a shortlist is represented **only** by its shortlist row, never
also in "Enter in YNAB", or the same transaction appears twice.

Reconciled groups (matched, reversals, shared costs already entered, full
repayments) are shown as an audit trail with no action.

## 7. The balance identity

```
upTotal   = sum of every Up transaction in the period
ynabTotal = sum of every YNAB transaction in the period
gap       = upTotal − ynabTotal
```

**The balance effects of all four action groups sum to exactly `gap`.** Assert
this after reconciling; a mismatch means a transaction was consumed twice or
lost. `expected.json` records it as `identity_holds`.

Because grouping is delta-neutral — one row of −30.59 moves the balance exactly
as far as −61.18 and +30.59 separately — the user re-pairing a shortlist can
never change the totals, only the wording of an instruction. Preserve this
property: it is what makes the picker safe.

**Know what this check cannot catch.** A wrongly matched pair that nets to zero
(passes 2 and 5) removes both transactions and the arithmetic still balances.
The identity catches double-counting, never wrongful cancellation.

---

## 8. Ordering traps

Two real bugs, both fixed by the ordering in §3. A port that reorders the passes
will reintroduce them, and both fixtures cover them.

**Reversals before shortlists.** An $11.17 grocery repayment once cancelled an
unrelated $11.17 cafe bill purely on equal-and-opposite amounts, swallowing
both. The cafe bill was then unavailable to the $5.58 repayment that genuinely
belonged to it. Requiring the categories to agree fixes it — and because the
pair nets to zero, the balance identity stayed green throughout and gave no
hint anything was wrong.

**Shortlists before full repayments.** A $103.99 refund sat beside a $149.99
charge at the same merchant. With pass 5 running first — or with refunds
allowed into pass 4 — the refund claimed the larger charge on the strength of a
round $46.00 remainder, and the true cancellation never happened. Excluding
`Refund` transaction types and same-merchant pairs from pass 4, and running
pass 5 after it, fixes it.

---

## 9. Defaults learned from history

Two conveniences mined from already-reconciled pairs (pass 1 and pass 3
results). Both are suggestions and must remain editable.

**Payee renames.** Where a YNAB payee name differs from the Up description,
record the mapping; the most frequent target wins. These are reliable —
`Merchant 12` consistently becomes `Payee 07`.

**Category defaults.** Map an Up description to a YNAB category id, but only
where that description has appeared under **exactly one** category. Ambiguous
merchants get no default.

**Do not use Up's own category to predict a YNAB category.** It is a poor
predictor: `restaurants-and-cafes` alone lands in four different YNAB
categories in the fixture.

---

## 10. Parameters

| name | default | used by |
|---|---|---|
| `tolerance` | 7 days | passes 1, 3 |
| `reimbursementWindow` | 14 days | passes 2, 3, 5 |
| `settleWindow` | 30 days | pass 4 |
| `amendTolerance` | 100 cents | pass 6 |
| `amendDays` | 3 days | pass 6 |
| `scoreFloor` | 25 | pass 4 |
| `shortlistSize` | 5 | pass 4 |
| `partners` | — | passes 4 |
| `heldStatus` | `cleared` | output only |

---

## 11. Verifying a port

Load each fixture pair, reconcile with the parameters in the expected file's
`parameters` block, and assert the result matches **exactly**: every
classification, every pairing by id, every score, every reason string, every
candidate's position in its shortlist, and every total.

`Fixtures/up.json` + `ynab.json` — 182 Up and 79 YNAB transactions of real
shape, anonymised. Covers direct matching at scale, one-to-one claiming with
duplicate amounts, reversals, shared costs both entered and not, odd-cent
splits, and pre-selection across all four bands.

`Fixtures/edge_up.json` + `edge_ynab.json` — 21 Up and 7 YNAB synthetic
transactions covering what the real data never reaches: an amount correction, an
unexplained YNAB row, a tied shortlist with nothing pre-selected, a repayment
nothing fits, a merchant refund competing against a larger same-merchant charge,
a pending transaction, and a cost fully repaid.

Between them every branch in §3 to §5 is exercised.
