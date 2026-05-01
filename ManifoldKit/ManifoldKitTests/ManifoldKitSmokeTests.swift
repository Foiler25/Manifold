// ManifoldKit/ManifoldKitTests/ManifoldKitSmokeTests.swift
//
// Phase-0 smoke test. Confirms ManifoldKit imports cleanly under Swift 6
// strict concurrency and that the sentinel constant matches the SPEC
// revision baseline. Replaced/extended in Phase 2 with the real
// SnapshotRoundTripTests and IdentifierStabilityTests called for in
// SPEC.md §17.
//
// Why XCTest and not the new Swift Testing macros: Swift Testing is fine,
// but XCTest works identically across `swift test` and Xcode's test runner
// with zero ceremony, and the SPEC's later test files are written in
// XCTest style (`USB2OnUSB3DeviceRuleTests` etc.). Picking XCTest now
// keeps the test surface uniform from day one.

import XCTest
@testable import ManifoldKit

final class ManifoldKitSmokeTests: XCTestCase {

    /// The constant exists so future phases can fail loudly when the SPEC
    /// revision and the in-code data model drift apart. Phase 2 baseline
    /// is revision 3, matching `SPEC.md`'s rev-3 header (license + repo
    /// public flip + Phase-2 fallback-key bullet amendments).
    func test_specRevision_matchesPhase2Baseline() {
        XCTAssertEqual(ManifoldKitInfo.specRevision, 3)
    }
}
