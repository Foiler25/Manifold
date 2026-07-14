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
// CablePersistenceErrorSurfacingTests.swift

import GRDB
import XCTest
@testable import Manifold

@MainActor
final class CablePersistenceErrorSurfacingTests: XCTestCase {
    func testSavedCableLoadDistinguishesDatabaseFailureFromEmpty() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.manager.dbPool.close()

        let result = await loadCableHistory {
            try await fixture.repository.savedCables()
        }

        guard case let .failed(message) = result else {
            return XCTFail("A closed database must produce a visible failure state")
        }
        XCTAssertFalse(message.isEmpty)
    }

    func testSaveActionReturnsFailureInsteadOfSilentSuccess() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.manager.dbPool.close()

        let result = await performCableSave {
            try await fixture.repository.rename(id: "missing", nickname: "Desk")
        }

        guard case let .failed(message) = result else {
            return XCTFail("A failed database write must not look saved")
        }
        XCTAssertFalse(message.isEmpty)
    }
}

@MainActor
private final class Fixture {
    let directory: URL
    let manager: DatabaseManager
    let repository: CableHistoryRepository

    init() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("manifold-save-errors-\(UUID().uuidString)")
        manager = try DatabaseManager(directory: directory)
        repository = CableHistoryRepository(dbPool: manager.dbPool)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}
