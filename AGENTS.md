# YNAB Reconciler — instructions for coding agents (AGENTS.md)

An iPhone app (SwiftUI) that reconciles Up Bank transactions against a
hand-maintained YNAB account. The reconciliation engine is the Swift package in
`TransactionKit/`; `SPEC.md` is its contract and `ARCHITECTURE.md` describes
the app's shape.

**All work is driven by plans.** Before changing anything, read
[`plans/README.md`](plans/README.md) and follow its rules: implement only the
plan you were given, never modify `TransactionKit/` unless the plan says so,
verify with the build and tests, never commit or push, and write your report to
`plans/NNN-name.response.md` as well as in the chat.
