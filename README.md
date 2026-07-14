# Split Checks

Split a dinner bill from a photo of the receipt — fully on-device, no cloud, no accounts. See [PLAN.md](PLAN.md) for the full project plan.

**Status: Milestone 1** — the split-math core with its test suite, plus a working manual-entry app (items → people → assign → tip & tax → summary → share). Receipt scanning (Milestone 2) lands next and feeds the same item list.

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
