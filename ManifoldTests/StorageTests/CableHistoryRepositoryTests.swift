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
// CableHistoryRepositoryTests.swift

import XCTest
@testable import Manifold

@MainActor
final class CableHistoryRepositoryTests: XCTestCase {
    private var directory: URL!
    private var manager: DatabaseManager!
    private var repository: CableHistoryRepository!

    override func setUp() async throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("manifold-cables-\(UUID().uuidString)")
        manager = try DatabaseManager(directory: directory)
        repository = CableHistoryRepository(dbPool: manager.dbPool)
    }

    override func tearDown() async throws {
        repository = nil
        manager = nil
        try? FileManager.default.removeItem(at: directory)
    }

    func testObservedCableOnlyBecomesSavedAfterRename() async throws {
        try await upsert()
        let initiallySaved = try await repository.savedCables()
        XCTAssertTrue(initiallySaved.isEmpty)

        try await repository.rename(id: "1234:ABCD:11223344", nickname: "Desk cable")
        let cables = try await repository.savedCables()

        XCTAssertEqual(cables.count, 1)
        XCTAssertEqual(cables.first?.displayName, "Desk cable")
        XCTAssertEqual(cables.first?.firstSeen, Date(timeIntervalSince1970: 10))
    }

    func testSessionRoundTripAndWorstEverSummary() async throws {
        try await upsert(nickname: "Dock")
        let first = try await repository.openSession(
            cableID: "1234:ABCD:11223344",
            portKey: "2/1",
            startedAt: Date(timeIntervalSince1970: 20)
        )
        try await repository.closeSession(
            id: first,
            endedAt: Date(timeIntervalSince1970: 30),
            verdict: .performing,
            negotiatedGbps: 40,
            negotiatedWatts: 100,
            observationCount: 5,
            overcurrentEvents: 0,
            plugEvents: 1
        )
        let second = try await repository.openSession(
            cableID: "1234:ABCD:11223344",
            portKey: "2/2",
            startedAt: Date(timeIntervalSince1970: 40)
        )
        try await repository.closeSession(
            id: second,
            endedAt: Date(timeIntervalSince1970: 50),
            verdict: .notPerforming,
            negotiatedGbps: 10,
            negotiatedWatts: 60,
            observationCount: 8,
            overcurrentEvents: 1,
            plugEvents: 2
        )

        let sessions = try await repository.sessions(cableID: "1234:ABCD:11223344")
        let savedCables = try await repository.savedCables()
        let saved = try XCTUnwrap(savedCables.first)
        let latestVerdict = try await repository.latestVerdict(cableID: saved.id)

        XCTAssertEqual(sessions.map(\.id), [second, first])
        XCTAssertEqual(sessions.first?.overcurrentEvents, 1)
        XCTAssertEqual(saved.verdictSummary.totalSessions, 2)
        XCTAssertEqual(saved.verdictSummary.worstVerdict, .notPerforming)
        XCTAssertEqual(latestVerdict, .notPerforming)
    }

    func testRetentionPrunesOnlyOldUnnamedHistory() async throws {
        try await upsert(id: "unnamed-active", seenAt: 10)
        try await upsert(id: "unnamed-stale", seenAt: 10)
        try await upsert(id: "named", nickname: "Keep me", seenAt: 10)

        _ = try await repository.openSession(
            cableID: "unnamed-active", portKey: "2/1",
            startedAt: Date(timeIntervalSince1970: 20)
        )
        let recentUnnamed = try await repository.openSession(
            cableID: "unnamed-active", portKey: "2/1",
            startedAt: Date(timeIntervalSince1970: 150)
        )
        let namedSession = try await repository.openSession(
            cableID: "named", portKey: "2/2",
            startedAt: Date(timeIntervalSince1970: 20)
        )

        let result = try await repository.pruneUnnamedHistory(
            olderThan: Date(timeIntervalSince1970: 100)
        )

        XCTAssertEqual(result, CableHistoryPruneResult(
            sessionsDeleted: 1, cablesDeleted: 1
        ))
        let remainingUnnamed = try await repository.sessions(cableID: "unnamed-active")
        let remainingNamed = try await repository.sessions(cableID: "named")
        let staleCable = try await repository.cable(id: "unnamed-stale")
        let namedCable = try await repository.cable(id: "named")
        XCTAssertEqual(remainingUnnamed.map(\.id), [recentUnnamed])
        XCTAssertEqual(remainingNamed.map(\.id), [namedSession])
        XCTAssertNil(staleCable)
        XCTAssertNotNil(namedCable)
    }

    private func upsert(nickname: String? = nil) async throws {
        try await upsert(
            id: "1234:ABCD:11223344", nickname: nickname, seenAt: 10
        )
    }

    private func upsert(
        id: String,
        nickname: String? = nil,
        seenAt: TimeInterval
    ) async throws {
        try await repository.upsertSavedCable(
            id: id,
            nickname: nickname,
            vendorID: 0x1234,
            productID: 0xABCD,
            vendorName: "Vendor",
            curatedBrand: "Brand",
            cableVDO: 0x1122_3344,
            seenAt: Date(timeIntervalSince1970: seenAt)
        )
    }
}
