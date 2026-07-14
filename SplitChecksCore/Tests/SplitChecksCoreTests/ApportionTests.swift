import XCTest
@testable import SplitChecksCore

/// Tests for the largest-remainder apportionment that underpins every split.
/// Expected values are cross-checked against an independent reference
/// implementation of the algorithm.
final class ApportionTests: XCTestCase {

    func testEvenThreeWaySplitGivesExtraCentToFirst() {
        XCTAssertEqual(SplitEngine.apportion(100, weights: [1, 1, 1]), [34, 33, 33])
    }

    func testWeightedSplit() {
        XCTAssertEqual(SplitEngine.apportion(100, weights: [2, 1]), [67, 33])
        XCTAssertEqual(SplitEngine.apportion(1000, weights: [3, 2, 1]), [500, 333, 167])
        XCTAssertEqual(SplitEngine.apportion(2550, weights: [2, 1]), [1700, 850])
    }

    func testNegativeAmountSplitsSymmetrically() {
        XCTAssertEqual(SplitEngine.apportion(-100, weights: [1, 1, 1]), [-34, -33, -33])
        XCTAssertEqual(SplitEngine.apportion(-500, weights: [1, 1]), [-250, -250])
    }

    func testOddCentGoesToFirstPerson() {
        XCTAssertEqual(SplitEngine.apportion(101, weights: [1, 1]), [51, 50])
        XCTAssertEqual(SplitEngine.apportion(1051, weights: [1, 1]), [526, 525])
    }

    func testZeroWeightsFallBackToEvenSplit() {
        XCTAssertEqual(SplitEngine.apportion(100, weights: [0, 0]), [50, 50])
    }

    func testAmountSmallerThanPartyDistributesLeadingCents() {
        XCTAssertEqual(SplitEngine.apportion(5, weights: [1, 1, 1, 1, 1, 1]), [1, 1, 1, 1, 1, 0])
    }

    func testSingleWeightTakesEverything() {
        XCTAssertEqual(SplitEngine.apportion(1234, weights: [7]), [1234])
        XCTAssertEqual(SplitEngine.apportion(0, weights: [1, 1]), [0, 0])
    }

    /// The two invariants that make the engine trustworthy: portions always
    /// sum exactly to the amount (no pennies created or lost), and no portion
    /// deviates from its exact proportional share by a full cent or more.
    func testInvariantsHoldUnderFuzz() {
        var generator = SplitMix64(seed: 42)
        for _ in 0..<20_000 {
            let count = Int(generator.next() % 8) + 1
            let weights = (0..<count).map { _ in Int(generator.next() % 6) }
            let amount = Int(generator.next() % 100_001) - 50_000
            let portions = SplitEngine.apportion(amount, weights: weights)

            XCTAssertEqual(portions.reduce(0, +), amount, "cents not conserved for \(amount) / \(weights)")

            let totalWeight = weights.reduce(0, +)
            let effectiveWeights = totalWeight > 0 ? weights : [Int](repeating: 1, count: count)
            let effectiveTotal = totalWeight > 0 ? totalWeight : count
            for (cents, weight) in zip(portions, effectiveWeights) {
                let exact = Double(amount) * Double(weight) / Double(effectiveTotal)
                XCTAssertLessThan(abs(Double(cents) - exact), 1.0 + 1e-9,
                                  "portion \(cents) too far from exact \(exact) for \(amount) / \(weights)")
            }
        }
    }
}

/// Tiny deterministic PRNG so the fuzz test is reproducible everywhere.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
