// Manifold — visualizes physical USB and Thunderbolt connections live.
// Copyright (C) 2026 Brandon Villar
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// ─────────────────────────────────────────────────────────────────────
// RetentionPolicyTests.swift
//
// Pin SPEC §10.2 default retention values and the cutoff-date math.
// Trivial type, but the defaults are part of the user-visible
// contract — a future "make raw retention 1h to save disk" change
// should be a deliberate decision, not an accident.

import XCTest
@testable import Manifold

final class RetentionPolicyTests: XCTestCase {

    /// SPEC §10.2: 24h raw, 30d 1-min, 1y 1-hour.
    func test_defaults_matchSpecValues() {
        let policy = RetentionPolicy.default
        XCTAssertEqual(policy.rawRetention,     86_400,     "Raw default = 24 hours")
        XCTAssertEqual(policy.oneMinRetention,  2_592_000,  "1-min default = 30 days")
        XCTAssertEqual(policy.oneHourRetention, 31_536_000, "1-hour default = 365 days")
    }

    /// `cutoffDate(for:)` subtracts the retention interval from `now`.
    func test_cutoffDate_subtractsRetentionFromNow() {
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        let policy = RetentionPolicy.default
        XCTAssertEqual(policy.cutoffDate(for: .raw, now: now),     now.addingTimeInterval(-86_400))
        XCTAssertEqual(policy.cutoffDate(for: .oneMin, now: now),  now.addingTimeInterval(-2_592_000))
        XCTAssertEqual(policy.cutoffDate(for: .oneHour, now: now), now.addingTimeInterval(-31_536_000))
    }

    /// Codable round-trip — used by future @AppStorage persistence.
    func test_codable_roundTrip() throws {
        let original = RetentionPolicy(
            rawRetention: 3600,
            oneMinRetention: 86_400,
            oneHourRetention: 604_800
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RetentionPolicy.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    /// `SampleAggregation.allCases` exposes exactly the three SPEC
    /// buckets in the canonical order.
    func test_sampleAggregation_allCases_isExhaustiveAndOrdered() {
        XCTAssertEqual(SampleAggregation.allCases, [.raw, .oneMin, .oneHour])
        XCTAssertEqual(SampleAggregation.raw.rawValue,     "raw")
        XCTAssertEqual(SampleAggregation.oneMin.rawValue,  "1min")
        XCTAssertEqual(SampleAggregation.oneHour.rawValue, "1hour")
    }
}
