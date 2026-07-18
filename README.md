# Split Checks

Split a dinner bill from a photo of the receipt — fully on-device, no cloud, no accounts. See [PLAN.md](PLAN.md) for the full project plan.

**Status: Milestones 1–4 complete.** The full loop from PLAN.md works: scan (VisionKit camera or photo import) → on-device OCR + parsing with low-confidence flags and a printed-subtotal checksum → people → assignment → tip & tax → exact per-person totals → share to the group chat → saved to local history (SwiftData). Names from past bills come back as one-tap suggestions. Remaining ideas live in PLAN.md's Milestone 5 (optional).

## Layout

```
SplitChecksCore/   SwiftPM package: models, Money helpers, SplitEngine + tests.
                   Pure Swift, no UI — this is where correctness lives.
App/               SwiftUI app sources (iOS 17+).
project.yml        XcodeGen spec that ties the two together.
```

## Getting started (on a Mac)

Run the core tests — no Xcode project needed:

```sh
cd SplitChecksCore && swift test
```

Build the app:

```sh
brew install xcodegen   # once
xcodegen                # generates SplitChecks.xcodeproj
open SplitChecks.xcodeproj
```

Then run the `SplitChecks` scheme on an iOS 17+ simulator or device.

No XcodeGen? Create a new iOS App project in Xcode (SwiftUI, iOS 17 minimum), delete its template source, add the `App/` folder to the target, and add the local `SplitChecksCore` package via *File → Add Package Dependencies → Add Local*.

## Releasing to TestFlight (no local Mac needed)

The `Release to TestFlight` workflow archives, cloud-signs, and uploads the
app to App Store Connect entirely on CI. One-time setup:

1. **App Store Connect API key**: App Store Connect → Users and Access →
   Integrations → App Store Connect API → generate a **Team key** with the
   **App Manager** role. Note the Key ID and Issuer ID and download the `.p8`.
2. **Repo secrets** (GitHub → Settings → Secrets and variables → Actions):
   - `ASC_KEY_ID` — the key's ID
   - `ASC_ISSUER_ID` — the issuer ID
   - `ASC_PRIVATE_KEY` — full contents of the `.p8` file
   - `APPLE_TEAM_ID` — your 10-character Team ID (developer.apple.com →
     Membership)
3. **App record**: App Store Connect → Apps → **+** → New App, with bundle ID
   `com.kchengg1.splitchecks` (register the bundle ID at
   developer.apple.com → Identifiers first if it isn't offered).

Then run the workflow from the Actions tab (or push a `v*` tag). The build
appears in TestFlight after Apple's processing (~5–15 min); install it on
your phone from the TestFlight app.

## How the math works

All money is integer cents. Every division goes through one function —
`SplitEngine.apportion(_:weights:)` — which uses the largest-remainder method:
floor each proportional share, then hand leftover cents to the largest
fractional remainders. Two invariants hold everywhere (and are fuzz-tested
over 20,000 cases):

1. Portions always sum exactly to the amount being split — no pennies created or lost.
2. No portion deviates from its exact proportional share by a full cent or more.

Shared items split by per-person weights (weights 2:1 give a two-thirds/one-third
split); tax and tip are prorated proportionally to each person's item subtotal,
or evenly, per the user's choice. Discounts are just negative line items and
split with the same fairness as charges.

## How scanning works

Everything is on-device — no cloud, no accounts:

1. **Capture**: VisionKit's document camera (the Notes.app scanner) auto-crops
   and de-skews, or the user imports a photo.
2. **OCR**: Vision's `VNRecognizeTextRequest` (accurate mode, language
   correction off — it "fixes" prices) returns text with bounding boxes.
3. **Parse**: `ReceiptParser` (in the core package, fully unit-tested) clusters
   observations into visual rows by vertical midpoint — receipts are columnar,
   so a row may be a name and a price observation — then classifies each row:
   trailing-amount extraction (tax-code suffixes, parenthesized discounts,
   comma decimals), explicit quantities ("2 x"), and keyword lines
   (SUBTOTAL/TAX/TIP/TOTAL captured separately; payment lines like
   VISA/CHANGE ignored).
4. **Review**: parsed items are a draft, not gospel — low-confidence lines are
   flagged, and the printed subtotal is compared against the item sum as a
   checksum before anyone gets assigned anything.
