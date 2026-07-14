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
// You should have received a copy of the GNU General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.
//
// ─────────────────────────────────────────────────────────────────────
// CableAttributionTests.swift
//
// Phase 21 — guards the MIT permission-notice preservation required by
// the WhatCable absorb. If a future refactor drops ATTRIBUTION.md or
// strips the upstream credit, this test fails and CI catches it.

import XCTest

final class CableAttributionTests: XCTestCase {

    func test_attribution_fileExists_atSourcePath() {
        guard let url = locateAttributionFile() else {
            XCTFail("ATTRIBUTION.md not found in any candidate location")
            return
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func test_attribution_containsMITAndUpstreamReference() throws {
        guard let url = locateAttributionFile() else {
            throw XCTSkip("ATTRIBUTION.md not present in test bundle environment")
        }
        let contents = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(contents.contains("MIT"), "ATTRIBUTION.md must mention MIT")
        XCTAssertTrue(
            contents.contains("darrylmorley/whatcable"),
            "ATTRIBUTION.md must reference upstream repo darrylmorley/whatcable"
        )
        XCTAssertTrue(
            contents.contains("Permission is hereby granted"),
            "ATTRIBUTION.md must include the MIT permission notice verbatim"
        )
        XCTAssertTrue(
            contents.contains("80114e7a482e53980c12b76839e1159f8548e9ee"),
            "ATTRIBUTION.md must pin the current imported upstream revision"
        )
        XCTAssertTrue(contents.contains("CableAdapterInfo"))
        XCTAssertTrue(contents.contains("CableLinkSpeed"))
    }

    /// ATTRIBUTION.md lives in the source tree, not the test bundle.
    /// Walk up from the test source file (resolved at compile time via
    /// `#filePath`) until we find a path whose sibling repository
    /// layout contains the expected file. This way the test works
    /// from any CI working directory and from local Xcode runs.
    private func locateAttributionFile() -> URL? {
        let testFile = URL(fileURLWithPath: #filePath)
        // ManifoldTests/Cables/CableAttributionTests.swift →
        // walk up to Manifold/Sources/Cables/ATTRIBUTION.md
        var current = testFile.deletingLastPathComponent() // Cables
        while current.pathComponents.count > 1 {
            let candidate = current
                .deletingLastPathComponent() // ManifoldTests
                .deletingLastPathComponent() // repo root
                .appendingPathComponent("Manifold")
                .appendingPathComponent("Sources")
                .appendingPathComponent("Cables")
                .appendingPathComponent("ATTRIBUTION.md")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            current = current.deletingLastPathComponent()
        }
        return nil
    }
}
