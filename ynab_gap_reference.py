#!/usr/bin/env python3
"""
Fetch Up Bank and YNAB transactions from the same start date, reconcile them,
and write an HTML worklist of the fixes needed in YNAB.

Setup - a .env file beside this script:

    UP_TOKEN=up:yeah:xxxxxxxxxxxxxxxx
    YNAB_TOKEN=xxxxxxxxxxxxxxxxxxxxxxxx
    YNAB_PLAN_ID=04431b71-0f95-440a-9358-789bac55c034
    YNAB_ACCOUNT_ID=48632bd8-ed08-4eda-85e8-2dd841ce0607
    UP_ACCOUNT_ID=554182c7-58a0-4b41-b730-15896f9657c0   # optional
    SPLIT_PARTNERS=$gabriele_ged                         # optional, comma-separated

Usage:
    python3 ynab_gap.py                       # prompts for the start date
    python3 ynab_gap.py --since 2026-09-01    # skips the prompt
    python3 ynab_gap.py --from-files up.json ynab.json   # re-run offline

Stdlib only - no pip install required.
"""

from __future__ import annotations

import argparse
import html
import http.server
import json
import os
import secrets
import stat
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import webbrowser
from collections import Counter, defaultdict
from dataclasses import dataclass, field
from datetime import date, datetime
from zoneinfo import ZoneInfo

UP_ROOT = "https://api.up.com.au/api/v1"
YNAB_ROOT = "https://api.ynab.com/v1"
MAX_RETRIES = 5
BACKOFF_BASE = 1.5
DEFAULT_TZ = "Australia/Melbourne"


# ==========================================================================
# Config
# ==========================================================================


def load_env(path: str) -> dict[str, str]:
    """
    Parse a KEY=value file. Handles `export` prefixes, quoted values and
    comments, which is everything a token file realistically contains - not
    worth a dependency.
    """
    if not os.path.exists(path):
        raise SystemExit(
            f"No env file at {path}.\n"
            "Create one with UP_TOKEN, YNAB_TOKEN, YNAB_PLAN_ID and "
            "YNAB_ACCOUNT_ID, or point at it with --env-file."
        )

    mode = stat.S_IMODE(os.stat(path).st_mode)
    if mode & (stat.S_IRGRP | stat.S_IROTH):
        warn(f"{path} is readable by other users. chmod 600 {path}")

    values = {}
    with open(path) as fh:
        for raw in fh:
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            if line.startswith("export "):
                line = line[7:].lstrip()
            if "=" not in line:
                continue
            key, _, val = line.partition("=")
            val = val.strip()
            if len(val) >= 2 and val[0] == val[-1] and val[0] in "\"'":
                val = val[1:-1]
            else:
                val = val.split(" #")[0].rstrip()
            values[key.strip()] = val
    return values


def require(cfg: dict[str, str], key: str) -> str:
    val = cfg.get(key) or os.environ.get(key)
    if not val:
        raise SystemExit(f"{key} is missing from the env file.")
    return val


# ==========================================================================
# Dates
# ==========================================================================


def ask_since(tz_name: str) -> date:
    """Prompt for the start date, defaulting to the 1st of the current month."""
    today = datetime.now(ZoneInfo(tz_name)).date()
    default = today.replace(day=1)
    while True:
        raw = input(f"Start date [{default.isoformat()}]: ").strip()
        if not raw:
            return default
        try:
            return date.fromisoformat(raw)
        except ValueError:
            print("  Use YYYY-MM-DD.")


def up_since_timestamp(day: date, tz_name: str) -> str:
    """
    Up wants a full ISO-8601 timestamp with an offset, so derive the offset for
    that specific date rather than hardcoding one. Melbourne is +10:00 in
    winter and +11:00 over daylight saving - a hardcoded offset silently
    gains or loses an hour of transactions at the boundary.
    """
    start = datetime(day.year, day.month, day.day, tzinfo=ZoneInfo(tz_name))
    offset = start.strftime("%z")  # e.g. '+1000'
    return f"{day.isoformat()}T00:00:00{offset[:3]}:{offset[3:]}"


# ==========================================================================
# HTTP
# ==========================================================================


def warn(msg: str) -> None:
    print(f"  ! {msg}", file=sys.stderr)


def fetch_json(url: str, token: str, timeout: int = 30, allow_404: bool = False):
    """GET and parse JSON, retrying 429 and 5xx with exponential backoff."""
    req = urllib.request.Request(
        url, headers={"Authorization": f"Bearer {token}", "Accept": "application/json"}
    )

    delay = BACKOFF_BASE
    last_error = None

    for attempt in range(1, MAX_RETRIES + 1):
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                return json.loads(resp.read().decode("utf-8"))

        except urllib.error.HTTPError as err:
            body = err.read().decode("utf-8", errors="replace")[:400]
            if err.code == 404 and allow_404:
                return None
            if err.code != 429 and not 500 <= err.code < 600:
                hint = ""
                if err.code in (401, 403):
                    hint = "\nCheck the token in your env file is set and still valid."
                elif err.code == 404:
                    hint = "\nCheck the plan and account ids."
                raise SystemExit(f"HTTP {err.code}\nURL:  {url}\nBody: {body}{hint}")

            retry_after = (err.headers.get("Retry-After") or "").strip()
            wait = float(retry_after) if retry_after.isdigit() else delay
            last_error = f"HTTP {err.code}: {body}"

        except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as err:
            wait = delay
            last_error = f"{type(err).__name__}: {err}"

        if attempt == MAX_RETRIES:
            raise SystemExit(f"Gave up after {MAX_RETRIES} attempts.\nURL: {url}\nLast: {last_error}")

        print(f"  retry {attempt}/{MAX_RETRIES - 1} in {wait:.1f}s ({last_error})", file=sys.stderr)
        time.sleep(wait)
        delay *= 2


def fetch_up(token: str, since_ts: str, account: str | None, page_size: int = 100) -> list[dict]:
    """Walk links.next to the end and return every transaction."""
    params = {"page[size]": str(page_size), "filter[since]": since_ts}
    base = f"{UP_ROOT}/accounts/{account}/transactions" if account else f"{UP_ROOT}/transactions"
    url = f"{base}?{urllib.parse.urlencode(params)}"

    out: list[dict] = []
    seen: set[str] = set()
    page = 0

    while url:
        page += 1
        payload = fetch_json(url, token)
        batch = payload.get("data", [])
        # Cursor pagination shouldn't repeat itself, but a HELD transaction can
        # settle mid-run and shift position, so guard against duplicates.
        for txn in batch:
            if txn.get("id") in seen:
                continue
            seen.add(txn.get("id"))
            out.append(txn)
        print(f"  Up page {page}: +{len(batch)} (total {len(out)})", file=sys.stderr)
        url = (payload.get("links") or {}).get("next")

    return out


def fetch_ynab(token: str, plan_id: str, account_id: str, since: date) -> list[dict]:
    """
    Fetch one account's transactions. No pagination on this endpoint - it
    returns the lot in a single response.
    """
    query = urllib.parse.urlencode({"since_date": since.isoformat()})
    # YNAB renamed budget_id to plan_id; /budgets still answers on older
    # deployments, so fall back rather than failing on a 404.
    for noun in ("plans", "budgets"):
        url = f"{YNAB_ROOT}/{noun}/{plan_id}/accounts/{account_id}/transactions?{query}"
        payload = fetch_json(url, token, allow_404=(noun == "plans"))
        if payload is not None:
            txns = payload["data"]["transactions"]
            print(f"  YNAB: {len(txns)} transactions", file=sys.stderr)
            return txns
    raise SystemExit("YNAB returned 404 for both /plans and /budgets.")


def fetch_categories(token: str, plan_id: str) -> list[dict]:
    """
    Fetch the category tree for the dropdown.

    Groups and categories both carry an `internal` flag marking resources YNAB
    uses itself rather than ones you made - that is what removes "Inflow: Ready
    to Assign" and the Credit Card Payments group without matching on names.
    Hidden categories are dropped too, and deleted ones never appear outside a
    delta request.
    """
    payload = fetch_json(f"{YNAB_ROOT}/plans/{plan_id}/categories", token)
    groups = []
    for group in payload["data"]["category_groups"]:
        if group.get("internal") or group.get("hidden") or group.get("deleted"):
            continue
        cats = [
            {"id": c["id"], "name": c["name"]}
            for c in group.get("categories", [])
            if not (c.get("internal") or c.get("hidden") or c.get("deleted"))
        ]
        if cats:
            groups.append({"name": group["name"], "categories": cats})
    total = sum(len(g["categories"]) for g in groups)
    print(f"  YNAB: {total} categories in {len(groups)} groups", file=sys.stderr)
    return groups


def fetch_payees(token: str, plan_id: str) -> list[str]:
    """Fetch payee names for the type-ahead, minus transfer and deleted ones."""
    payload = fetch_json(f"{YNAB_ROOT}/plans/{plan_id}/payees", token)
    names = sorted(
        {
            p["name"]
            for p in payload["data"]["payees"]
            if not p.get("deleted") and not p.get("transfer_account_id")
        },
        key=str.casefold,
    )
    print(f"  YNAB: {len(names)} payees", file=sys.stderr)
    return names


def category_ids_by_name(groups: list[dict]) -> dict[str, str]:
    """Flatten the tree to name -> id, for turning learned names into ids."""
    return {c["name"]: c["id"] for g in groups for c in g["categories"]}


def learn_from_matches(matched, splits, groups: list[dict]):
    """
    Mine the already-reconciled pairs for two defaults.

    Payee renames are reliable - Booking.com becomes Booking every time - so
    the most frequent rename for an Up description pre-fills the payee field.
    Categories are not: restaurants-and-cafes has landed in four different
    categories, and one merchant in three, so only a merchant seen with a
    single category ever pre-fills one. Everything else starts empty and has to
    be chosen.
    """
    by_name = category_ids_by_name(groups)
    renames: dict[str, Counter] = defaultdict(Counter)
    cats: dict[str, Counter] = defaultdict(Counter)

    pairs = [(u, y) for u, y, _ in matched] + [(p, y) for y, p, _ in splits]
    for u, y in pairs:
        if y.label and y.label != u.label:
            renames[u.label][y.label] += 1
        if y.extra.get("category") in by_name:
            cats[u.label][by_name[y.extra["category"]]] += 1

    return (
        {k: v.most_common(1)[0][0] for k, v in renames.items()},
        {k: v.most_common(1)[0][0] for k, v in cats.items() if len(v) == 1},
    )


# ==========================================================================
# Pushing to YNAB
# ==========================================================================

PUSH_MEMO = "Pushed by localhost script"


def load_pushed(path: str) -> dict[str, str]:
    """Up ids already sent, mapped to when. No import_id means YNAB will
    happily create a second copy, so this file is the only thing standing
    between a stray double-click and 52 duplicates."""
    try:
        with open(path) as fh:
            return json.load(fh)
    except (OSError, json.JSONDecodeError):
        return {}


def save_pushed(path: str, pushed: dict[str, str]) -> None:
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(pushed, fh, indent=2, sort_keys=True)


def build_payload(selections: list[dict], rows: dict[str, dict], account_id: str):
    """
    Turn the report's selections into YNAB transaction objects.

    Amounts and dates come from `rows`, derived from Up, never from the posted
    payload - the browser may choose a category and rewrite a payee, but it
    does not get to decide what a transaction was worth.

    Returns the transactions, any problems, and for each transaction the Up
    ids it accounts for - a share consumes both the purchase and the repayment,
    and both must be logged or the repayment could be sent again on its own.
    """
    transactions, problems, accounted = [], [], []
    for sel in selections:
        up_id = str(sel.get("up_id", ""))
        row = rows.get(up_id)
        if row is None:
            problems.append(f"{up_id[:8]}: not a transaction in this report")
            continue

        # A share row names the repayment it was paired with, so the amount is
        # recomputed here from both Up transactions. The browser can change
        # which purchase a repayment belongs to, so it cannot be the one to
        # decide what the entry is worth.
        pair_id = str(sel.get("paired_with") or "")
        cents = row["cents"]
        if pair_id:
            pair = rows.get(pair_id)
            if pair is None:
                problems.append(f"{row['payee']}: unknown repayment pairing")
                continue
            if pair["cents"] <= 0 or row["cents"] >= 0:
                problems.append(f"{row['payee']}: that pairing is not a purchase plus a repayment")
                continue
            cents = row["cents"] + pair["cents"]
            if cents >= 0:
                problems.append(f"{row['payee']}: repayment exceeds the bill")
                continue

        category_id = (sel.get("category_id") or "").strip()
        if not category_id:
            problems.append(f"{row['payee']}: no category chosen")
            continue
        if category_id not in row["valid_categories"]:
            problems.append(f"{row['payee']}: unknown category")
            continue

        payee = (sel.get("payee") or row["payee"]).strip()[:200]
        if not payee:
            problems.append(f"{up_id[:8]}: empty payee")
            continue

        consumed = [up_id] + ([pair_id] if pair_id else [])
        transactions.append({
            "account_id": account_id,
            "date": row["date"],
            # Up works in cents, YNAB in milliunits.
            "amount": cents * 10,
            "payee_name": payee,
            "category_id": category_id,
            "memo": PUSH_MEMO,
            "cleared": row["cleared"],
            # Omitted, a transaction arrives unapproved.
            "approved": True,
        })
        accounted.append(consumed)
    return transactions, problems, accounted


def push_transactions(token: str, plan_id: str, transactions: list[dict]) -> dict:
    """POST them all in one request and return YNAB's response body."""
    body = json.dumps({"transactions": transactions}).encode("utf-8")
    req = urllib.request.Request(
        f"{YNAB_ROOT}/plans/{plan_id}/transactions",
        data=body,
        method="POST",
        headers={
            "Authorization": f"Bearer {token}",
            "Accept": "application/json",
            "Content-Type": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as err:
        detail = err.read().decode("utf-8", errors="replace")[:600]
        raise RuntimeError(f"YNAB returned HTTP {err.code}: {detail}") from err


def serve_report(page: str, rows: dict[str, dict], cfg: dict, pushed_path: str,
                 host: str = "127.0.0.1", port: int = 8713, dry_run: bool = False,
                 open_browser: bool = False, force: bool = False):
    """
    Serve the report locally so its send button can actually reach YNAB.

    The page cannot call YNAB itself: a token has no business in a browser, and
    a file:// page is blocked from posting to localhost anyway. So the report is
    served from here, the token stays in this process, and the browser only
    ever posts its selections back.

    Bound to the loopback interface, and every POST must carry a one-time
    secret printed into the page it came from - otherwise any other page you
    have open could quietly post transactions into your plan while this is
    running.
    """
    secret = secrets.token_urlsafe(24)
    page = page.replace("__PUSH_SECRET__", secret)
    token = require(cfg, "YNAB_TOKEN")
    plan_id = require(cfg, "YNAB_PLAN_ID")
    account_id = require(cfg, "YNAB_ACCOUNT_ID")

    class Handler(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, fmt, *args):  # quieter than the default
            print(f"  {self.address_string()} {fmt % args}", file=sys.stderr)

        def _send(self, code: int, body: bytes, ctype: str) -> None:
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)

        def _json(self, code: int, obj) -> None:
            self._send(code, json.dumps(obj).encode("utf-8"), "application/json")

        def do_GET(self):
            if self.path in ("/", "/index.html"):
                self._send(200, page.encode("utf-8"), "text/html; charset=utf-8")
            else:
                self._send(404, b"not found", "text/plain")

        def do_POST(self):
            # Read the body first, always. Leaving it unread on an HTTP/1.1
            # connection corrupts whatever request comes next down the same
            # socket, so rejecting a request early still has to drain it.
            length = int(self.headers.get("Content-Length") or 0)
            raw = self.rfile.read(length) if 0 < length <= 1_000_000 else b""
            if length > 1_000_000:
                self._json(413, {"error": "payload too large"})
                return

            if self.path != "/push":
                self._send(404, b"not found", "text/plain")
                return
            if not secrets.compare_digest(
                self.headers.get("X-Push-Secret") or "", secret
            ):
                self._json(403, {"error": "bad or missing push secret"})
                return

            try:
                body = json.loads(raw.decode("utf-8"))
                selections = body["selections"]
                if not isinstance(selections, list):
                    raise ValueError("selections must be a list")
            except (json.JSONDecodeError, KeyError, TypeError, ValueError,
                    UnicodeDecodeError) as err:
                self._json(400, {"error": f"could not read request: {err}"})
                return

            pushed = load_pushed(pushed_path)

            def seen(sel):
                if force:
                    return False
                return (str(sel.get("up_id")) in pushed
                        or str(sel.get("paired_with") or "") in pushed)

            already = [s for s in selections if seen(s)]
            fresh = [s for s in selections if not seen(s)]

            transactions, problems, accounted = build_payload(fresh, rows, account_id)
            if problems:
                self._json(400, {"error": "; ".join(problems[:6]), "problems": problems})
                return
            if not transactions:
                self._json(400, {
                    "error": "Nothing new to send."
                             + (f" {len(already)} already sent." if already else "")
                })
                return

            if dry_run:
                self._json(200, {
                    "dry_run": True,
                    "created": 0,
                    "skipped": len(already),
                    "transactions": transactions,
                    "message": f"Dry run — {len(transactions)} would be sent, nothing written.",
                })
                return

            try:
                result = push_transactions(token, plan_id, transactions)
            except (RuntimeError, urllib.error.URLError, TimeoutError) as err:
                self._json(502, {"error": str(err)})
                return

            stamp = datetime.now().isoformat(timespec="seconds")
            sent_ids = [uid for group in accounted for uid in group]
            pushed.update({uid: stamp for uid in sent_ids})
            save_pushed(pushed_path, pushed)

            created = result.get("data", {}).get("transaction_ids", [])
            print(f"  pushed {len(created)} transaction(s) to YNAB", file=sys.stderr)
            self._json(200, {
                "created": len(created),
                "skipped": len(already),
                "up_ids": sent_ids,
                "message": f"{len(created)} sent to YNAB."
                           + (f" {len(already)} skipped as already sent." if already else ""),
            })

    server = http.server.ThreadingHTTPServer((host, port), Handler)
    url = f"http://{host}:{port}/"
    print(f"\nServing the report at {url}", file=sys.stderr)
    if dry_run:
        print("  DRY RUN — the send button will not write to YNAB.", file=sys.stderr)
    if force:
        print("  --force: the pushed log is ignored, so re-sending will "
              "duplicate in YNAB.", file=sys.stderr)
    print("  Ctrl-C to stop.\n", file=sys.stderr)
    # Only now that the socket is bound, or the browser races the server and
    # lands on a connection refused.
    if open_browser:
        webbrowser.open(url)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nStopped.", file=sys.stderr)
    finally:
        server.server_close()
    return url


# ==========================================================================
# Model
# ==========================================================================


@dataclass
class Txn:
    source: str
    uid: str
    day: date
    cents: int  # negative = money out, in both APIs
    label: str
    status: str
    extra: dict = field(default_factory=dict)

    @property
    def dollars(self) -> str:
        return f"{self.cents / 100:,.2f}"

    @property
    def abs_dollars(self) -> str:
        return f"{abs(self.cents) / 100:,.2f}"


def normalise_up(records: list[dict]) -> list[Txn]:
    out = []
    for tx in records:
        a = tx["attributes"]
        created = a["createdAt"]
        out.append(
            Txn(
                source="UP",
                uid=tx["id"],
                # createdAt carries an explicit offset, so .date() gives the
                # local calendar day rather than the UTC one - which would
                # push a late-evening purchase onto the next day.
                day=datetime.fromisoformat(created).date(),
                cents=a["amount"]["valueInBaseUnits"],
                label=a.get("description") or "",
                status=a.get("status") or "",
                extra={
                    "created_at": created,
                    "type": a.get("transactionType") or "",
                    "raw_text": a.get("rawText") or "",
                    "category": ((tx.get("relationships", {}).get("category", {}) or {}).get("data") or {}).get("id", ""),
                    "parent_category": ((tx.get("relationships", {}).get("parentCategory", {}) or {}).get("data") or {}).get("id", ""),
                    "message": a.get("message") or "",
                },
            )
        )
    return out


def normalise_ynab(records: list[dict]) -> list[Txn]:
    out = []
    skipped = 0
    for tx in records:
        if tx.get("deleted"):
            skipped += 1
            continue
        milli = tx["amount"]
        if milli % 10:
            warn(f"YNAB {tx['id']} has sub-cent amount {milli} milliunits; rounding.")
        out.append(
            Txn(
                source="YNAB",
                uid=tx["id"],
                day=date.fromisoformat(tx["date"]),
                cents=round(milli / 10),  # milliunits -> cents
                label=tx.get("payee_name") or "",
                status=tx.get("cleared") or "",
                extra={
                    "category": tx.get("category_name") or "",
                    "memo": tx.get("memo") or "",
                    # A split's children sum to the parent, and the bank only
                    # ever saw the parent total, so match on that.
                    "is_split": bool(tx.get("subtransactions")),
                    "is_transfer": bool(tx.get("transfer_account_id")),
                },
            )
        )
    if skipped:
        print(f"  Skipped {skipped} deleted YNAB transaction(s).", file=sys.stderr)
    return out


# ==========================================================================
# Reconciliation
# ==========================================================================


def match_exact(up: list[Txn], ynab: list[Txn], tolerance: int):
    """
    Pair on identical signed amount, within `tolerance` days, one-to-one.

    A set difference would be wrong: identical amounts recur, so each
    transaction must be consumed by at most one partner. Candidates are
    claimed greedily by date gap - same-day first, then a day out, and so on -
    with ties broken on date and id so runs are reproducible.
    """
    by_amount: dict[int, list[int]] = defaultdict(list)
    for i, t in enumerate(up):
        by_amount[t.cents].append(i)

    candidates = []
    for j, y in enumerate(ynab):
        for i in by_amount.get(y.cents, []):
            gap = abs((up[i].day - y.day).days)
            if gap <= tolerance:
                candidates.append((gap, up[i].day, up[i].uid, i, j))
    candidates.sort()

    used_up: set[int] = set()
    used_ynab: set[int] = set()
    pairs = []
    for gap, _, _, i, j in candidates:
        if i in used_up or j in used_ynab:
            continue
        used_up.add(i)
        used_ynab.add(j)
        pairs.append((up[i], ynab[j], gap))

    return (
        pairs,
        [t for i, t in enumerate(up) if i not in used_up],
        [t for j, t in enumerate(ynab) if j not in used_ynab],
    )


def match_splits(up: list[Txn], ynab: list[Txn], tolerance: int, reimb_window: int):
    """
    Explain a YNAB row as a shared expense that has already been paid back.

    Up records two transactions for a split - the full purchase, then a deposit
    when the other person settles up - while YNAB only ever holds your share.
    No single Up amount equals the YNAB amount, so look for a purchase plus an
    inflow that sum to it exactly.

    Candidates are scored on how close the purchase date sits to the YNAB date
    first, then on how near the split is to even, because a 50/50 share is far
    likelier than a coincidental arithmetic hit.
    """
    outflows = [t for t in up if t.cents < 0]
    inflows = [t for t in up if t.cents > 0]

    triples = []
    for y in ynab:
        if y.cents >= 0:
            continue
        for p in outflows:
            if p.cents >= y.cents:  # the purchase has to exceed your share
                continue
            if abs((p.day - y.day).days) > tolerance:
                continue
            needed = y.cents - p.cents
            for d in inflows:
                if d.cents != needed or abs((d.day - p.day).days) > reimb_window:
                    continue
                evenness = abs(d.cents - abs(p.cents) / 2)
                triples.append((abs((p.day - y.day).days), evenness, y.uid, p.uid, d.uid, y, p, d))
    triples.sort(key=lambda t: t[:5])

    used: set[str] = set()
    explained = []
    for *_, y, p, d in triples:
        if used & {y.uid, p.uid, d.uid}:
            continue
        used |= {y.uid, p.uid, d.uid}
        explained.append((y, p, d))

    return (
        explained,
        [t for t in up if t.uid not in used],
        [t for t in ynab if t.uid not in used],
    )


def match_zero_net(up: list[Txn], reimb_window: int, same_merchant: bool = False):
    """
    Find Up purchases cancelled out by an equal inflow - a refund, or a cost
    fronted and repaid in full. Net zero means there is nothing to enter in
    YNAB, so these are reconciled rather than gaps.

    Runs in two passes, controlled by `same_merchant`. With it set, both sides
    must carry the same description: that is a merchant reversing its own
    charge, which is about as certain as this gets, so it is settled before the
    split shortlists get a look in. Without it, only the categories need agree,
    which is weaker - a repayment from a friend that happens to equal some
    other bill looks identical - so that pass runs last, on whatever the
    shortlists didn't want.

    Equal-and-opposite amounts are never enough alone. An $11.17 grocery
    repayment once cancelled an $11.17 cafe bill and swallowed both, and
    because the pair sums to zero the balance arithmetic still came out right
    and gave no hint anything was wrong.
    """
    outflows = [t for t in up if t.cents < 0]
    inflows = [t for t in up if t.cents > 0]

    candidates = []
    for p in outflows:
        for d in inflows:
            if d.cents != -p.cents:
                continue
            gap = abs((d.day - p.day).days)
            if gap > reimb_window:
                continue
            if same_merchant and p.label.casefold() != d.label.casefold():
                continue
            both_categorised = p.extra.get("category") and d.extra.get("category")
            if both_categorised and not same_category(p, d):
                continue
            candidates.append((gap, p.uid, d.uid, p, d))
    candidates.sort(key=lambda c: c[:3])

    used: set[str] = set()
    cancelled = []
    for _, _, _, p, d in candidates:
        if used & {p.uid, d.uid}:
            continue
        used |= {p.uid, d.uid}
        cancelled.append((p, d))

    return cancelled, [t for t in up if t.uid not in used]


def is_partner(txn: Txn, partners: list[str]) -> bool:
    """Is this inflow from someone you routinely split costs with?"""
    if not partners:
        return True
    label = txn.label.casefold()
    return any(p.casefold() in label for p in partners if p)


def same_category(a: Txn, b: Txn) -> bool:
    """
    Do two Up transactions carry the same category and parent?

    Up copies the category of a purchase onto the repayment that settles it,
    which turns out to be the single most useful signal for pairing them -
    it held on every confidently matched pair in testing. Uncategorised
    transactions are excluded: two blanks agreeing tells you nothing.
    """
    return bool(
        a.extra.get("category")
        and a.extra["category"] == b.extra.get("category")
        and a.extra.get("parent_category") == b.extra.get("parent_category")
    )


SPLIT_SIGNALS = """Scoring is a ranking aid, not a probability. The weights say which
signals have proved hardest to hit by coincidence, nothing more."""


HALF_BAND = 90  # an exact half starts here; nothing else can reach it


def score_split(purchase: Txn, deposit: Txn, settle_window: int):
    """
    Rate how likely `deposit` is to be someone's share of `purchase`.

    Amount arithmetic alone is hopeless here - with fifty unmatched purchases
    and twenty repayments in a month, a $51.00 deposit sits plausibly against a
    dozen of them. So signals are weighted by how hard each is to hit by
    chance, and every one that fires is named in the output so a ranking can be
    argued with rather than taken on faith.

    Scoring runs in two bands. Halving a bill is the one pattern that stands on
    its own, so it scores from `HALF_BAND` up, and everything else is capped
    below that: an uncategorised bill split straight down the middle outranks
    any number of same-category near-misses, which is the right answer and the
    opposite of what a single pool of weights produces.

    Nothing is rejected outright. A split can be an arbitrary number - one of
    yours was 61.3% - and a gate demanding a clean fraction would hide the real
    answer rather than rank it second.
    """
    total = abs(purchase.cents)
    her = deposit.cents
    mine = total - her
    if mine <= 0:
        return None

    reasons: list[str] = []
    categorised = same_category(purchase, deposit)
    offset = (deposit.day - purchase.day).days
    nearness = 0.0
    if settle_window > 0:
        nearness = max(0.0, 1 - max(offset, 0) / settle_window)

    # ---- band A: exactly half ------------------------------------------
    if abs(total - 2 * her) <= 1:
        reasons.append("exactly half")
        score = HALF_BAND + round(4 * nearness)
        if categorised:
            score += 6
            reasons.append("same category")
        return min(100, score), reasons, mine, offset

    # ---- band B: everything else, capped at 85 -------------------------
    score = 0
    if categorised:
        score += 40
        reasons.append("same category")
    elif purchase.extra.get("category") and purchase.extra["category"] == deposit.extra.get("category"):
        score += 26
        reasons.append("same category, different parent")

    for parts, name, points in ((3, "a third", 22), (4, "a quarter", 12)):
        if abs(total - parts * her) <= 1:
            score += points
            reasons.append(f"exactly {name}")
            break
    else:
        if abs(2 * total - 3 * her) <= 1:
            score += 12
            reasons.append("exactly two thirds")

    if mine % 100 == 0:
        score += 10
        reasons.append(f"leaves a round {mine / 100:,.2f}")
    if her % 100 == 0:
        score += 5
        reasons.append("round repayment")

    score += round(8 * nearness)

    share = her / total
    if share > 0.8 or share < 0.1:
        score -= 12
        reasons.append("lopsided share")

    return min(HALF_BAND - 5, max(0, score)), reasons, mine, offset


EVIDENCE_CLASSES = (
    "half of the bill, and Up agrees on the category",
    "half of the bill",
    "a clean fraction, and Up agrees on the category",
    "a round share, and Up agrees on the category",
)


def evidence_class(reasons: list[str]) -> int | None:
    """
    Sort a pairing into a band of evidence, strongest first, or None if it
    isn't strong enough to pre-select.

    Bands rather than a point margin, because points are the wrong instrument
    for this decision. An uncategorised bill split exactly in half is
    trustworthy; three same-category near-misses are not, however close their
    scores land. Comparing kinds of evidence says that directly.
    """
    half = "exactly half" in reasons
    categorised = "same category" in reasons
    if half:
        return 0 if categorised else 1
    if not categorised:
        return None
    if any(r.startswith("exactly ") for r in reasons):
        return 2
    if any(r.startswith("leaves a round") for r in reasons):
        return 3
    return None


def match_unentered_splits(up: list[Txn], partners: list[str], settle_window: int,
                           floor: int = 25, shortlist: int = 5):
    """
    Find shared costs that have been settled up but never entered in YNAB.

    This is the case where you front the whole bill, the other person pays
    their share back, and neither Up transaction has made it into YNAB. Every
    other pass misses it: the amounts match nothing, the pair doesn't net to
    zero, and the split pass needs a YNAB row to work backwards from. Left
    alone the report asks you to enter the full purchase and the repayment
    separately, which is two entries you'd never make.

    Returns a ranked shortlist per repayment rather than a single answer. One
    candidate is pre-selected only when it is the sole occupant of the best
    evidence band available for that repayment. Where two purchases sit in the
    same band - two uncategorised bills each exactly half the repayment, say -
    neither is promoted over the other: they are marked as joint best, listed
    together, and the choice is left to you. Their order among themselves
    carries no meaning.

    Claims are assigned across all repayments at once, so two of them can never
    pre-select the same purchase - without that, two $7.64 repayments would
    both latch onto the same $15.28 bill.

    Nothing is consumed. Grouping a purchase and a repayment into one entry
    moves your balance exactly as far as entering them separately, so the
    pairing you pick cannot affect the totals - only the wording of the
    instruction.
    """
    outflows = [t for t in up if t.cents < 0]
    # A merchant reversing its own charge is not anybody's share of anything.
    # Up labels these, and the description matches the purchase, so exclude
    # them outright - without a configured partner list they would otherwise
    # compete for bills, and an Apple refund of $103.99 will happily claim a
    # separate $149.99 Apple charge on the strength of a round $46.00
    # remainder.
    inflows = [
        t for t in up
        if t.cents > 0
        and is_partner(t, partners)
        and t.extra.get("type") != "Refund"
    ]

    blocks = []
    for d in sorted(inflows, key=lambda t: (t.day, -t.cents)):
        rated = []
        for p in outflows:
            offset = (d.day - p.day).days
            # A repayment follows the purchase, give or take a couple of days
            # for someone who pays you up front.
            if offset < -2 or offset > settle_window:
                continue
            if p.label.casefold() == d.label.casefold():
                continue  # same merchant both ways: a reversal, not a split
            rating = score_split(p, d, settle_window)
            if rating is None:
                continue
            score, reasons, mine, _ = rating
            if score < floor:
                continue
            rated.append({
                "purchase": p,
                "score": score,
                "reasons": reasons,
                "share": mine,
                "band": evidence_class(reasons),
            })

        if not rated:
            continue
        # Score orders the shortlist; the date and id only keep runs
        # reproducible, and mean nothing between equally scored candidates.
        rated.sort(key=lambda r: (-r["score"], r["purchase"].day, r["purchase"].uid))
        rated = rated[:shortlist]

        bands = [r["band"] for r in rated if r["band"] is not None]
        best = min(bands, default=None)
        joint = [r for r in rated if r["band"] == best] if best is not None else []
        for r in joint:
            r["joint"] = len(joint) > 1
        blocks.append({
            "deposit": d,
            "candidates": rated,
            "chosen": None,
            "contenders": joint,
            "tied": len(joint) > 1,
        })

    # Strongest evidence gets first claim on a purchase, across every repayment.
    ranked = sorted(
        (
            (b["contenders"][0]["band"], -b["contenders"][0]["score"], b["deposit"].uid, b)
            for b in blocks if len(b["contenders"]) == 1
        ),
        key=lambda r: r[:3],
    )
    taken: set[str] = set()
    for *_, block in ranked:
        cand = block["contenders"][0]
        if cand["purchase"].uid in taken:
            continue
        block["chosen"] = cand
        taken.add(cand["purchase"].uid)

    claimed = taken | {b["deposit"].uid for b in blocks if b["chosen"]}
    return blocks, claimed


def match_amends(up: list[Txn], ynab: list[Txn], days: int, cents_tol: int):
    """
    Pair a YNAB row with an Up transaction of nearly the same amount - the
    signature of a mistyped figure. Same direction only, and scored on the size
    of the discrepancy before the date gap, since a 4c difference two days
    apart is a likelier typo than a 90c difference on the same day.
    """
    candidates = []
    for y in ynab:
        for u in up:
            if (u.cents < 0) != (y.cents < 0):
                continue
            delta = abs(u.cents - y.cents)
            gap = abs((u.day - y.day).days)
            if delta == 0 or delta > cents_tol or gap > days:
                continue
            candidates.append((delta, gap, y.uid, u.uid, y, u))
    candidates.sort(key=lambda c: c[:4])

    used: set[str] = set()
    amends = []
    for _, _, _, _, y, u in candidates:
        if used & {y.uid, u.uid}:
            continue
        used |= {y.uid, u.uid}
        amends.append((y, u))

    return (
        amends,
        [t for t in up if t.uid not in used],
        [t for t in ynab if t.uid not in used],
    )


# ==========================================================================
# HTML
# ==========================================================================

CSS = """
:root {
  color-scheme: light dark;
  --paper: #eef1f4;
  --ink: #16212b;
  --ink-soft: #55636f;
  --rule: #ccd5dd;
  --rule-firm: #16212b;
  --share: #1b5a74;
  --add: #15603f;
  --add-bg: #dfeee6;
  --amend: #8a5000;
  --amend-bg: #f6e9d6;
  --query: #8a2733;
  --query-bg: #f4e0e2;
  --done: #8b97a2;
}
@media (prefers-color-scheme: dark) {
  :root {
    --paper: #121a21;
    --ink: #e4eaef;
    --ink-soft: #97a5b1;
    --rule: #2b3843;
    --rule-firm: #6d7f8d;
    --share: #7bb9d4;
    --add: #6cc596;
    --add-bg: #17302640;
    --amend: #d9a055;
    --amend-bg: #35291640;
    --query: #dd8f99;
    --query-bg: #35191d40;
    --done: #5d6b76;
  }
}
* { box-sizing: border-box; }
[hidden] { display: none !important; }
body {
  margin: 0;
  padding: calc(3rem + env(safe-area-inset-top, 0px)) 1.5rem
           calc(6rem + env(safe-area-inset-bottom, 0px));
  background: var(--paper);
  color: var(--ink);
  font-family: "Iowan Old Style", "Palatino Linotype", Palatino, "Book Antiqua", Georgia, serif;
  font-size: 17px;
  line-height: 1.5;
  font-variant-numeric: tabular-nums;
}
main { max-width: 52rem; margin: 0 auto; }
h1 {
  font-size: clamp(1.7rem, 4.5vw, 2.6rem);
  font-weight: 600;
  line-height: 1.15;
  letter-spacing: -0.015em;
  margin: 0 0 0.6rem;
  max-width: 34ch;
}
.window { color: var(--ink-soft); margin: 0 0 2rem; max-width: 62ch; }
.window b { font-weight: 600; color: var(--ink); }
.progress { margin: 0 0 2rem; }
#progress-gap { color: var(--ink-soft); }
#progress-gap::before { content: " · "; }
#progress-gap.settled { color: var(--add); font-weight: 600; }
.balance {
  border-collapse: collapse;
  margin: 0 0 3.5rem;
  min-width: 18rem;
}
.balance th {
  text-align: left;
  font-weight: 400;
  color: var(--ink-soft);
  padding: 0.3rem 2.5rem 0.3rem 0;
}
.balance td.num { text-align: right; white-space: nowrap; }
.balance tr.total th { color: var(--ink); font-weight: 600; }
.balance tr.total th, .balance tr.total td {
  border-top: 1px solid var(--rule-firm);
  padding-top: 0.45rem;
  font-weight: 600;
}
.progress-rule {
  height: 3px;
  background: var(--rule);
  position: relative;
  margin-top: 0.6rem;
}
.progress-rule i {
  position: absolute;
  inset: 0 auto 0 0;
  background: var(--rule-firm);
  transition: width 0.25s ease;
}
h2 {
  font-size: 1.2rem;
  font-weight: 600;
  margin: 0;
  display: flex;
  align-items: baseline;
  gap: 0.6rem;
}
h2 .count {
  font-size: 0.95rem;
  font-weight: 400;
  color: var(--ink-soft);
}
section { margin-bottom: 3.5rem; }
section > p.lede { color: var(--ink-soft); margin: 0.4rem 0 1.4rem; max-width: 62ch; }
.entry {
  display: grid;
  grid-template-columns: 1.3rem 5.4rem 1fr auto;
  gap: 0.35rem 0.9rem;
  padding: 0.85rem 0;
  border-top: 1px solid var(--rule);
  align-items: baseline;
}
.entry:last-child { border-bottom: 1px solid var(--rule); }
.entry input[type=checkbox] {
  appearance: none;
  width: 1.05rem;
  height: 1.05rem;
  border: 1.5px solid var(--ink-soft);
  border-radius: 3px;
  cursor: pointer;
  position: relative;
  top: 0.2rem;
  margin: 0;
}
.entry input[type=checkbox]:checked { background: var(--rule-firm); border-color: var(--rule-firm); }
.entry input[type=checkbox]:checked::after {
  content: "";
  position: absolute;
  left: 4px; top: 1px;
  width: 5px; height: 9px;
  border: solid var(--paper);
  border-width: 0 2px 2px 0;
  transform: rotate(45deg);
}
.entry input[type=checkbox]:focus-visible { outline: 2px solid var(--ink); outline-offset: 2px; }
.date { color: var(--ink-soft); font-size: 0.92rem; }
.payee { font-weight: 600; }
.amount { text-align: right; font-weight: 600; white-space: nowrap; }
.note {
  grid-column: 3 / -1;
  color: var(--ink-soft);
  font-size: 0.92rem;
}
.note .was { text-decoration: line-through; }
.tag {
  display: inline-block;
  font-size: 0.75rem;
  font-weight: 600;
  padding: 0.1rem 0.4rem;
  border-radius: 3px;
  vertical-align: 0.1em;
  margin-left: 0.4rem;
}
.tag.held { background: var(--amend-bg); color: var(--amend); }
.tag.in { background: var(--add-bg); color: var(--add); }
.tag.check { background: var(--amend-bg); color: var(--amend); }
.entry.done .payee, .entry.done .amount, .entry.done .date, .entry.done .note {
  color: var(--done);
  text-decoration: line-through;
  text-decoration-thickness: 1px;
}
.entry.done .tag { opacity: 0.45; }
.copy {
  grid-column: 3 / -1;
  justify-self: start;
  font: inherit;
  font-size: 0.85rem;
  color: var(--ink-soft);
  background: none;
  border: 1px solid var(--rule);
  border-radius: 3px;
  padding: 0.1rem 0.5rem;
  cursor: pointer;
}
.copy:hover { color: var(--ink); border-color: var(--ink-soft); }
.block { border-top: 1px solid var(--rule); }
.block .entry { border-top: none; }
.block:last-of-type { border-bottom: 1px solid var(--rule); }
.entry.unset .payee, .entry.unset .amount { color: var(--ink-soft); font-style: italic; }
.block details { border: none; padding: 0 0 0.9rem 2.2rem; }
.block details summary { font-weight: 400; font-size: 0.9rem; color: var(--ink-soft); }
.ranked { list-style: none; margin: 0.6rem 0 0; padding: 0; }
.ranked li { margin: 0; }
.option {
  display: grid;
  grid-template-columns: 1.1rem 2.6rem 1fr;
  gap: 0.2rem 0.7rem;
  align-items: baseline;
  padding: 0.4rem 0.5rem;
  border-radius: 4px;
  cursor: pointer;
  font-size: 0.93rem;
}
.option:hover { background: var(--amend-bg); }
.option input { margin: 0; position: relative; top: 0.15rem; }
.option .score {
  text-align: right;
  font-size: 0.82rem;
  color: var(--ink-soft);
  position: relative;
}
.option .score::after {
  content: "";
  position: absolute;
  left: 0; right: 0; bottom: -3px;
  height: 2px;
  background: linear-gradient(to right, var(--share) var(--fill, 0%), var(--rule) var(--fill, 0%));
}
.option .score.none::after { display: none; }
.option .why { grid-column: 3; color: var(--ink-soft); font-size: 0.85rem; }
.joint { color: var(--share); font-weight: 600; }
.joint::before { content: "· "; color: var(--ink-soft); font-weight: 400; }
.option:has(input:checked) { background: var(--add-bg); }
.option:has(input:focus-visible) { outline: 2px solid var(--ink); }
/* ---- sendable row controls ---- */
.fields {
  grid-column: 3 / -1;
  display: flex;
  flex-wrap: wrap;
  gap: 0.5rem 1rem;
  margin-top: 0.45rem;
}
.field { display: flex; align-items: baseline; gap: 0.4rem; font-size: 0.88rem; }
.field > span { color: var(--ink-soft); }
.field input:not([type=hidden]) {
  font: inherit;
  font-size: 0.9rem;
  padding: 0.12rem 0.4rem;
  border: 1px solid var(--rule);
  border-radius: 3px;
  background: transparent;
  color: var(--ink);
  min-width: 11rem;
}
.field input:focus { outline: none; border-color: var(--ink-soft); }
.field input:disabled { color: var(--done); border-color: transparent; }
.combo { position: relative; }
.combo.unset .cat-input { border-color: var(--query); }
.cat-menu {
  position: absolute;
  z-index: 5;
  top: 100%;
  left: 3.9rem;
  margin: 0.15rem 0 0;
  padding: 0.2rem;
  list-style: none;
  min-width: 15rem;
  max-height: 14rem;
  overflow-y: auto;
  background: var(--paper);
  border: 1px solid var(--rule-firm);
  border-radius: 4px;
  box-shadow: 0 6px 20px rgb(0 0 0 / 0.18);
  font-size: 0.9rem;
}
.cat-menu li { padding: 0.2rem 0.45rem; border-radius: 3px; cursor: pointer; }
.cat-menu li small { color: var(--ink-soft); }
.cat-menu li[aria-selected=true], .cat-menu li:hover { background: var(--add-bg); }
.cat-menu li.none { color: var(--ink-soft); cursor: default; font-style: italic; }
.entry[data-sent] { opacity: 0.6; }
.entry[data-sent] .amount::after {
  content: " sent";
  font-size: 0.72rem;
  font-weight: 600;
  color: var(--add);
}

/* ---- send button and modal ---- */
.send {
  font: inherit;
  font-size: 0.85rem;
  font-weight: 600;
  background: var(--rule-firm);
  color: var(--paper);
  border: none;
  border-radius: 4px;
  padding: 0.2rem 0.7rem;
  margin-left: 0.6rem;
  cursor: pointer;
}
.send:hover { opacity: 0.88; }
.send:disabled { opacity: 0.4; cursor: default; }
.ghost {
  font: inherit;
  font-size: 0.85rem;
  background: none;
  border: 1px solid var(--rule);
  border-radius: 4px;
  padding: 0.2rem 0.7rem;
  color: var(--ink-soft);
  cursor: pointer;
}
.modal {
  position: fixed;
  inset: 0;
  background: rgb(0 0 0 / 0.45);
  display: grid;
  place-items: center;
  padding: 1.5rem;
  z-index: 20;
}
.sheet {
  background: var(--paper);
  border-radius: 6px;
  padding: 1.5rem;
  max-width: 52rem;
  width: 100%;
  max-height: 85vh;
  display: flex;
  flex-direction: column;
  box-shadow: 0 20px 60px rgb(0 0 0 / 0.35);
}
.sheet h2 { margin: 0 0 0.3rem; }
.sheet .lede { margin: 0 0 1rem; }
.sheet-scroll { overflow-y: auto; flex: 1; }
.review { width: 100%; border-collapse: collapse; font-size: 0.92rem; }
.review th {
  text-align: left;
  color: var(--ink-soft);
  font-weight: 600;
  border-bottom: 1px solid var(--rule);
  padding: 0.3rem 0.6rem 0.3rem 0;
  position: sticky;
  top: 0;
  background: var(--paper);
}
.review td { padding: 0.28rem 0.6rem 0.28rem 0; border-bottom: 1px solid var(--rule); }
.review td.num { text-align: right; white-space: nowrap; }
/* The date is the narrowest column and the one that reads worst broken over
   two lines, so it never wraps. */
.review th:first-child, .review td:first-child { white-space: nowrap; width: 1%; }
.review td:nth-child(3) { color: var(--ink-soft); }
.review tfoot { position: sticky; bottom: 0; }
.review tfoot th {
  text-align: left;
  border-bottom: none;
  border-top: 1px solid var(--rule-firm);
  padding-top: 0.45rem;
  background: var(--paper);
}
.review tfoot td {
  border-bottom: none;
  border-top: 1px solid var(--rule-firm);
  padding-top: 0.45rem;
  font-weight: 600;
  background: var(--paper);
}
.review tfoot tr.after th, .review tfoot tr.after td {
  border-top: none;
  padding-top: 0.15rem;
  padding-bottom: 0.3rem;
  font-weight: 400;
  color: var(--ink-soft);
}
.review tfoot td.settled { color: var(--add); font-weight: 600; }
.sheet-actions { display: flex; justify-content: flex-end; gap: 0.6rem; margin-top: 1.2rem; }
.modal-error { color: var(--query); margin: 0.8rem 0 0; }
.dry { color: var(--amend); font-weight: 600; margin: 0 0 0.6rem; }
.mode {
  margin: -1rem 0 2rem;
  padding: 0.4rem 0.7rem;
  border-left: 3px solid var(--rule);
  color: var(--ink-soft);
  font-size: 0.9rem;
}
.mode code { font-size: 0.95em; }
.mode.live { border-left-color: var(--add); color: var(--add); }
.mode.dry { border-left-color: var(--amend); color: var(--amend); margin: -1rem 0 2rem; }
.add h2 { color: var(--add); }
.share h2 { color: var(--share); }
.amend h2 { color: var(--amend); }
.query h2 { color: var(--query); }
.empty { color: var(--ink-soft); font-style: italic; }
details { border-top: 1px solid var(--rule); padding: 1rem 0; }
details summary { cursor: pointer; font-weight: 600; }
details summary::marker { color: var(--ink-soft); }
details table { width: 100%; border-collapse: collapse; margin-top: 1rem; font-size: 0.92rem; }
details th {
  text-align: left;
  font-weight: 600;
  color: var(--ink-soft);
  border-bottom: 1px solid var(--rule);
  padding: 0.35rem 0.6rem 0.35rem 0;
}
details td { padding: 0.3rem 0.6rem 0.3rem 0; border-bottom: 1px solid var(--rule); vertical-align: top; }
details td.num { text-align: right; white-space: nowrap; }
footer { color: var(--ink-soft); font-size: 0.88rem; margin-top: 4rem; border-top: 1px solid var(--rule); padding-top: 1rem; }
.reset {
  font: inherit;
  font-size: 0.82rem;
  background: none;
  border: 1px solid var(--rule);
  border-radius: 3px;
  color: var(--ink-soft);
  cursor: pointer;
  padding: 0.05rem 0.5rem;
  margin-left: 0.6rem;
}
.reset:hover { color: var(--ink); border-color: var(--ink-soft); }
@media (max-width: 34rem) {
  body { padding: calc(2rem + env(safe-area-inset-top, 0px)) 1rem
                 calc(4rem + env(safe-area-inset-bottom, 0px)); }
  .entry { grid-template-columns: 1.3rem 1fr auto; }
  .date { grid-column: 2; }
  .payee { grid-column: 2; }
  .note, .copy { grid-column: 2 / -1; }
}
@media (prefers-reduced-motion: reduce) { * { transition: none !important; } }
"""

JS = """
const STORE = 'ynab-gap-done';
const PICKS = 'ynab-gap-picks';

function load(key, fallback) {
  try { return JSON.parse(localStorage.getItem(key)) ?? fallback; }
  catch (e) { return fallback; }
}
function save(key, value) {
  try { localStorage.setItem(key, JSON.stringify(value)); } catch (e) {}
}

const done = new Set(load(STORE, []));
const picks = load(PICKS, {});
const boxes = [...document.querySelectorAll('.entry input[type=checkbox]')];
const blocks = [...document.querySelectorAll('.block')];
const addRows = new Map(
  [...document.querySelectorAll('.add .entry[data-up-id]')].map(el => [el.dataset.upId, el])
);
const fmt = new Intl.NumberFormat('en-AU', {
  style: 'currency', currency: 'AUD', signDisplay: 'exceptZero'
});
const plain = new Intl.NumberFormat('en-AU', { minimumFractionDigits: 2 });

/* Restore saved picks before the first paint. */
blocks.forEach(block => {
  const saved = picks[block.dataset.deposit];
  if (saved === undefined) return;
  const radio = [...block.querySelectorAll('input[type=radio]')]
    .find(r => r.dataset.purchase === saved);
  if (radio) radio.checked = true;
});

function selectedIn(block) {
  return block.querySelector('input[type=radio]:checked');
}

/* Rewrite a block's header to match whatever purchase is selected. */
function refreshBlock(block) {
  const radio = selectedIn(block);
  const entry = block.querySelector('.entry');
  const box = entry.querySelector('input[type=checkbox]');
  const purchase = radio && radio.dataset.purchase;
  const deposit = Number(block.dataset.depositDelta || 0);
  const copy = entry.querySelector('.copy');

  if (purchase) {
    const share = Number(radio.dataset.share || 0);
    box.dataset.delta = share;
    /* The row stands for a different Up transaction now, so everything the
       send uses has to follow the pick, not just the visible figures. */
    entry.dataset.upId = purchase;
    entry.dataset.pushPair = block.dataset.deposit;
    entry.dataset.pushDate = radio.dataset.date || '';
    entry.dataset.pushCents = String(share);
    entry.querySelector('.payee').textContent = radio.dataset.payee || '(no description)';
    entry.querySelector('.amount').textContent = plain.format(share / 100);
    if (copy) {
      copy.dataset.copy = [radio.dataset.date, radio.dataset.payee,
                           plain.format(share / 100)].join('\t');
    }
  } else {
    /* With no purchase assigned the repayment itself is what goes in - still
       an entry to make, just an income one. A repayment with a shortlist is
       never listed in the main section, so this is its only appearance. */
    box.dataset.delta = deposit;
    /* Unassigned: the row is the repayment itself, with nothing paired. */
    entry.dataset.upId = block.dataset.deposit;
    entry.dataset.pushPair = '';
    entry.dataset.pushDate = block.dataset.depositDate || '';
    entry.dataset.pushCents = String(deposit);
    entry.querySelector('.payee').textContent = block.dataset.depositLabel || '';
    entry.querySelector('.amount').textContent = plain.format(deposit / 100);
    if (copy) {
      copy.dataset.copy = [block.dataset.depositDate, block.dataset.depositLabel,
                           plain.format(deposit / 100)].join('\t');
    }
  }
  entry.classList.toggle('unset', !purchase);
  return purchase;
}

function refreshAll() {
  /* Two repayments must never claim the same purchase. Later picks win, and
     the block that loses falls back to "not a split" rather than silently
     double-counting the bill. */
  const claimedBy = new Map();
  blocks.forEach(block => {
    const radio = selectedIn(block);
    const purchase = radio && radio.dataset.purchase;
    if (!purchase) return;
    const holder = claimedBy.get(purchase);
    if (holder && holder !== block) {
      const none = [...holder.querySelectorAll('input[type=radio]')]
        .find(r => !r.dataset.purchase);
      if (none) none.checked = true;
    }
    claimedBy.set(purchase, block);
  });

  blocks.forEach(refreshBlock);

  /* Any purchase not currently claimed goes back on the list to enter. */
  addRows.forEach((row, upId) => { row.hidden = claimedBy.has(upId); });

  save(PICKS, Object.fromEntries(
    blocks.map(b => {
      const r = selectedIn(b);
      return [b.dataset.deposit, r ? r.dataset.purchase : ''];
    })
  ));
  paint();
}

function paint() {
  let closed = 0;
  let settled = 0;
  let ticked = 0;
  let tickedSum = 0;
  let total = 0;

  boxes.forEach(box => {
    const entry = box.closest('.entry');
    if (entry.hidden) return;
    total++;
    /* Two different meanings of "handled". On a sendable row a tick means
       "include in the next push", so only an actually-sent row counts as
       done. Amends and queries can't be pushed, so a tick still means you
       dealt with it by hand. */
    const sendable = entry.dataset.pushable === '1';
    const handled = sendable ? entry.dataset.sent === '1' : box.checked;
    entry.classList.toggle('done', handled);
    if (handled) { settled++; closed += Number(box.dataset.delta || 0); }
    else if (sendable && box.checked) {
      ticked++;
      tickedSum += Number(box.dataset.delta || 0);
    }
  });

  const label = document.getElementById('progress-label');
  const bar = document.getElementById('progress-bar');
  const gapEl = document.getElementById('progress-gap');
  const canPush = pushRows.length > 0;

  if (label) {
    if (total === 0) {
      label.textContent = 'Nothing to fix.';
    } else if (canPush) {
      /* What matters here is how much of the batch is lined up, not how much
         has been dealt with - a tick is an intention to send, not progress. */
      const bits = [];
      if (ticked) bits.push(ticked + ' ticked to send');
      if (settled) bits.push(settled + ' sent');
      label.textContent = bits.length
        ? bits.join(' · ') + ' of ' + total
        : total + ' to fix — tick the ones to send';
    } else {
      label.textContent = settled + ' of ' + total + ' done';
    }
  }
  if (bar) bar.style.width = total ? ((settled + ticked) / total * 100) + '%' : '0%';

  if (gapEl) {
    const gap = Number(gapEl.dataset.gap || 0);
    const left = gap - closed;
    let note = gapEl.dataset.note ? ' · ' + gapEl.dataset.note : '';
    if (tickedSum) note = ' · ' + fmt.format(tickedSum / 100) + ' ticked' + note;
    if (total === 0) {
      gapEl.textContent = '';
    } else if (left === 0) {
      gapEl.textContent = 'Up and YNAB now agree.' + note;
      gapEl.className = 'settled';
    } else {
      /* Divided by 100 because every figure on this page is held in cents. */
      gapEl.textContent = fmt.format(left / 100) + ' still to account for' + note;
      gapEl.className = '';
    }
  }

  const reset = document.getElementById('reset');
  if (reset) {
    /* Dead controls are worse than absent ones, so it only appears when it
       would do something. */
    const ticked = boxes.filter(b => b.checked && !b.disabled).length;
    reset.hidden = ticked === 0;
    reset.textContent = 'Unmark all ' + ticked;
  }

  document.querySelectorAll('section').forEach(sec => {
    const el = sec.querySelector('.count');
    if (!el) return;
    const live = [...sec.querySelectorAll('.entry')].filter(e => !e.hidden);
    const sum = live.reduce((acc, e) => {
      const box = e.querySelector('input[type=checkbox]');
      return acc + (box ? Number(box.dataset.delta || 0) : 0);
    }, 0);
    el.textContent = live.length + (sum ? ' · ' + fmt.format(sum / 100) : '');
  });

  if (typeof refreshSend === 'function') refreshSend();
}

boxes.forEach(box => {
  box.checked = done.has(box.dataset.key);
  box.addEventListener('change', () => {
    box.checked ? done.add(box.dataset.key) : done.delete(box.dataset.key);
    save(STORE, [...done]);
    paint();
  });
});

document.querySelectorAll('.block input[type=radio]').forEach(radio => {
  radio.addEventListener('change', refreshAll);
});

/* ======================================================================
   Sending to YNAB
   ====================================================================== */

const CATS = window.CATEGORIES || [];
const PUSH_SECRET = '__PUSH_SECRET__';
const pushRows = [...document.querySelectorAll('.entry[data-pushable]')];

/* ---- category combobox ------------------------------------------------
   A datalist won't do here: it lets any typed text through, and a category
   has to resolve to a real id. So the visible input only ever filters, the
   hidden field carries the id, and typing clears it - no pick, no id. */
function wireCombo(row) {
  const input = row.querySelector('.cat-input');
  const hidden = row.querySelector('.cat-id');
  const menu = row.querySelector('.cat-menu');
  const combo = row.querySelector('.combo');
  if (!input) return;

  let active = -1;
  let shown = [];

  const named = id => CATS.find(c => c.id === id);
  const start = named(hidden.value);
  if (start) input.value = start.name;

  function markState() {
    const box = row.querySelector('input[type=checkbox]');
    combo.classList.toggle('unset', !hidden.value && box && box.checked);
  }

  function close() {
    menu.hidden = true;
    input.setAttribute('aria-expanded', 'false');
    active = -1;
  }

  function open(filter) {
    const needle = (filter || '').trim().toLowerCase();
    shown = needle
      ? CATS.filter(c => (c.name + ' ' + c.group).toLowerCase().includes(needle))
      : CATS.slice();
    menu.innerHTML = shown.length
      ? shown.slice(0, 60).map((c, i) =>
          `<li role="option" data-i="${i}" aria-selected="false">` +
          `${escapeHtml(c.name)} <small>${escapeHtml(c.group)}</small></li>`).join('')
      : '<li class="none">No category matches</li>';
    menu.hidden = false;
    input.setAttribute('aria-expanded', 'true');
    active = -1;
  }

  function highlight(next) {
    const items = [...menu.querySelectorAll('li[role=option]')];
    if (!items.length) return;
    active = (next + items.length) % items.length;
    items.forEach((li, i) => li.setAttribute('aria-selected', String(i === active)));
    items[active].scrollIntoView({ block: 'nearest' });
  }

  function choose(i) {
    const cat = shown[i];
    if (!cat) return;
    hidden.value = cat.id;
    input.value = cat.name;
    close();
    markState();
    paint();
  }

  input.addEventListener('input', () => {
    hidden.value = '';           /* typing invalidates any previous pick */
    open(input.value);
    markState();
    paint();
  });
  input.addEventListener('focus', () => open(input.value));
  input.addEventListener('keydown', e => {
    if (e.key === 'ArrowDown') { e.preventDefault(); if (menu.hidden) open(input.value); highlight(active + 1); }
    else if (e.key === 'ArrowUp') { e.preventDefault(); highlight(active - 1); }
    else if (e.key === 'Enter') {
      if (!menu.hidden) { e.preventDefault(); choose(active >= 0 ? active : 0); }
    } else if (e.key === 'Escape') { close(); }
  });
  input.addEventListener('blur', () => {
    /* Leaving the box without picking is not a choice. Restore the last real
       selection so the field never shows a category that isn't set. */
    setTimeout(() => {
      const cat = named(hidden.value);
      input.value = cat ? cat.name : '';
      close();
      markState();
      paint();
    }, 120);
  });
  menu.addEventListener('mousedown', e => {
    const li = e.target.closest('li[role=option]');
    if (li) { e.preventDefault(); choose(Number(li.dataset.i)); }
  });
}

function escapeHtml(s) {
  return String(s).replace(/[&<>"']/g, c =>
    ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}

pushRows.forEach(wireCombo);

/* Balance effect of everything already sent or hand-ticked, so the modal can
   say what will still be outstanding afterwards. */
function closedSoFar() {
  return boxes.reduce((acc, box) => {
    const entry = box.closest('.entry');
    if (entry.hidden) return acc;
    const sendable = entry.dataset.pushable === '1';
    const handled = sendable ? entry.dataset.sent === '1' : box.checked;
    return handled ? acc + Number(box.dataset.delta || 0) : acc;
  }, 0);
}

/* ---- what is ticked and ready ---------------------------------------- */
function selected() {
  return pushRows.filter(row => {
    const box = row.querySelector('input[type=checkbox]');
    return !row.hidden && !row.dataset.sent && box && box.checked;
  });
}

function describe(row) {
  const cat = CATS.find(c => c.id === row.querySelector('.cat-id').value);
  return {
    up_id: row.dataset.upId,
    paired_with: row.dataset.pushPair || '',
    payee: row.querySelector('.payee-input').value.trim(),
    category_id: cat ? cat.id : '',
    category_name: cat ? cat.name : '',
    date: row.dataset.pushDate,
    cents: Number(row.dataset.pushCents || 0),
  };
}

function refreshSend() {
  const btn = document.getElementById('send');
  if (!btn) return;
  const picked = selected();
  btn.hidden = picked.length === 0;
  btn.textContent = 'Send ' + picked.length + ' to YNAB';
  const ready = picked.filter(r => r.querySelector('.cat-id').value);
  btn.disabled = picked.length === 0 || ready.length !== picked.length;
  btn.title = btn.disabled && picked.length
    ? (picked.length - ready.length) + ' of these still need a category'
    : '';
}

/* ---- modal ----------------------------------------------------------- */
const modal = document.getElementById('modal');

function openModal() {
  const rows = selected().map(describe);
  const body = document.querySelector('#review tbody');
  body.innerHTML = rows.map(r =>
    `<tr><td>${escapeHtml(r.date)}</td><td>${escapeHtml(r.payee)}</td>` +
    `<td>${escapeHtml(r.category_name)}</td>` +
    `<td class="num">${plain.format(r.cents / 100)}</td></tr>`).join('');
  const total = rows.reduce((a, r) => a + r.cents, 0);
  document.getElementById('review-total').textContent = fmt.format(total / 100);

  /* What the reconciliation still won't account for once this push lands.
     Every row's amount is also its effect on the balance, so the remainder is
     just the gap less what is already sent and what is about to be. */
  const gapEl = document.getElementById('progress-gap');
  const gap = gapEl ? Number(gapEl.dataset.gap || 0) : 0;
  const after = gap - closedSoFar() - total;
  const afterEl = document.getElementById('review-after');
  afterEl.textContent = after === 0 ? 'nothing — Up and YNAB will agree' : fmt.format(after / 100);
  afterEl.classList.toggle('settled', after === 0);

  document.getElementById('modal-lede').textContent =
    rows.length + (rows.length === 1 ? ' transaction' : ' transactions')
    + '. Every one will carry the memo "Pushed by localhost script".';
  document.getElementById('modal-error').hidden = true;
  document.getElementById('modal-confirm').disabled = false;
  document.getElementById('modal-confirm').textContent = 'Send';
  modal.hidden = false;
}

function closeModal() { modal.hidden = true; }

async function confirmSend() {
  const confirm = document.getElementById('modal-confirm');
  const errorEl = document.getElementById('modal-error');
  const rows = selected();
  confirm.disabled = true;
  confirm.textContent = 'Sending…';
  errorEl.hidden = true;

  try {
    const resp = await fetch('/push', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'X-Push-Secret': PUSH_SECRET },
      body: JSON.stringify({ selections: rows.map(describe) }),
    });
    const data = await resp.json();
    if (!resp.ok) throw new Error(data.error || ('HTTP ' + resp.status));

    if (!data.dry_run) {
      /* Lock what went through: without an import_id YNAB would happily
         create a second copy, so a sent row must not be sendable again. */
      rows.forEach(row => {
        row.dataset.sent = '1';
        const box = row.querySelector('input[type=checkbox]');
        box.checked = false;
        box.disabled = true;
        row.querySelectorAll('.fields input').forEach(i => { i.disabled = true; });
      });
    }
    closeModal();
    const gapEl = document.getElementById('progress-gap');
    if (gapEl) gapEl.dataset.note = data.message || '';
    refreshSend();
    paint();
    announce(data.message || 'Done.');
  } catch (err) {
    errorEl.textContent = err.message;
    errorEl.hidden = false;
    confirm.disabled = false;
    confirm.textContent = 'Send';
  }
}

function announce(text) {
  const el = document.getElementById('progress-label');
  if (!el) return;
  const was = el.textContent;
  el.textContent = text;
  setTimeout(() => { paint(); }, 4000);
}

document.getElementById('send')?.addEventListener('click', openModal);
document.getElementById('modal-cancel')?.addEventListener('click', closeModal);
document.getElementById('modal-confirm')?.addEventListener('click', confirmSend);
modal?.addEventListener('click', e => { if (e.target === modal) closeModal(); });
document.addEventListener('keydown', e => {
  if (e.key === 'Escape' && modal && !modal.hidden) closeModal();
});

refreshSend();

refreshAll();

document.querySelectorAll('.copy').forEach(btn => {
  btn.addEventListener('click', async () => {
    const text = btn.dataset.copy;
    const original = btn.textContent;
    try {
      await navigator.clipboard.writeText(text);
    } catch (e) {
      const ta = document.createElement('textarea');
      ta.value = text;
      document.body.appendChild(ta);
      ta.select();
      document.execCommand('copy');
      ta.remove();
    }
    btn.textContent = 'Copied';
    setTimeout(() => { btn.textContent = original; }, 1200);
  });
});

/* Ticks only. Split selections live in a separate store and are untouched,
   so clearing your progress never rearranges the list. */
document.getElementById('reset')?.addEventListener('click', () => {
  done.clear();
  save(STORE, []);
  boxes.forEach(b => { b.checked = false; });
  paint();
});
"""


def fmt_day(d: date, month: str = "%b") -> str:
    """Day without a leading zero. `%-d` is glibc-only, so build it by hand."""
    return f"{d.day} {d.strftime(month)}"


def esc(value) -> str:
    return html.escape(str(value or ""), quote=True)


def push_fields(up_id: str, payee: str, category_id: str, sent: bool) -> str:
    """
    The two controls on a sendable row.

    Payee is a plain input backed by a shared datalist: typing filters your
    existing payees, and whatever is left in the box is what gets sent, chosen
    from the list or not. Category is a custom combobox rather than a datalist,
    because a datalist would let arbitrary text through and a category has to
    resolve to a real id - the hidden field holds it, and typing clears it.
    """
    lock = " disabled" if sent else ""
    return f"""<div class="fields">
  <label class="field">
    <span>Payee</span>
    <input class="payee-input" list="payee-names" value="{esc(payee)}"
           autocomplete="off" spellcheck="false"{lock}>
  </label>
  <label class="field combo">
    <span>Category</span>
    <input class="cat-input" placeholder="Type to filter…" autocomplete="off"
           role="combobox" aria-expanded="false" aria-autocomplete="list"{lock}>
    <input type="hidden" class="cat-id" value="{esc(category_id)}">
    <ul class="cat-menu" role="listbox" hidden></ul>
  </label>
</div>"""


def entry_row(key: str, day: date, payee: str, amount: str, delta_cents: int,
              note: str = "", tag: str = "", copy_text: str = "",
              up_id: str = "", hidden: bool = False,
              pushable: bool = False, push_payee: str = "", push_category: str = "",
              push_date: str = "", push_cents: int = 0, push_cleared: str = "cleared",
              push_pair: str = "", sent: bool = False) -> str:
    tag_html = f'<span class="tag {tag[0]}">{esc(tag[1])}</span>' if tag else ""
    note_html = f'<p class="note">{note}</p>' if note else ""
    # Pointless once the row can be sent from here; it only earns its place
    # in the read-only report, where entering by hand is the whole point.
    copy_html = (
        f'<button class="copy" data-copy="{esc(copy_text)}">Copy for YNAB</button>'
        if copy_text and not pushable else ""
    )
    attrs = f' data-up-id="{esc(up_id)}"' if up_id else ""
    if hidden:
        attrs += ' hidden'
    fields = ""
    if pushable:
        attrs += (
            f' data-pushable="1" data-push-date="{esc(push_date)}"'
            f' data-push-cents="{push_cents}" data-push-cleared="{esc(push_cleared)}"'
            f' data-push-pair="{esc(push_pair)}"'
        )
        if sent:
            attrs += ' data-sent="1"'
        fields = push_fields(up_id, push_payee, push_category, sent)
    label = "Include in this push" if pushable else "Mark done"
    return f"""<div class="entry"{attrs}>
  <input type="checkbox" data-key="{esc(key)}" data-delta="{delta_cents}"
         aria-label="{label}"{' disabled' if sent else ''}>
  <span class="date">{fmt_day(day)}</span>
  <span class="payee">{esc(payee)}{tag_html}</span>
  <span class="amount">{esc(amount)}</span>
  {note_html}
  {copy_html}
  {fields}
</div>"""


def money(cents: int) -> str:
    """Signed dollars, with the sign always shown so a subtotal reads clearly."""
    return f"{cents / 100:+,.2f}"


def render(
    adds: list[Txn],
    amends: list[tuple[Txn, Txn]],
    blocks: list[dict],
    claimed: set[str],
    queries: list[Txn],
    matched: list[tuple[Txn, Txn, int]],
    splits: list[tuple[Txn, Txn, Txn]],
    cancelled: list[tuple[Txn, Txn]],
    up: list[Txn],
    ynab: list[Txn],
    since: date,
    tolerance: int,
    partners: list[str],
    categories: list[dict],
    payees: list[str],
    renames: dict[str, str],
    cat_memory: dict[str, str],
    pushed: dict[str, str],
    serve: bool,
    dry_run: bool,
    held_status: str,
) -> str:
    in_block = {b["deposit"].uid for b in blocks}
    visible_adds = [t for t in adds if t.uid not in claimed and t.uid not in in_block]
    pushable = serve and bool(categories)
    action_count = len(visible_adds) + len(amends) + len(blocks) + len(queries)
    up_last = max((t.day for t in up), default=since)
    ynab_last = max((t.day for t in ynab), default=since)

    # How far the YNAB balance moves once the list is worked through. Each
    # action carries its own delta, and they sum to exactly the difference
    # between the two accounts - adding what is missing, correcting what is
    # wrong, and removing what has nothing behind it leaves YNAB agreeing with
    # Up to the cent. If this identity ever breaks, the matcher has a bug.
    up_total = sum(t.cents for t in up)
    ynab_total = sum(t.cents for t in ynab)
    gap = up_total - ynab_total
    add_total = sum(t.cents for t in visible_adds)
    amend_total = sum(u.cents - y.cents for y, u in amends)
    share_total = sum(
        b["chosen"]["purchase"].cents + b["deposit"].cents for b in blocks if b["chosen"]
    )
    query_total = sum(-t.cents for t in queries)
    if add_total + amend_total + share_total + query_total != gap:
        warn(
            "Action deltas do not sum to the account difference "
            f"({(add_total + amend_total + share_total + query_total) / 100:+,.2f} "
            f"vs {gap / 100:+,.2f})."
        )

    # ---- headline ---------------------------------------------------------
    if action_count == 0:
        headline = "Up and YNAB agree."
    else:
        noun = "entry" if action_count == 1 else "entries"
        headline = f"{action_count} {noun} to fix in YNAB."

    # ---- add --------------------------------------------------------------
    # A repayment with a shortlist is represented by its block and must not
    # also appear here, or the same transaction is listed twice.
    in_a_block = {b["deposit"].uid for b in blocks}
    add_rows = []
    for t in sorted(adds, key=lambda t: (t.day, t.cents)):
        if t.uid in in_a_block:
            continue
        hidden = t.uid in claimed
        bits = [b for b in (t.extra["type"], t.extra["category"].replace("-", " ")) if b]
        note = esc(" · ".join(bits)) if bits else ""
        if t.extra["raw_text"] and t.extra["raw_text"] != t.label:
            note += f'{" — " if note else ""}{esc(t.extra["raw_text"])}'
        # An unpaired repayment is worth calling out: it is almost certainly a
        # share of something, just not one that halves cleanly, so the pairing
        # is left to you rather than guessed at.
        if t.cents > 0 and is_partner(t, partners) and partners:
            note = (
                f'Money back from {esc(t.label)} that I could not tie to a purchase — '
                "likely an uneven split, or the purchase falls outside this period"
            )
        tag = (
            ("held", f"pending · {held_status}") if t.status == "HELD"
            else (("in", "money in") if t.cents > 0 else "")
        )
        add_rows.append(
            entry_row(
                key=f"add:{t.uid}",
                day=t.day,
                delta_cents=t.cents,
                up_id=t.uid,
                hidden=hidden,
                pushable=serve and bool(categories),
                push_payee=renames.get(t.label, t.label),
                push_category=cat_memory.get(t.label, ""),
                push_date=t.day.isoformat(),
                push_cents=t.cents,
                push_cleared=held_status if t.status == "HELD" else "cleared",
                sent=t.uid in pushed,
                payee=t.label or "(no description)",
                amount=t.dollars,
                note=note,
                tag=tag,
                copy_text=f"{t.day.isoformat()}\t{t.label}\t{t.dollars}",
            )
        )

    # ---- your share of a settled-up cost ----------------------------------
    # Every shortlist is rendered in full, best first, with the score and the
    # signals behind it, so a ranking can be overruled. Picking a different
    # purchase rewrites the entry and the running total in place.
    share_rows = []
    for b in sorted(blocks, key=lambda b: (b["deposit"].day, -b["deposit"].cents)):
        d = b["deposit"]
        chosen = b["chosen"]
        options = []
        for c in b["candidates"]:
            p = c["purchase"]
            selected = " checked" if chosen is c else ""
            joint = ' <span class="joint">joint best</span>' if c.get("joint") else ""
            options.append(f"""<li>
  <label class="option">
    <input type="radio" name="split-{esc(d.uid)}" data-purchase="{esc(p.uid)}"
           data-share="{p.cents + d.cents}" data-payee="{esc(p.label)}"
           data-date="{esc(p.day.isoformat())}"{selected}>
    <span class="score" style="--fill:{c['score']}%">{c['score']}</span>
    <span class="cand">
      <b>{esc(p.label or '(no description)')}</b> {esc(p.abs_dollars)} on {fmt_day(p.day)}
      → your share {esc(f"{c['share'] / 100:,.2f}")}
    </span>
    <span class="why">{esc(', '.join(c['reasons']) or 'amount and date only')}{joint}</span>
  </label>
</li>""")
        options.append(f"""<li>
  <label class="option">
    <input type="radio" name="split-{esc(d.uid)}" data-purchase=""
           data-share="0"{"" if chosen else " checked"}>
    <span class="score none">—</span>
    <span class="cand">Not a split — enter the repayment on its own</span>
  </label>
</li>""")

        share = (chosen["purchase"].cents + d.cents) if chosen else 0
        # With no purchase assigned, the block stands in for the repayment
        # itself - it is still an entry to make, just an income one.
        head = entry_row(
            key=f"share:{d.uid}",
            day=chosen["purchase"].day if chosen else d.day,
            payee=(chosen["purchase"].label or "(no description)") if chosen else d.label,
            amount=f"{share / 100:,.2f}" if chosen else d.dollars,
            delta_cents=share if chosen else d.cents,
            note=(
                f'{esc(d.label)} paid {esc(d.abs_dollars)} back on {fmt_day(d.day)}'
                + f' — full bill {esc(chosen["purchase"].abs_dollars)}'
                if chosen else
                f'Money back with no purchase assigned — '
                + (
                    f'{len(b["contenders"])} fit equally well, so pick one below'
                    if b["tied"] else
                    'pick one below, or enter it on its own as income'
                )
            ),
            tag=("in", "money in") if not chosen else "",
            copy_text=(
                f'{chosen["purchase"].day.isoformat()}\t{chosen["purchase"].label}\t{share / 100:,.2f}'
                if chosen else
                f'{d.day.isoformat()}\t{d.label}\t{d.dollars}'
            ),
            up_id=chosen["purchase"].uid if chosen else d.uid,
            pushable=serve and bool(categories),
            push_payee=(
                renames.get(chosen["purchase"].label, chosen["purchase"].label)
                if chosen else renames.get(d.label, d.label)
            ),
            push_category=(
                cat_memory.get(chosen["purchase"].label, "") if chosen
                else cat_memory.get(d.label, "")
            ),
            push_date=(chosen["purchase"].day if chosen else d.day).isoformat(),
            push_cents=share if chosen else d.cents,
            push_cleared=(
                held_status
                if chosen and chosen["purchase"].status == "HELD"
                else "cleared"
            ),
            push_pair=d.uid if chosen else "",
            sent=(chosen["purchase"].uid if chosen else d.uid) in pushed,
        )
        share_rows.append(f"""<div class="block" data-deposit="{esc(d.uid)}" data-deposit-delta="{d.cents}"
     data-deposit-label="{esc(d.label)}" data-deposit-date="{esc(d.day.isoformat())}">
  {head}
  <details{"" if chosen else " open"}>
    <summary>{len(b["candidates"])} possible purchase{"s" if len(b["candidates"]) != 1 else ""}{f", {len(b['contenders'])} equally strong" if b["tied"] else ""}</summary>
    <ul class="ranked">{"".join(options)}</ul>
  </details>
</div>""")

    # ---- amend ------------------------------------------------------------
    amend_rows = []
    for y, u in sorted(amends, key=lambda p: (p[0].day, p[0].cents)):
        delta = (u.cents - y.cents) / 100
        note = (
            f'Up has <b>{esc(u.dollars)}</b> for {esc(u.label)} on '
            f'{fmt_day(u.day)} — yours reads <span class="was">{esc(y.dollars)}</span>, '
            f'out by {delta:+,.2f}'
        )
        amend_rows.append(
            entry_row(
                key=f"amend:{y.uid}",
                day=y.day,
                delta_cents=u.cents - y.cents,
                payee=y.label or "(no payee)",
                amount=u.dollars,
                note=note,
                copy_text=u.dollars,
            )
        )

    # ---- query ------------------------------------------------------------
    query_rows = []
    for t in sorted(queries, key=lambda t: (t.day, t.cents)):
        note = "Nothing in Up matches this amount, on this date or within "
        note += f"{tolerance} days either side."
        if t.extra["is_split"]:
            note += " This is a split entry — check its total."
        if t.extra["is_transfer"]:
            note += " Marked as a transfer."
        if t.extra["memo"]:
            note += f' Memo: {esc(t.extra["memo"])}'
        query_rows.append(
            entry_row(
                key=f"query:{t.uid}",
                day=t.day,
                delta_cents=-t.cents,
                payee=t.label or "(no payee)",
                amount=t.dollars,
                note=note,
            )
        )

    def section(cls: str, title: str, lede: str, rows: list[str], empty: str,
                subtotal: int | None = None) -> str:
        meta = ""
        if rows:
            meta = f'<span class="count">{len(rows)}'
            if subtotal is not None:
                meta += f' · {money(subtotal)}'
            meta += "</span>"
        body = "\n".join(rows) if rows else f'<p class="empty">{esc(empty)}</p>'
        return f"""<section class="{cls}">
  <h2>{esc(title)} {meta}</h2>
  <p class="lede">{lede}</p>
  {body}
</section>"""

    # ---- reconciled detail ------------------------------------------------
    matched_rows = "\n".join(
        f"<tr><td>{fmt_day(u.day)}</td><td>{esc(u.label)}</td>"
        f"<td>{esc(y.label)}</td><td class='num'>{esc(u.dollars)}</td>"
        f"<td class='num'>{gap}d</td></tr>"
        for u, y, gap in sorted(matched, key=lambda p: (p[0].day, p[0].cents))
    )
    split_rows = "\n".join(
        f"<tr><td>{fmt_day(y.day)}</td><td>{esc(y.label)}</td>"
        f"<td class='num'>{esc(y.dollars)}</td><td>{esc(p.label)}</td>"
        f"<td class='num'>{esc(p.dollars)}</td>"
        f"<td class='num'>{esc(d.dollars)}</td>"
        f"<td class='num'>{abs(y.cents) / abs(p.cents):.0%}</td></tr>"
        for y, p, d in sorted(splits, key=lambda e: e[0].day)
    )
    cancel_rows = "\n".join(
        f"<tr><td>{fmt_day(p.day)}</td><td>{esc(p.label)}</td>"
        f"<td class='num'>{esc(p.dollars)}</td><td>{esc(d.label)}</td>"
        f"<td>{fmt_day(d.day)}</td>"
        f"<td class='num'>{esc(d.dollars)}</td></tr>"
        for p, d in sorted(cancelled, key=lambda c: c[0].day)
    )

    details = []
    if matched:
        details.append(f"""<details>
  <summary>{len(matched)} matched on amount and date</summary>
  <table><thead><tr><th>Date</th><th>Up</th><th>YNAB payee</th><th class="num">Amount</th><th class="num">Gap</th></tr></thead>
  <tbody>{matched_rows}</tbody></table>
</details>""")
    if splits:
        details.append(f"""<details>
  <summary>{len(splits)} shared costs, already settled up</summary>
  <table><thead><tr><th>Date</th><th>YNAB payee</th><th class="num">Your share</th><th>Up purchase</th><th class="num">Full</th><th class="num">Paid back</th><th class="num">Share</th></tr></thead>
  <tbody>{split_rows}</tbody></table>
</details>""")
    if cancelled:
        details.append(f"""<details>
  <summary>{len(cancelled)} fully repaid, nothing to enter</summary>
  <table><thead><tr><th>Date</th><th>Up purchase</th><th class="num">Amount</th><th>Repaid by</th><th>On</th><th class="num">Amount</th></tr></thead>
  <tbody>{cancel_rows}</tbody></table>
</details>""")

    categories_json = json.dumps(
        [{"group": g["name"], "id": c["id"], "name": c["name"]}
         for g in categories for c in g["categories"]]
    ) if pushable else "[]"

    if pushable:
        mode_note = (
            '<p class="mode dry">Dry run — ticking and sending work, but nothing '
            'will be written to YNAB.</p>' if dry_run else
            '<p class="mode live">Connected to YNAB. Ticked rows can be sent.</p>'
        )
    else:
        mode_note = (
            '<p class="mode">Read-only report — no category or payee fields, and '
            'nothing can be sent from here. Re-run with <code>--serve</code> to '
            'enter these in YNAB.</p>'
        )

    send_bar = (
        '<button class="send" id="send" hidden>Send to YNAB</button>'
        if pushable else ""
    )

    if pushable:
        options = "".join(f'<option value="{esc(n)}">' for n in payees)
        banner = (
            '<p class="dry">Dry run — the send button will not write anything.</p>'
            if dry_run else ""
        )
        push_furniture = f"""<datalist id="payee-names">{options}</datalist>
<div class="modal" id="modal" hidden>
  <div class="sheet" role="dialog" aria-modal="true" aria-labelledby="modal-title">
    <h2 id="modal-title">Send to YNAB</h2>
    {banner}
    <p class="lede" id="modal-lede"></p>
    <div class="sheet-scroll">
      <table class="review" id="review">
        <thead><tr><th>Date</th><th>Payee</th><th>Category</th><th class="num">Amount</th></tr></thead>
        <tbody></tbody>
        <tfoot>
          <tr class="total"><th colspan="3">Your YNAB total moves by</th>
              <td class="num" id="review-total"></td></tr>
          <tr class="after"><th colspan="3">Still to account for after this</th>
              <td class="num" id="review-after"></td></tr>
        </tfoot>
      </table>
    </div>
    <p class="modal-error" id="modal-error" hidden></p>
    <div class="sheet-actions">
      <button class="ghost" id="modal-cancel">Cancel</button>
      <button class="send" id="modal-confirm">Send</button>
    </div>
  </div>
</div>"""
    else:
        push_furniture = ""

    tail_note = ""
    if up_last > ynab_last:
        days = (up_last - ynab_last).days
        tail_note = (
            f' Your last YNAB entry is {fmt_day(ynab_last)}, '
            f'{days} day{"s" if days != 1 else ""} behind Up.'
        )

    return f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>Up · YNAB gap — from {since.isoformat()}</title>
<style>{CSS}</style>
</head>
<body>
<main>
  <h1>{esc(headline)}</h1>
  <p class="window">
    Comparing <b>{len(up)}</b> Up transactions against <b>{len(ynab)}</b> in YNAB,
    from {fmt_day(since, "%B %Y")} to {fmt_day(up_last, "%B")}.
    Matched on amount to the cent, within {tolerance} days either side.{tail_note}
  </p>

  {mode_note}

  <div class="progress">
    <span id="progress-label">0 of {action_count} done</span>
    <span id="progress-gap" data-gap="{gap}"></span>
    <button class="reset" id="reset" hidden
            title="Clears the tickboxes only — your split choices are kept">Unmark all</button>
    {send_bar}
    <div class="progress-rule"><i id="progress-bar" style="width:0%"></i></div>
  </div>

  <table class="balance">
    <tr><th>Up, for this period</th><td class="num">{esc(f"{up_total / 100:,.2f}")}</td></tr>
    <tr><th>YNAB, as it stands</th><td class="num">{esc(f"{ynab_total / 100:,.2f}")}</td></tr>
    <tr class="total"><th>Your total moves by</th><td class="num">{esc(money(gap))}</td></tr>
  </table>

  {section("add", "Enter in YNAB", "In Up, with nothing in YNAB behind it. Dates and amounts come straight from Up; the payee is Up's own description, so rename it to whatever you normally use.", add_rows, "Nothing outstanding.", add_total)}

  {section("share", "Enter your half", "Shared costs already settled up. Up shows the full bill and the money coming back; the figure is what you actually paid, which is the single entry to make. Open a row to see every purchase the repayment could belong to, ranked, and pick a different one if the top guess is wrong.", share_rows, "Nothing outstanding.", share_total)}

  {section("amend", "Correct the amount", "The payee and date line up but the figure does not, which usually means a typo when it went in. The amount shown is Up's.", amend_rows, "Every amount agrees.", amend_total)}

  {section("query", "Check these yourself", "In YNAB with no counterpart in Up. Either it belongs to another account, it covers more than one Up transaction, or it was entered twice. The subtotal assumes you delete them.", query_rows, "Nothing unaccounted for.", query_total)}

  {"".join(details)}

  <footer>
    Generated {fmt_day(datetime.now().date(), "%B %Y")} at {datetime.now().strftime("%H:%M")}.
    Ticks and split choices are saved in this browser only.
  </footer>
</main>
{push_furniture}
<script>window.CATEGORIES = {categories_json};</script>
<script>{JS}</script>
</body>
</html>"""


# ==========================================================================
# Main
# ==========================================================================


def main() -> int:
    ap = argparse.ArgumentParser(description="Reconcile Up Bank against YNAB.")
    ap.add_argument("--since", type=date.fromisoformat, help="start date, YYYY-MM-DD")
    ap.add_argument("--env-file", default=".env", help="path to the env file (default: .env)")
    ap.add_argument("--timezone", default=DEFAULT_TZ, help=f"default: {DEFAULT_TZ}")
    ap.add_argument("--tolerance", type=int, default=7, help="date tolerance in days (default 7)")
    ap.add_argument("--reimbursement-window", type=int, default=14,
                    help="max days between a purchase and its repayment (default 14)")
    ap.add_argument("--amend-tolerance", type=float, default=1.00,
                    help="dollars of difference still treated as a typo (default 1.00)")
    ap.add_argument("--amend-days", type=int, default=3,
                    help="date window for typo detection (default 3)")
    ap.add_argument("--split-with", action="append", default=None, metavar="NAME",
                    help="Up name of someone you split costs with; repeatable "
                         "(default: SPLIT_PARTNERS from the env file)")
    ap.add_argument("--settle-window", type=int, default=30,
                    help="max days between a purchase and a settle-up (default 30)")
    ap.add_argument("--no-splits", action="store_true", help="skip the shared-cost passes")
    ap.add_argument("--from-files", nargs=2, metavar=("UP_JSON", "YNAB_JSON"),
                    help="reconcile saved responses instead of calling the APIs")
    ap.add_argument("-o", "--output", default="ynab_gap.html", help="default: ynab_gap.html")
    ap.add_argument("--save-raw", metavar="DIR", help="also write the raw API responses here")
    ap.add_argument("--open", action="store_true", help="open the report when done")
    ap.add_argument("--serve", action="store_true",
                    help="serve the report locally so it can push to YNAB")
    ap.add_argument("--port", type=int, default=8713, help="port for --serve (default 8713)")
    ap.add_argument("--dry-run", action="store_true",
                    help="with --serve, validate and report but never write to YNAB")
    ap.add_argument("--pushed-log", default=".ynab_pushed.json",
                    help="record of what has been sent (default .ynab_pushed.json)")
    ap.add_argument("--held-status", choices=["uncleared", "cleared"], default="uncleared",
                    help="how to mark Up's HELD (pending) transactions in YNAB "
                         "(default uncleared, since they have not settled at the bank)")
    ap.add_argument("--force", action="store_true",
                    help="allow re-sending transactions listed in the pushed log")
    args = ap.parse_args()

    # ---- gather -----------------------------------------------------------
    categories: list[dict] = []
    payee_names: list[str] = []

    if args.from_files:
        up_path, ynab_path = args.from_files
        with open(up_path) as fh:
            payload = json.load(fh)
            up_raw = payload["data"] if isinstance(payload, dict) else payload
        with open(ynab_path) as fh:
            payload = json.load(fh)
            data = payload.get("data", payload)
            ynab_raw = data["transactions"] if isinstance(data, dict) else data
        since = args.since or min(
            date.fromisoformat(t["date"]) for t in ynab_raw
        )
        env = {}
        print(f"Reading {up_path} and {ynab_path}", file=sys.stderr)
        if args.serve:
            # Saved transactions are fine to reconcile offline, but the
            # category list and the push itself need live credentials.
            cfg = env = load_env(args.env_file)
            token = require(cfg, "YNAB_TOKEN")
            plan = require(cfg, "YNAB_PLAN_ID")
            categories = fetch_categories(token, plan)
            payee_names = fetch_payees(token, plan)
    else:
        cfg = env = load_env(args.env_file)
        since = args.since or ask_since(args.timezone)
        up_raw = fetch_up(
            require(cfg, "UP_TOKEN"),
            up_since_timestamp(since, args.timezone),
            cfg.get("UP_ACCOUNT_ID") or None,
        )
        ynab_raw = fetch_ynab(
            require(cfg, "YNAB_TOKEN"),
            require(cfg, "YNAB_PLAN_ID"),
            require(cfg, "YNAB_ACCOUNT_ID"),
            since,
        )
        if args.serve:
            categories = fetch_categories(
                require(cfg, "YNAB_TOKEN"), require(cfg, "YNAB_PLAN_ID")
            )
            payee_names = fetch_payees(
                require(cfg, "YNAB_TOKEN"), require(cfg, "YNAB_PLAN_ID")
            )
        if args.save_raw:
            os.makedirs(args.save_raw, exist_ok=True)
            stamp = since.isoformat()
            for name, body in (("up", {"data": up_raw}), ("ynab", {"data": {"transactions": ynab_raw}})):
                path = os.path.join(args.save_raw, f"{name}_{stamp}.json")
                with open(path, "w", encoding="utf-8") as fh:
                    json.dump(body, fh, indent=2, ensure_ascii=False)
                print(f"  saved {path}", file=sys.stderr)

    partners = args.split_with or [
        p.strip() for p in (env.get("SPLIT_PARTNERS", "") or "").split(",") if p.strip()
    ]

    if args.serve and not categories:
        raise SystemExit(
            "--serve needs the category list, which means live credentials. "
            "Drop --from-files, or run without --serve to get a read-only report."
        )

    if args.serve and not categories:
        raise SystemExit(
            "--serve needs the live category list. Drop --from-files, or run "
            "without --serve for a read-only report."
        )

    if not partners:
        warn(
            "No SPLIT_PARTNERS set, so any money in could be read as somebody's "
            "share. Naming who you split with makes this far more accurate."
        )

    up = normalise_up(up_raw)
    ynab = normalise_ynab(ynab_raw)
    if not up and not ynab:
        raise SystemExit("Both sides are empty - nothing to reconcile.")

    # ---- reconcile --------------------------------------------------------
    matched, rest_up, rest_ynab = match_exact(up, ynab, args.tolerance)

    splits = []
    if not args.no_splits:
        splits, rest_up, rest_ynab = match_splits(
            rest_up, rest_ynab, args.tolerance, args.reimbursement_window
        )

    # A merchant reversing its own charge is the most certain pairing on the
    # board, so it settles first. Weaker full-repayment pairs - matching only
    # on category - wait until the split shortlists have had their pick, since
    # a repayment that is exactly half of one bill can also be
    # equal-and-opposite to another.
    reversals, rest_up = match_zero_net(
        rest_up, args.reimbursement_window, same_merchant=True
    )

    blocks: list[dict] = []
    claimed: set[str] = set()
    if not args.no_splits:
        blocks, claimed = match_unentered_splits(rest_up, partners, args.settle_window)

    unclaimed = [t for t in rest_up if t.uid not in claimed]
    repaid, unclaimed = match_zero_net(unclaimed, args.reimbursement_window)
    cancelled = reversals + repaid

    # Anything a shortlist has claimed still gets rendered, just hidden, so the
    # picker in the report can bring it back if you choose differently.
    amends, unclaimed, rest_ynab = match_amends(
        unclaimed, rest_ynab, args.amend_days, round(args.amend_tolerance * 100)
    )
    rest_up = unclaimed + [t for t in rest_up if t.uid in claimed]

    # ---- push scaffolding --------------------------------------------------
    renames, cat_memory = learn_from_matches(matched, splits, categories)
    if categories:
        print(f"  learned {len(renames)} payee renames, "
              f"{len(cat_memory)} category defaults", file=sys.stderr)

    pushed = {} if args.force else load_pushed(args.pushed_log)
    if pushed:
        print(f"  {len(pushed)} transaction(s) already pushed previously",
              file=sys.stderr)

    # The server derives amounts and dates from here, never from the browser.
    # Every unmatched Up transaction is listed, not just the ones currently
    # shown: the picker can re-pair a repayment at any time, which changes both
    # which purchase is sendable and what the entry is worth.
    valid_categories = set(category_ids_by_name(categories).values())
    rows: dict[str, dict] = {
        t.uid: {
            "date": t.day.isoformat(),
            "cents": t.cents,
            "payee": renames.get(t.label, t.label),
            "cleared": args.held_status if t.status == "HELD" else "cleared",
            "valid_categories": valid_categories,
        }
        for t in rest_up
    }

    # ---- report -----------------------------------------------------------
    page = render(
        adds=rest_up,
        amends=amends,
        blocks=blocks,
        claimed=claimed,
        queries=rest_ynab,
        matched=matched,
        splits=splits,
        cancelled=cancelled,
        up=up,
        ynab=ynab,
        since=since,
        tolerance=args.tolerance,
        partners=partners,
        categories=categories,
        payees=payee_names,
        renames=renames,
        cat_memory=cat_memory,
        pushed=pushed,
        serve=args.serve,
        dry_run=args.dry_run,
        held_status=args.held_status,
    )
    if not args.serve:
        with open(args.output, "w", encoding="utf-8") as fh:
            fh.write(page)

    print(
        f"\n{len(up)} Up / {len(ynab)} YNAB — "
        f"{len(matched)} matched, {len(splits)} shared, {len(cancelled)} repaid\n"
        f"{len(unclaimed)} to enter, {len(blocks)} shares "
        f"({sum(1 for b in blocks if not b['chosen'])} to choose), "
        f"{len(amends)} to correct, {len(rest_ynab)} to check\n"
        f"-> {'served, not written to disk' if args.serve else os.path.abspath(args.output)}",
        file=sys.stderr,
    )

    if args.serve:
        serve_report(
            page, rows, cfg, args.pushed_log,
            port=args.port, dry_run=args.dry_run, open_browser=args.open,
            force=args.force,
        )
        return 0

    if args.open:
        webbrowser.open(f"file://{os.path.abspath(args.output)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
