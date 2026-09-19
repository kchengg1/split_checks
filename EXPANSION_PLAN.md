# Settled → full shared-expense tracking: Expansion Plan

This document plans the expansion of Settled from "split one receipt, track a trip"
into a full shared-expense app: friends, groups, rich expenses,
per-currency balances, recorded reimbursements, an activity feed, reports, and
device-to-device collaboration — while keeping the two things that make this app
different: **on-device receipt scanning** and **no accounts, no server**.

It builds on what already exists (see [PLAN.md](PLAN.md), milestones 1–4, plus the
Trips mode added afterwards). Nothing here requires throwing away the current engine;
every milestone extends `SettledCore` first and the UI second.

---

## 0. Where we are today

| Layer | What exists | Gap vs. a full expense-sharing app |
|---|---|---|
| Money & math | Integer cents, `SplitEngine.apportion` (largest remainder, fuzz-tested) | Fine as-is. Reused everywhere below. |
| Receipt flow | Scan → items → people → assign → tip/tax → summary → share → history | Result is a dead end: it can't become a trip expense. |
| Trips | `Trip { people, expenses }`, `Expense { payer, amount, split }`, four split methods, net balances, greedy minimum-transfer settle-up | Single payer per expense; one currency per trip; no way to *record* that someone paid someone back; no edit/undo; no categories, notes, or receipt photos. |
| People | `Person` is a value embedded in each bill/trip with a fresh UUID | The same friend in three trips is three unrelated people. No "friends" view, no cross-group balance, no concept of *me*. |
| Persistence | SwiftData rows holding a JSON blob of the whole `Trip`/`BillSnapshot` plus denormalized list fields | Good foundation for sync (whole-value, Codable, deterministic recompute). Needs a schema version and a people directory. |
| Sharing | Plain-text summary via share sheet | No collaboration; the treasurer's phone is the only source of truth. |

The one-sentence gap: **the app models "who owes what for this bill/trip" but not "who
is who across time, who has paid whom back, and who else can see it".**

---

## 1. Product scope: what "full expense sharing" means here

Feature inventory, grouped by how people think about shared expenses. ✅ exists, 🔶 partial, ⬜ new.

**People**
- ⬜ *Me* — a designated person so the UI can say "you owe Sam $12" instead of "Alex owes Sam".
- ⬜ Friends directory — persistent people reused across groups, with optional payment handles (Venmo, PayPal, Zelle, phone).
- ⬜ Friend balance — net position with one friend summed across every group, per currency.

**Groups** (the generalization of today's Trip)
- 🔶 Groups with a kind: trip, home, couple, event, other. Kind only changes iconography and defaults.
- ✅ Members, expenses, per-group balances, minimized settle-up.
- ⬜ "Simplify debts" as a per-group toggle (default *off*: show pairwise debts as incurred).
- ⬜ Archive / leave-group semantics; "Non-group expenses" pseudo-group for one-off splits.

**Expenses**
- ✅ Equal, shares, percentages, exact-amount splits.
- ⬜ Adjustment split ("everyone equal, but Sam +$5 for the extra drink").
- ⬜ **Itemized split from a scanned receipt** — the bridge between the two halves of the app, and the feature no competitor does on-device.
- ⬜ Multiple payers on one expense.
- ⬜ Currency per expense; balances kept per currency.
- ⬜ Category, notes, date, receipt photo attachment.
- ⬜ Edit, soft delete, restore; edit history.
- ⬜ Recurring expenses (rent, subscriptions) materialized locally.
- ⬜ Comments on an expense (local-only until collaboration lands).

**Reimbursement / settling**
- ✅ Suggested minimum transfers.
- ⬜ **Record a payment** (full or partial) so balances actually go down.
- ⬜ Payment method + deep link handoff to Venmo / PayPal / Cash App (we never move money).
- ⬜ "Settle all" for a friend or a group in one tap.
- ⬜ Reminders (local notifications) for outstanding balances and recurring expenses.
- ⬜ Reports: per-person reimbursement statement (PDF) and group CSV export — useful for work trips.

**Activity**
- ⬜ Chronological feed across groups: expense added/edited/deleted, payment recorded, member joined.

**Collaboration** (see §6 — the only place the "no server" constraint bites)
- 🔶 Share text summary.
- ⬜ Export/import a group as a file (AirDrop, Messages) with conflict-free merge.
- ⬜ Live shared groups via iCloud (CloudKit `CKShare`) — no server of ours, still no account of ours.

**Explicit non-goals** (unchanged from PLAN.md): no backend we run, no login, no in-app money
movement, no ads/analytics.

---

## 2. Domain model v2 (`SettledCore`)

Design rules carried forward: value types, `Codable`, `Sendable`, integer cents, engine is
pure and deterministic, a group is a self-contained document.

### 2.1 Identity: `Person` becomes global, plus `Me`

`Person` keeps its shape, but IDs become *stable across groups*. The app gains a
people directory; when you add "Sam" to a second group you pick the existing Sam.

```swift
public struct Person: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public var name: String
    public var colorIndex: Int
    public var handles: PaymentHandles = .init()   // new, all optional
}

public struct PaymentHandles: Hashable, Codable, Sendable {
    public var venmo: String?, paypal: String?, cashApp: String?, zelle: String?, phone: String?
}

/// Stored once per device. `meID` lets every screen say "you".
public struct Profile: Codable, Sendable { public var meID: Person.ID? }
```

A group still *embeds* its members (`people: [Person]`) so the document stays
self-contained for export and sync; the directory is the app-side index that keeps the
IDs consistent. Name changes propagate from the directory to embedded copies on save.

### 2.2 `Group` (generalized `Trip`) as a ledger

```swift
public enum GroupKind: String, Codable, Sendable, CaseIterable { case trip, home, couple, event, other }

public struct Group: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public var name: String
    public var kind: GroupKind
    public var defaultCurrencyCode: String
    public var simplifyDebts: Bool          // default: false
    public var people: [Person]
    public var entries: [LedgerEntry]       // replaces `expenses`
    public var activity: [ActivityEvent]    // append-only audit trail
    public var createdAt: Date
    public var schemaVersion: Int           // for forward-compatible decoding
}

public enum LedgerEntry: Identifiable, Hashable, Codable, Sendable {
    case expense(Expense)
    case payment(Payment)
}
```

`Trip` stays as `public typealias Trip = Group` during migration so existing code and
tests compile; the on-disk `SavedTrip` row is kept and its JSON decoder fills the new
fields with defaults (`kind: .trip`, `simplifyDebts: false`, `entries` from `expenses`).

### 2.3 `Expense` v2

```swift
public struct Expense: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public var title: String
    public var amountCents: Int
    public var currencyCode: String
    public var date: Date
    public var payers: [Person.ID: Int]     // sums to amountCents; single payer = one entry
    public var split: SplitMethod
    public var category: ExpenseCategory
    public var notes: String
    public var receiptImageID: UUID?        // image file stored outside the blob (§5)
    public var itemizedBill: BillSnapshot?  // present when built from a scanned receipt
    public var recurrence: RecurrenceRule?
    public var isDeleted: Bool
    public var createdAt: Date, updatedAt: Date
}

public enum SplitMethod: Hashable, Codable, Sendable {
    case equally(participantIDs: [Person.ID])
    case shares([Person.ID: Int])
    case percentages([Person.ID: Int])          // basis points
    case exactCents([Person.ID: Int])
    case adjustment(participantIDs: [Person.ID], adjustments: [Person.ID: Int])  // new
}
```

- **Adjustment** resolves as: each participant gets their adjustment, the remainder
  (`amount − Σadjustments`) is apportioned equally. Negative remainders are a validation error.
- **Itemized** is *not* a fifth split method: an itemized expense stores
  `split = .exactCents(perPersonTotals)` (so the engine needs nothing new) plus the
  `BillSnapshot` it was derived from, so the UI can reopen and re-edit the receipt and
  regenerate the split. The bill's people are mapped onto group members at import time.
- `payerID` is replaced by `payers`. A compatibility decoder maps old `payerID` →
  `[payerID: amountCents]`.

### 2.4 `Payment` — a reimbursement is a ledger entry

```swift
public struct Payment: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public var fromID: Person.ID, toID: Person.ID
    public var cents: Int
    public var currencyCode: String
    public var date: Date
    public var method: PaymentMethod       // cash, venmo, paypal, cashApp, zelle, bankTransfer, other
    public var note: String
    public var isDeleted: Bool
    public var createdAt: Date, updatedAt: Date
}
```

For balance purposes a payment is exactly "an expense paid by `from`, owed entirely by
`to`", which is how shared-expense ledgers usually model it. Keeping it a distinct type gives the UI
clean copy ("Sam paid you $40 via Venmo") and lets reports separate spend from transfers.

### 2.5 Activity / audit

```swift
public struct ActivityEvent: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public var at: Date
    public var kind: Kind        // entryAdded, entryEdited, entryDeleted, entryRestored, memberAdded, memberRemoved, groupRenamed
    public var entryID: UUID?
    public var actorID: Person.ID?   // `me` on this device; the sharer's `me` on theirs
    public var summary: String       // pre-rendered line for the feed
    public var before: LedgerEntry?  // enables "restore" and edit history without diffs
}
```

Every mutation goes through `Group.apply(_ change:)`, which appends the event and updates
`entries`. This one rule buys: the Activity tab, undo/restore, edit history, and — later —
conflict-free merging (§6), because a group's state is a fold over its events.

### 2.6 Validation

Pure `ExpenseValidator.validate(_:in:) -> [ValidationError]` (payers don't sum to amount;
percentages ≠ 10 000 bp; exact cents ≠ amount; unknown person; negative adjustment
remainder; zero amount). The `Add`/`Edit` sheet shows these inline and disables Save.

---

## 3. Engine v2 (`SettlementEngine` and friends)

All pure, all in the core package, all tested against invariants.

| Function | Purpose | Invariant tested |
|---|---|---|
| `owedShares(for:knownPeople:)` | Extended for `.adjustment`; unchanged otherwise | Shares sum to amount |
| `netContributions(for expense)` | `paid − owed` per person for one entry, multi-payer aware | Sums to zero |
| `balances(for group) -> [Currency: [Balance]]` | Net per person, **per currency**; payments included; deleted entries excluded | Each currency sums to zero |
| `pairwiseDebts(for group) -> [Currency: [Debt]]` | Debts *as incurred*: per entry, debtors → payers matched deterministically; summed over entries; a payment reduces the matching pair | Σ pairwise nets == balances |
| `simplify(_:)` | Existing greedy min-transfer; applied per currency | Transfers clear balances; ≤ n−1 transfers |
| `settlement(for group)` | Chooses pairwise vs. simplified by `group.simplifyDebts` | — |
| `friendBalances(groups:meID:) -> [Person.ID: [Currency: Int]]` | Cross-group net between me and each friend | Equals Σ of per-group pairwise nets involving me |
| `settleAllTransfers(for friend/group)` | The list of payments that would zero things out (feeds "Settle all") | Applying them yields zero balances |
| `materializeRecurring(group, now)` | Emits due instances of recurring expenses; idempotent | No duplicates on repeated runs |

**Multi-currency policy:** balances are *per currency* and never auto-converted (no
network, no rate source, no surprises). An optional manual
`conversion: (toCode, rateBasisPoints)` on an expense lets a user say "this €50 counts as
$54 for the group" at entry time; the engine then treats the expense in the converted
currency. That is the only conversion path.

**Pairwise debt for multi-payer expenses:** compute per-entry `net_i = paid_i − owed_i`,
then match debtors to creditors *within that entry* in people order (deterministic).
Single-payer entries reduce to "each participant owes the payer their share", which is what
users expect to see in the expense detail.

---

## 4. App architecture and UI

### 4.1 Information architecture (groups-first, scanner-first)

```
TabView
├── Groups     — overall "you owe / you are owed" header, then groups by last activity
│    └── Group detail: Expenses | Balances | Totals | Members  (segmented, as today)
│         ├── Expense detail (shares, payers, receipt image, notes, edit history, comments)
│         ├── Settle up sheet
│         └── + Add expense → Manual | Scan receipt | Import photo
├── Friends    — every person in the directory with net balance per currency
│    └── Friend detail: per-group breakdown, shared expenses, Settle up, Remind
├── Activity   — cross-group feed; tap → the entry
└── Settings   — Me (name, handles), default currency, simplify default, export, privacy
```

The existing receipt flow is not removed; it becomes the **Scan receipt** entry point of
"Add expense" and keeps working standalone as **Quick split**, whose result lands in the
implicit *Non-group expenses* group (the usual convention), so history survives as
a group like any other.

### 4.2 The receipt ↔ group bridge (the differentiator)

Two directions, both thin because the engines already agree on `Person.ID` and cents:

1. **Scan from inside a group** — `BillFlowModel` is started with `people` prefilled
   from the group's members. On "Save", instead of only writing `SavedBill`, it creates
   an `Expense` with `payers` (asked on the summary screen: "Who paid the restaurant?"),
   `split = .exactCents(perPersonTotals)`, and `itemizedBill = snapshot`.
2. **Attach a saved bill to a group** — from history or the summary screen: pick a
   group, map bill people → members (auto-matched by name, editable), pick payer(s).

Expense detail for an itemized expense shows the per-person item breakdown (reuse
`SavedBillDetailView`) and an "Edit receipt" action that reopens the bill flow and
regenerates the split on save.

### 4.3 State and persistence in the app target

- `GroupStore` (`@Observable`): loads `SavedGroup` rows, decodes to `Group` values, applies
  changes through `Group.apply`, re-encodes on change (the current
  `.onChange(of: trip) { saved.update(from:) }` pattern, centralized).
- `PeopleDirectory` (`@Observable`): `SavedPerson` rows; `me`; name/handle edits fan out to
  embedded copies.
- Receipt images: JPEG files in `Application Support/receipts/<uuid>.jpg`, referenced by ID.
  Not in the blob (size), not in iCloud unless the group is shared (privacy — receipts
  carry card digits and locations). Deleted with the expense.
- Recurring expenses are materialized on app foreground (`scenePhase == .active`); there is
  no server to do it for us, and the app is where the user would look anyway.

### 4.4 SwiftData schema evolution

Adopt `VersionedSchema` + `SchemaMigrationPlan` now, before the model grows:

- `SchemaV1`: today's `SavedBill`, `SavedTrip`.
- `SchemaV2`: `SavedGroup` (renamed from `SavedTrip`; lightweight migration with a custom
  stage that re-encodes the blob to the v2 JSON), `SavedPerson`, `SavedProfile`;
  `SavedBill` stays and gains `groupID?` for bills that became expenses.
- The JSON blob carries `schemaVersion`; the core package owns decoding of every past
  version (`GroupDecoding.decode(data:)`), with fixture tests for each shipped version.

---

## 5. Reimbursement features in detail

**Settle up sheet** (from a group balance row, a friend, or a suggested transfer):
- Prefilled from/to/amount/currency from the row tapped; editable for partial payments.
- Method picker; if the payee has a handle for that method, a **Pay with Venmo/PayPal**
  button opens a deep link (`venmo://paycharge?txn=pay&recipients=<handle>&amount=<x>&note=<group>`;
  PayPal.me and Cash App URLs likewise) and then records the payment when the user confirms
  "I sent it". We never confirm the transfer ourselves — recorded means "the user said so".
- "Settle all" records every transfer from `settleAllTransfers` at once, each as a payment.

**Reminders:** `UNUserNotificationCenter` local notifications only. "Remind me to settle
with Sam on Friday", "Rent is due on the 1st". Optional, permission asked at first use.

**Reports:**
- Group CSV (date, title, category, currency, amount, paid by, each member's share) —
  what people paste into a spreadsheet.
- Per-person **reimbursement statement** PDF (`ImageRenderer` → PDF): expenses they're owed
  for, with receipt thumbnails when attached, subtotal per currency, and a payment history.
  This is the "expense a work trip" use case.

---

## 6. Collaboration without a server

The honest answer to "how do friends see the same group?" in a no-server app, in three
increasing steps. Each step is independently shippable; none requires the previous UI to change.

**Step A — Share a file.** Export a group as `<name>.settled` (JSON, registered
`UTType`, `Codable` document). Send it by AirDrop or Messages; the recipient's app imports
it. Re-importing a group that already exists **merges** instead of duplicating:

- Entries are keyed by UUID; last `updatedAt` wins per entry; deletions are tombstones
  (`isDeleted`), so a delete on one phone survives a merge with an edit on another.
- `ActivityEvent`s are unioned by ID and re-sorted; the feed shows both people's actions.
- Members are unioned by `Person.ID`; the directory adds anyone new.
- Merge is a pure function in the core package, tested for commutativity and idempotence
  (`merge(a, b) == merge(b, a)`, `merge(a, a) == a`).

This already covers the common case: a treasurer keeps the book and periodically drops the
file in the group chat; anyone can open it, see their balance, and record a payment they
made, then send it back.

**Step B — Live sync through iCloud.** Store each `Group` document as a `CKRecord` in the
owner's private CloudKit database and share it with `CKShare` (Apple's share sheet handles
invitations — participants need an iCloud account, not a Settled account). Because
state is a mergeable document from Step A, conflict resolution is the same `merge`; there
is no schema to design on the server. Receipt images become `CKAsset`s only for shared
groups. Costs: iCloud capability + container (already have a paid developer account for
TestFlight), a privacy-policy update ("if you share a group, its data is stored in your
iCloud"), and Apple's CloudKit sharing UI quirks. This is the recommended end state and
is why the models are whole-value `Codable` today.

**Step C (optional) — In-person sync.** `MultipeerConnectivity` to push the document to
phones at the same table with no network. Same merge; a nice demo; lower priority than B.

---

## 7. Milestones

Each milestone ends green on CI (`swift test` for the core, simulator build for the app)
and shippable to TestFlight. Sizes are rough relative effort.

| # | Milestone | Core package | App | Size |
|---|---|---|---|---|
| 6 | **Foundation: people, groups, ledger** | `Group`/`LedgerEntry`/`Payment`/`ActivityEvent`, `Group.apply`, soft delete, `pairwiseDebts`, `simplifyDebts` toggle, versioned JSON decoding with v1 fixtures | People directory + *Me* onboarding, `SchemaV2` migration, Groups tab (rename Trips), group kind, record-a-payment sheet, edit/delete/restore expense, Activity tab | L |
| 7 | **Rich expenses** | Multi-payer, `.adjustment`, per-currency balances, manual conversion, categories, `ExpenseValidator`, recurring materialization | Add/Edit expense redesign (payers, adjustment, currency, category, notes, receipt photo, recurrence), expense detail, currency-aware balance rows | L |
| 8 | **Receipt ↔ group bridge** | `Expense.itemizedBill`, bill-people → member mapping helper, regenerate-split-on-edit | "Scan receipt" from a group, "Add to group" from summary/history, Quick split → Non-group expenses, itemized expense detail | M |
| 9 | **Friends, settle up, reports** | `friendBalances`, `settleAllTransfers`, CSV writer, statement model | Friends tab + detail, Settle-up sheet with method + deep links, Settle all, reminders, CSV + PDF export, home "you owe / are owed" header | M |
| 10 | **Collaboration A: file share + merge** | `Group.merge`, tombstone semantics, export/import document; commutativity/idempotence tests | `.settled` `UTType`, `FileDocument`/share sheet export, import via `onOpenURL`, merge review ("3 new expenses, 1 payment") | M |
| 11 | **Collaboration B: iCloud shared groups** | — (document already mergeable) | CloudKit container, `CKShare` flow, background fetch + merge, receipt `CKAsset`s, privacy policy + App Privacy answers update | L |
| 12 | **Polish & platform** | Foundation Models receipt parsing (iOS 26+) as a parser strategy | Home/Lock Screen widget ("You owe $42"), App Intents ("Add $20 lunch to Lisbon"), iPad layout, localization pass, updated screenshots + store copy | M |

Suggested order is as numbered: 6 and 7 are pure value once shipped; 8 is small and is the
marketing story; 9 makes reimbursement real; 10 → 11 is the collaboration ladder.

### Milestone 6 in detail (first PR series)

1. Core: add `Payment`, `LedgerEntry`, `ActivityEvent`, `Group` (with `typealias Trip`),
   `Group.apply(_:)`; port `SettlementEngine` to iterate `entries`; add `pairwiseDebts`.
   Tests: existing suite unchanged and passing; new invariant tests; v1 JSON fixture decodes.
2. Core: `Profile`, `Person.handles`.
3. App: `SchemaV2` + migration plan; `SavedGroup`, `SavedPerson`, `SavedProfile`; run the
   migration against a copy of a v1 store in a unit test.
4. App: first-launch "What's your name?" sheet sets *me*; people picker in group members
   and in the receipt flow offers directory people.
5. App: Groups tab (Trips renamed, kind icon), Balances view honoring `simplifyDebts`,
   "Record payment" from any balance/transfer row, Activity tab.
6. App: expense edit sheet reusing `AddExpenseView`; swipe-delete becomes soft delete with
   "Undo"; deleted entries visible in Activity with Restore.
7. Screenshots test updated; store "What's New" copy.

---

## 8. Testing strategy

- **Engine invariants** (XCTest, fuzzed like `apportion` today): balances sum to zero per
  currency; pairwise nets equal balances; transfers clear balances; multi-payer conserves
  money; payments reduce exactly the pair they name; recurring materialization is idempotent.
- **Golden scenarios**: a hand-checked 3-person weekend and a 5-person multi-currency trip,
  asserting exact balances and transfers (extending `SettlementEngineTests`).
- **Decoding fixtures**: one JSON file per shipped schema version, decoded and re-encoded.
- **Merge algebra**: commutativity, idempotence, tombstone-beats-edit, edit-beats-older-edit.
- **Migration**: SwiftData `SchemaV1 → V2` against a fixture store in the app test target.
- **UI**: screenshot test extended to Friends, Activity, Settle up (feeds the store listing).

---

## 9. Decisions (confirmed 2026-09-17)

All six were confirmed as recommended (the bold option in each).

1. **Rename Trips → Groups** in the UI? **Yes**: "Groups" with a kind is what users expect
   and what data imported from other expense apps looks like. Keep the airplane icon for `kind: .trip`.
2. **Simplify debts default**: **off per group** (people want to see "I
   owe Sam because of dinner", not a rearranged transfer), with a one-tap toggle. Today's
   Trips mode always simplifies, so existing groups migrate with `simplifyDebts: true` to
   avoid surprising current users.
3. **Currency conversion**: **manual, per expense, optional**; never fetched.
4. **Receipt images in sync**: **only for shared groups, only if the user attached one**,
   with a warning line in the share flow.
5. **Collaboration endpoint**: **CloudKit sharing** (Step B) as the target; file share
   (Step A) ships first because it is one afternoon of UI once `merge` exists and it works
   for people without iCloud.
6. **`Me` is optional**: without it every screen falls back to today's neutral wording
   ("Alex owes Sam"), so nothing breaks for a user who skips onboarding.

---

### Implementation notes from Milestone 6

- The core type is `ExpenseGroup`, not `Group`, to avoid clashing with SwiftUI's `Group`
  view in the app target. `Trip` remains as a typealias.
- The SwiftData entity keeps its on-disk name `SavedTrip`: renaming an entity is not a
  lightweight migration, so the class stays and only gains defaulted columns. The
  `VersionedSchema` plan in §4.4 is deferred until a change that lightweight migration
  can't absorb; version-awareness lives in the JSON payload (`schemaVersion`) and the core
  package's decoder, which is fixture-tested against the v1 shape.
- *Me* is stored in `UserDefaults` (observed via `@AppStorage`) rather than a SwiftData row.
- The one-time directory backfill dedupes historical people by name and keeps the most
  recent ID; older groups stay internally consistent with their embedded copies.
- Group settle-up for pre-existing trips migrates with `simplifyDebts: true` (decision 2).

### Implementation notes from Milestone 7

- Conversion is an explicit "counts as" amount (`ConvertedAmount`), not a rate: exact,
  and no rounding surprises. Paid and owed shares are scaled to it with the same
  largest-remainder apportionment, so they still sum exactly.
- The engine exposes a `Contribution` per entry (paid, owed, currency); balances,
  pairwise debts, and settlements are per currency via `settlements(for:)`.
- Multi-payer pairwise debts match overpayers to underpayers *within each entry* in
  people order, so a single-payer expense still reads "each participant owes the payer".
- Recurring expenses: the expense carrying the rule is the first occurrence; copies are
  generated by `materializeRecurring` when the app becomes active, linked by
  `recurringSourceID`.
- Payload schema version is 3; version 2 (single `payerID`, no currency) decodes via a
  fixture-tested compatibility path.

### Implementation notes from Milestone 8

- An itemized expense stores its `BillSnapshot` and an `.exactCents` split derived from it
  (`Expense.itemized(from:...)` / `applyItemizedBill`). Diner → member matching is a plain
  ID mapping; with the people directory it is usually the identity.
- The receipt flow is reused as-is: `BillFlowModel` gains a `GroupTarget`, so the same
  screens end in "Add to <group>" (or "Update expense" when re-editing a receipt) instead
  of saving to history.
- The "Non-group expenses" pseudo-group was **not** built: standalone bills stay in History
  and "Add to a group" is one tap from the summary or a saved bill. A bill remembers the
  group it went into (`SavedBill.groupID`).

### Implementation notes from Milestone 9

- Friend balances (`FriendLedger.balances`) follow each group's own settle-up mode, so the
  Friends tab never disagrees with a group's Balances screen; "settle everything" records
  one payment per group and currency in the direction of the debt.
- Payment-app hand-offs are plain URL opens (`venmo://`, `paypal.me`, `cash.app`) with the
  amount prefilled when there is a single currency; nothing is verified, the user records
  the payment afterwards.
- Reminders are local `UNUserNotificationCenter` requests on this phone only.
- Reports: `GroupCSV` (one row per entry, one "owes" column per member) and `Statement`
  (per-person lines and totals) live in the core package; the app renders the statement
  to PDF with `ImageRenderer` and hands both to the system share sheet.

## 10. Risks

| Risk | Mitigation |
|---|---|
| SwiftData migration corrupts a real user's history | Blob-in-a-row storage means the migration is "add columns + re-encode JSON"; test against a fixture v1 store; keep a pre-migration copy of the store file for one launch. |
| Multi-payer / multi-currency make balances hard to read | Show per-currency rows only when more than one currency exists; expense detail always shows "who paid / who owes" lines generated from `netContributions`. |
| CloudKit sharing UX is fiddly and requires iCloud | Ship file-share first; CloudKit is additive. Never require iCloud for local use. |
| Deep links to payment apps change | Handles are optional; every deep link has a "Copy amount" fallback and the payment is recorded manually. |
| Scope creep vs. the app's simplicity promise | Every milestone leaves Quick split (scan → summary → share) two taps from launch. |
