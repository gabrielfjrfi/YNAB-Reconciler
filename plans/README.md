# Plans — how changes are made in this repo

Changes are planned in one place and implemented in another. Every plan and
every implementation report lives in this folder, so the history of *why* the
code looks the way it does stays next to the code.

## The loop

1. **Plan.** A plan is written as `plans/NNN-short-name.md` (three-digit
   number, kebab-case name). It states the goal, the exact scope, what must not
   change, acceptance criteria and tests.
2. **Implement.** The coding agent is asked to implement one plan.
3. **Report.** The coding agent writes `plans/NNN-short-name.response.md` and
   posts the same text in its chat.
4. **Review.** The response and the code changes are checked against the plan.
   Follow-ups become a new plan (`NNN-short-name` with the next number, or a
   lettered revision such as `001b-...`).

## Rules for the coding agent

Follow these whenever you implement a plan.

1. **Read first.** Read the plan in full, then `ARCHITECTURE.md`, and
   `SPEC.md` if the plan touches reconciliation behaviour.
2. **Do only what the plan says.** No drive-by refactors, renames, formatting
   sweeps or extra features. If you notice something worth changing, list it
   under *Suggestions* in your response instead.
3. **Ambiguity stops you.** If the plan is unclear, contradicts the code, or
   would break something, do not guess. Implement what is unambiguous, stop,
   and explain the problem under *Open questions*.
4. **The engine is protected.** Do not modify anything under `TransactionKit/`
   (including its tests and fixtures) unless the plan explicitly says so.
   Never edit `Fixtures/` or any `*expected.json` to make a test pass.
5. **Plans are read-only.** Never edit a plan file. Write only the response
   file for the plan you implemented.
6. **Verify before reporting.** All of these are required.
   - **Build** the `YNAB Reconciler` scheme for an iPhone simulator. Read the
     build log and list every warning in files you changed, or "none".
   - **Engine tests:** `swift test --package-path TransactionKit`. All pass.
   - **App tests:** run the `YNAB ReconcilerTests` target. All pass. If the
     plan changes app logic (view models, formatting, rules), add or update
     tests there.
   - **Simulator checks:** on a named iPhone simulator (the newest
     installed; name it in the response), launch the app, carry out **every**
     acceptance criterion, and take a screenshot as evidence for each. Use
     the `-FixtureData` launch argument for anything that needs results on
     screen, and add `-FixtureRefreshFails` to check failure paths. Save the
     screenshots as `plans/NNN-short-name/NN-what-it-shows.png` and link
     them in the response.
   - A check may be skipped only if it is impossible (say exactly why), and
     then the status is **Blocked**, not "Partially done". "I didn't run it"
     is not a reason.
7. **Never commit or push.** Leave changes in the working tree. Syncing with
   GitHub is done separately so the local repo and GitHub stay identical.
8. **No secrets.** Never write tokens, IDs from `.env`, or real transaction
   data into code, plans, responses or logs.

## Response file format

Write `plans/NNN-short-name.response.md` with exactly these sections, then
paste the same content into the chat:

```markdown
# Response to NNN-short-name

## Status
Done | Partially done | Blocked — one line on why.

## Changes
- `path/to/File.swift` — what changed and why (one line per file).

## Deviations from the plan
Anything done differently from the plan, and why. "None" if none.

## Verification
- Build: succeeded / failed on <simulator>. Warnings in changed files: none / list.
- Engine tests: N passed, N failed (name any failures).
- App tests: N passed, N failed (name any failures; list tests added).
- Simulator checks (<simulator name>):
  1. <criterion> — pass / fail — [screenshot](NNN-short-name/01-....png)
  2. ...

## Open questions
Anything that needs a decision before this can be called done. "None" if none.

## Suggestions
Optional: things noticed but deliberately not changed.
```
