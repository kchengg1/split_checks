# Split Checks — Receipt-Based Bill Splitting App: Project Plan

A friendly iOS app for splitting a dinner bill from a photo of the receipt. Snap the receipt, the app itemizes it, everyone gets assigned their items, and the app tells you who owes what — tax and tip included.

---

## 1. Can this be simple and fully on-device (no cloud)? **Yes.**

This is the most important design decision, and the answer is a confident yes. Everything the app needs ships inside iOS itself:

| Need | On-device solution | Cloud needed? |
|---|---|---|
| Read text from a receipt photo | Apple **Vision framework** (`VNRecognizeTextRequest`, and on iOS 26+ the newer `RecognizeDocumentsRequest` which understands document/table structure) | No |
| Camera + auto document cropping | **VisionKit** `VNDocumentCameraViewController` — the same scanner used by Notes.app; auto-detects edges, de-skews, enhances contrast | No |
| Turning raw text into line items | Deterministic parsing (regex + layout heuristics) written in Swift; optionally Apple's on-device **Foundation Models** framework (iOS 26+) for smarter parsing | No |
| Storing bills and history | **SwiftData** (or Core Data) — local database on the phone | No |
| Sharing the result with friends | iOS **share sheet** (Messages, etc.) with a text/image summary | No |

Consequences of going local-only, all of them good for a simple app:

- **No backend to build, host, or pay for.** The project is one Xcode target.
- **No accounts, no sign-in, no privacy policy headaches.** Receipt photos (which contain restaurant, location, card digits) never leave the phone.
- **Works offline** — in the restaurant basement with no signal, which is exactly where you use it.
- **The trade-off:** no real-time multi-device collaboration (friends can't tap their own items from their own phones). For a v1, one person drives and shares the summary — that's how people actually split checks at the table anyway. If collaboration is ever wanted later, **MultipeerConnectivity / SharePlay** can do device-to-device sync *still without a server*.

Accuracy note: Apple's on-device OCR is very good on printed receipts (it's what powers Live Text). It will occasionally misread a price or merge columns — the plan below treats OCR output as a *draft the user confirms*, not ground truth, which keeps the app robust without any cloud ML.

**Minimum target: iOS 17** (SwiftData, modern SwiftUI). The optional Foundation-Models-assisted parsing is a progressive enhancement gated to iOS 26+ devices; the regex parser is the always-available fallback.

---

## 2. Core user flow

```
Scan → Review items → Add people → Assign → Tip & tax → Summary → Share
```

1. **Scan** — Open to a big friendly "Scan receipt" button. VisionKit document camera auto-captures and crops. Also allow picking an existing photo from the library, and a "skip — enter manually" escape hatch.
2. **Review items** — OCR runs (sub-second), parsed into an editable list of `name — qty — price`. Low-confidence lines are highlighted for a quick glance. User can tap to fix text/price, delete junk lines, add missed ones. A running subtotal vs. the receipt's printed subtotal acts as a built-in checksum ("Items add up ✓").
3. **Add people** — Type names or pick from a locally stored "frequent diners" list. Each person gets a color/avatar chip.
4. **Assign** — The fun screen. Item list with people chips; tap a chip onto an item. Items can be **shared** (split evenly among the tapped people — the tiramisu problem) or given a custom split. Unassigned items stay visually loud so nothing is forgotten.
5. **Tip & tax** — Tax read from the receipt (editable); tip via quick buttons (18/20/25%) or custom amount. Both are **prorated proportionally to each person's subtotal** (the fair way), with an "split evenly" toggle for groups that prefer that.
6. **Summary** — One card per person: their items, their share of tax/tip, total. Rounding is handled so per-person totals sum *exactly* to the bill (largest-remainder method; no lost pennies).
7. **Share** — Share sheet with a clean text breakdown (and optionally a rendered image card) to paste into the group chat. Bill is saved to local history.

---

## 3. Architecture

Single Xcode project, SwiftUI, MVVM-ish with plain observable models. No third-party dependencies required.

```
SplitChecks/
├── App/                    # App entry, navigation (NavigationStack flow)
├── Models/                 # Bill, LineItem, Person, Assignment, Money (SwiftData @Model)
├── Scanning/
│   ├── DocumentScanner     # VisionKit camera wrapper (UIViewControllerRepresentable)
│   └── ReceiptOCR          # Vision text recognition → positioned text lines
├── Parsing/
│   ├── ReceiptParser       # heuristics: line-item vs subtotal/tax/tip/total detection
│   └── SmartParser         # optional iOS 26 FoundationModels enhancement
├── Splitting/
│   └── SplitEngine         # pure functions: assignments + tax/tip → per-person totals
├── Views/                  # Scan, ReviewItems, People, Assign, TipTax, Summary, History
└── Tests/                  # parser fixtures (real receipt texts), SplitEngine math tests
```

Key design rules:

- **`SplitEngine` and `ReceiptParser` are pure, UI-free Swift** — fully unit-testable with fixture receipts. This is where correctness lives.
- **All money is `Decimal` (or integer cents), never `Double`.**
- **Parsing strategy:** Vision gives text *with bounding boxes*. Receipts are columnar — item names left, prices right — so we cluster observations into rows by y-position, then classify each row: price-bearing item line (`.+\s+\$?\d+[.,]\d{2}$`), quantity prefix (`2 x`, `2@`), modifier line (indented, no price → attach to item above), and keyword lines (`SUBTOTAL|TAX|TIP|GRATUITY|TOTAL`) which are captured separately, not treated as items. Confidence below a threshold flags the row for user review.

### Data model (SwiftData)

```
Bill        — date, restaurantName?, receiptImage?, taxCents, tipCents, status
LineItem    — name, quantity, priceCents, ocrConfidence, bill →
Person      — name, colorIndex (reusable across bills)
Assignment  — lineItem →, person →, shareWeight (1 = full/even share)
```

---

## 4. UI principles (the "friendly" part)

- **One decision per screen**, linear flow with a progress feel; back always works without losing state.
- **Big touch targets**: person chips ≥ 44 pt, whole item rows tappable.
- **Assignment is playful**: tap a person chip then tap items ("painting" items with a person), snappy haptics on assign, chip avatars stack on shared items.
- **Trust through transparency**: every computed number can be expanded to show its math ("$4.12 tip = 20% of your $20.60").
- **Errors are shrugs, not walls**: bad OCR line → inline edit, never a modal failure. No receipt at all → manual entry works with the same downstream flow.
- Dynamic Type, VoiceOver labels on chips/items, and dark mode from day one — cheap to do early, painful to retrofit.

---

## 5. Edge cases the SplitEngine must handle (test fixtures for each)

- Shared items among a subset of people, including uneven weights (I ate 2 slices).
- Tax/tip proration with rounding: per-person totals must sum exactly to the grand total (distribute remainder cents deterministically, e.g. largest fractional part).
- Discounts / negative lines (happy hour, comps) — prorate like tax, or attach to a specific item.
- Quantity lines (`3 Margarita  $36.00`) — splittable into 3 unit items for assignment.
- Receipt subtotal ≠ sum of parsed items → surface the mismatch, let the user reconcile.
- Someone paid the whole bill vs. everyone pays the restaurant — v1 assumes one payer and shows "owes payer" amounts.

---

## 6. Milestones

| # | Milestone | Contents | Status |
|---|---|---|---|
| 1 | **Split math core** | Models, SplitEngine, full unit-test suite. Manual-entry UI only (no camera yet) — the app is already *usable* here | ✅ Done |
| 2 | **Scan & parse** | VisionKit scanner, Vision OCR, ReceiptParser + fixture tests, Review-items screen | ✅ Done |
| 3 | **Assign & summarize** | People, assignment UI, tip/tax screen, summary + share sheet | ✅ Done |
| 4 | **Polish** | History (SwiftData persistence), recent-diner suggestions, haptics, empty states, app icon | ✅ Done |
| 5 | *(Optional later)* | iOS 26 Foundation-Models parsing, receipt-image attachment on shared summary, MultipeerConnectivity "pass the phone-less" mode, Venmo/deep-link handoff | — |

Milestone 1 first is deliberate: the math engine is the riskiest correctness surface and needs zero UI to verify, and manual entry means the app degrades gracefully whenever OCR disappoints.

---

## 7. What we're explicitly *not* building (to stay simple)

- No accounts, no login, no server, no analytics.
- No in-app payments — we hand off to the group chat / Venmo, we don't move money.
- No cross-device live collaboration in v1.
- No Android/web in v1 (this plan is native-iOS; the on-device OCR story is what makes no-cloud viable, and it's platform-specific).
