# API contract

Everything the app sends and receives. Both APIs are called directly from the
device.

---

## Up Bank

Base `https://api.up.com.au/api/v1`, bearer token, JSON:API shaped.

### Fetching transactions

```
GET /transactions?page[size]=100&filter[since]=2026-09-01T00:00:00+10:00
GET /accounts/{accountId}/transactions?...        # when scoped to one account
```

`filter[since]` is a **full ISO-8601 timestamp with an offset**, not a date.
Derive the offset from the user's time zone *for that specific date* — Melbourne
is `+10:00` in winter and `+11:00` under daylight saving, and a hardcoded offset
silently gains or loses an hour of transactions at the boundary.

Percent-encode the parameters. The `+` in an offset must become `%2B` or the
API reads it as a space.

**Pagination:** follow `links.next` until it is null. Page size maxes at 100.
Accumulate across pages and **de-duplicate by `id`** — cursor pagination should
not repeat, but a HELD transaction settling mid-run can shift position.

`filter[until]`, `filter[status]`, `filter[category]` and `filter[tag]` exist
and are optional.

### Response shape

```jsonc
{
  "data": [{
    "type": "transactions",
    "id": "8f4e...",                          // UUID, always 36 chars
    "attributes": {
      "status": "SETTLED",                    // or "HELD"
      "description": "Merchant 12",           // the payee as Up sees it
      "rawText": "MERCHANT 12 AU",            // card-network string, nullable
      "message": null,
      "amount": {
        "currencyCode": "AUD",
        "value": "-41.50",
        "valueInBaseUnits": -4150             // cents — use this one
      },
      "foreignAmount": null,
      "cardPurchaseMethod": { "method": "CARD_ON_FILE", "cardNumberSuffix": "0000" },
      "settledAt": "2026-09-14T12:00:00+10:00", // null while HELD; unused
      "createdAt": "2026-09-14T09:00:00+10:00", // the matching date
      "transactionType": "Purchase",          // "Deposit", "Refund", "Pay Anyone",
                                              // "Payment", "BPAY Payment", or null
      "note": null,
      "performingCustomer": { "displayName": "..." }
    },
    "relationships": {
      "account":        { "data": { "type": "accounts",   "id": "..." } },
      "transferAccount":{ "data": null },
      "category":       { "data": { "type": "categories", "id": "restaurants-and-cafes" } },
      "parentCategory": { "data": { "type": "categories", "id": "good-life" } },
      "tags":           { "data": [] }
    }
  }],
  "links": { "prev": null, "next": "https://api.up.com.au/api/v1/transactions?page[after]=..." }
}
```

`category` and `parentCategory` data are **nullable** — plenty of transactions
are uncategorised. The ids are Up's public taxonomy, shared across all users.

`transactionType` is nullable; treat a missing value as ordinary.

Token format is `up:yeah:…`. `GET /util/ping` validates one cheaply.

---

## YNAB

Base `https://api.ynab.com/v1`, bearer token. **200 requests per hour per
token** — cache aggressively.

YNAB renamed every `budget_id` to `plan_id`; `/plans/` is current and
`/budgets/` still answers. Prefer `/plans/` and fall back on a 404.

### Fetching transactions

```
GET /plans/{planId}/accounts/{accountId}/transactions?since_date=2026-09-01
```

`since_date` is a plain date, inclusive, open-ended. `until_date` bounds the
other end. **This endpoint does not paginate** — one response is everything.

Do **not** send `last_knowledge_of_server` unless implementing delta sync: it
switches the endpoint to returning only what changed, which looks exactly like
an incomplete result.

**Pending transactions are excluded** from this endpoint. Irrelevant for a
hand-entered account, but worth knowing.

```jsonc
{ "data": { "transactions": [{
    "id": "...", "date": "2026-09-14",
    "amount": -41500,                          // MILLIUNITS: ÷10 for cents
    "memo": null,
    "cleared": "cleared",                      // "uncleared" | "cleared" | "reconciled"
    "approved": true,
    "account_id": "...", "account_name": "Up",
    "payee_id": "...", "payee_name": "Payee 07",
    "category_id": "...", "category_name": "Category 03",
    "transfer_account_id": null,
    "deleted": false,
    "subtransactions": []
  }], "server_knowledge": 1926 } }
```

### Categories, for the picker

```
GET /plans/{planId}/categories
```

Returns `data.category_groups`, each with nested `categories`. Filter out any
group or category where `internal`, `hidden` or `deleted` is true. The
`internal` flag is what removes "Inflow: Ready to Assign" and the Credit Card
Payments group without matching on names. Deleted categories appear only in
delta requests.

### Payees, for the type-ahead

```
GET /plans/{planId}/payees
```

Drop entries with `deleted: true` or a non-null `transfer_account_id`.

### Creating transactions

```
POST /plans/{planId}/transactions
```

Body `{ "transactions": [ … ] }` creates many in one request; `{ "transaction": … }`
creates one. Prefer the array — it is a single call against a tight rate limit.

```jsonc
{
  "account_id": "...",
  "date": "2026-09-14",          // Up's LOCAL createdAt date; future dates rejected
  "amount": -41500,              // cents × 10
  "payee_name": "Payee 07",      // max 200 chars; payee_id takes precedence if both
  "category_id": "...",
  "memo": "Pushed by mobile app",// max 500 chars
  "cleared": "cleared",
  "approved": true               // REQUIRED: omitted means unapproved
}
```

**`import_id` is deliberately omitted.** Consequences, both intended:

- Entries are true user-entered transactions, not imported ones.
- The typed payee is exactly what lands. Payee rename rules only fire when
  `import_id` is present.
- **YNAB provides no duplicate protection.** The app's own pushed-log is the
  only thing preventing a re-send creating second copies. See ARCHITECTURE.md.

If `import_id` is ever reintroduced: max 36 chars, unique per account, and an
Up transaction id is exactly 36 characters so it fits with nothing to spare.
YNAB would then also try to match each imported transaction to an existing
user-entered one with the same amount within **10** days — wider than the
default `tolerance` of 7.

Response `data.transaction_ids` lists what was created. With an array body,
`data.duplicate_import_ids` lists any skipped — always empty while `import_id`
is omitted.

### Other useful endpoints

| endpoint | use |
|---|---|
| `GET /user` | validate a token cheaply |
| `GET /plans` | list plans, to pick `planId` during setup |
| `GET /plans/{id}/accounts` | list accounts, to pick `accountId` |
| `PUT /plans/{id}/transactions/{txId}` | update one — for amount corrections |
| `PATCH /plans/{id}/transactions` | update many |

---

## Errors worth handling distinctly

| status | meaning | response |
|---|---|---|
| 401, 403 | token invalid or revoked | send the user to settings; do not retry |
| 404 | wrong plan or account id | on `/plans/`, retry once against `/budgets/` |
| 429 | rate limited | honour `Retry-After`; otherwise exponential backoff |
| 5xx | transient | retry with backoff, up to 5 attempts |

A 4xx other than 429 will not fix itself — fail loudly rather than retrying.

Never log a token, and never write one into an error message shown to the user.
