#!/usr/bin/env bash
# Runs the real reconciliation engine on your live Up and YNAB data and writes
# a plain-text report to reports/<timestamp>/report.txt (git ignores reports/).
#
#   scripts/report.sh                      # live, since the 1st of this month
#   scripts/report.sh --since 2026-10-01   # live, from another start date
#   scripts/report.sh --up-json reports/<ts>/up.json --ynab-json reports/<ts>/ynab.json
#                                          # offline replay of an earlier run
#
# Tokens are read from the macOS login keychain, never from a file. Store them
# once with (each command prompts for the token, so it never lands in your
# shell history):
#   security add-generic-password -U -s ynab-reconciler -a up-token -w
#   security add-generic-password -U -s ynab-reconciler -a ynab-token -w
#
# Non-secret settings come from .env in the repo root:
#   YNAB_PLAN_ID=...  YNAB_ACCOUNT_ID=...  UP_ACCOUNT_ID=... (optional)
#   SPLIT_PARTNERS=$handle1,$handle2
# Any UP_TOKEN or YNAB_TOKEN line left in .env is ignored.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ -f .env ]]; then
  # Parsed rather than sourced, so a `$handle` in SPLIT_PARTNERS stays literal.
  while IFS='=' read -r key value; do
    value="${value%$'\r'}"; value="${value%\"}"; value="${value#\"}"
    case "$key" in
      YNAB_PLAN_ID|YNAB_ACCOUNT_ID|UP_ACCOUNT_ID|SPLIT_PARTNERS|SINCE) export "$key=$value" ;;
    esac
  done < <(grep -E '^[A-Z_]+=' .env || true)
fi

keychain() {
  if ! security find-generic-password -s ynab-reconciler -a "$1" -w 2>/dev/null; then
    echo "No '$1' in your keychain. Add it with:" >&2
    echo "  security add-generic-password -U -s ynab-reconciler -a $1 -w" >&2
    return 1
  fi
}

if [[ " $* " != *" --up-json "* ]]; then
  UP_TOKEN="$(keychain up-token)"
  YNAB_TOKEN="$(keychain ynab-token)"
  export UP_TOKEN YNAB_TOKEN
fi

swift run --package-path TransactionKit -c release reconcile-report --out reports "$@"
