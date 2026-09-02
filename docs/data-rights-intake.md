# Data rights intake

The company operates today, so the register in `gov.` is not describing a
greenfield decision — it is describing something that already exists and
has simply never been written down in one place. This file is the
questionnaire that turns "we have access to data" into rows that the
system can actually enforce.

Answer it once per **instrument**, not once per source. One MLS
membership covering three feeds is one instrument. One vendor
subscription is one instrument. A seller emailing you a photo is, awkwardly,
also one instrument.

---

## The five questions

### 1. What is the paper?

What actually grants the access — a signed agreement, a paid subscription,
a login somebody was given, a handshake? Record it honestly. `instrument`
accepts `none`, and `none` is a legitimate and useful answer: it records
that data is held under nothing, which is a finding rather than a blank.

| Answer | `instrument` |
|---|---|
| MLS membership / participation agreement | `mls_participation` |
| IDX display addendum | `idx_addendum` |
| VOW addendum | `vow_addendum` |
| Full broker feed | `broker_feed` |
| Paid API or data subscription | `vendor_subscription` |
| Bought outright | `purchase` |
| County records, assessor, public filings | `public_record` |
| The seller or owner gave it to us | `seller_submission` / `owner_consent` |
| Nothing — we just have it | `none` |

### 2. Where does it apply?

Not "where do we operate" — where does *this instrument* apply. An MLS
covers its own footprint and nothing beyond it, and the most common
licensing breach in this industry is using a feed one county over from
where it was licensed.

State-level is enough for most vendor subscriptions (`US-OH`). An MLS
usually needs a market territory with its member towns listed
(`gov.territory_place`).

### 3. What may we do with it?

Answer all eight. `unclear` is a real answer and is treated as *no*.

| Use | The question to ask |
|---|---|
| `internal_analysis` | Can staff underwrite on it? |
| `gated_display` | Can we show it to a registered, signed-in user? |
| `public_display` | Can we show it to an anonymous visitor? — usually narrower |
| `derive` | Can we publish figures computed from it (cap rate, NOI)? |
| `redistribute` | Can we pass it to a third party or another portal? |
| `export` | Can we hand a customer a file? |
| `marketing` | Can we build campaign audiences or ad content from it? |
| `model_training` | Can we train or fine-tune a model on it? |

The last one is increasingly an explicit clause and is almost never
granted by default. If the agreement is silent, the answer is `unclear`,
not `granted`.

### 4. What do we owe in return?

The obligations that have deadlines are the ones worth transcribing,
because the system can then compute them:

- **`attribution`** — exact required wording, if specified
- **`refresh_interval`** — how often the feed must be re-pulled (`interval_hours`)
- **`removal_sla`** — how long after a delisting before it must be off display (`interval_hours`)
- **`retention_limit`** — how long we may keep it
- **`deletion_on_termination`** — must it all be destroyed if the agreement ends?
- **`commingling_restriction`** — may it be shown alongside other sources?

`removal_sla` and `refresh_interval` are the two that `gov.removal_due`
and the nightly sweep act on directly. The rest are recorded for people.

### 5. When does it run out?

`effective_to`, and whether the right `survives_termination`. Most feed
licences do not survive: ending the agreement obliges deletion. That is
the clause most often discovered late, and it is the reason the field
exists.

---

## Recording it

```bash
node worker/tools/record-data-right.js my-right.json
# then, once a lawyer has actually read it:
node worker/tools/record-data-right.js my-right.json --confirm "J. Smith, counsel"
```

A right is **`unreviewed` until someone is named**, and `gov.may_use()`
only honours confirmed rights. The tool will not let a JSON file mark
itself confirmed — "somebody set a flag" and "a lawyer read the contract"
must not look the same afterwards.

## Worked example

```json
{
  "right_id": "MLS-NEOHREX-IDX",
  "name": "NEOHREX IDX display licence",
  "grantor": "Northeast Ohio Real Estate Exchange",
  "instrument": "idx_addendum",
  "source_code": "MLS_RESO",
  "reference": "Participation agreement #12345, IDX addendum signed 2025-03-04",
  "contact": "datalicensing@example.org",
  "effective_from": "2025-03-04",
  "effective_to": "2026-03-03",
  "survives_termination": false,
  "territories": ["MLS-NEOH"],
  "uses": {
    "internal_analysis": true,
    "gated_display": true,
    "public_display": { "posture": "granted", "condition": "with listing broker attribution" },
    "derive": { "posture": "granted", "condition": "derived figures only, not raw ListPrice history" },
    "redistribute": false,
    "export": false,
    "marketing": "unclear",
    "model_training": false
  },
  "obligations": [
    { "kind": "attribution", "text_required": "Listing courtesy of {ListOfficeName}",
      "detail": "Must appear on every listing display", "enforcement": "procedural" },
    { "kind": "refresh_interval", "interval_hours": 12,
      "detail": "Feed must be re-pulled at least twice daily", "enforcement": "automatic" },
    { "kind": "removal_sla", "interval_hours": 24,
      "detail": "Delisted properties off display within 24 hours", "enforcement": "automatic" },
    { "kind": "deletion_on_termination",
      "detail": "All feed data destroyed within 30 days of termination", "enforcement": "procedural" }
  ],
  "covers_listing_refs": ["SDI-1042", "SDI-1014"],
  "scopes": ["listing_facts", "media"]
}
```

---

## Where you stand right now

```sql
SELECT * FROM api.governance_status;      -- the summary
SELECT * FROM gov.uncovered_publication;  -- published with no confirmed right
SELECT * FROM api.compliance_register;    -- the regimes, and which have no control
SELECT * FROM api.data_rights;            -- per property, what is held and why it does or does not apply
```

Governance ships in **advisory** mode: nothing is blocked, and every gap
is reported. Flipping it is the go-live gate, and after that the standing
invariant keeps it flipped:

```sql
UPDATE gov.policy SET enforcement_mode = 'blocking',
       changed_by = 'your name', changed_at = now();
```

Do that only when `gov.uncovered_publication` is empty, or publishing will
start failing.
