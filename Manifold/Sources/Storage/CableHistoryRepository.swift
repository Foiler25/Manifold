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
// CableHistoryRepository.swift

import Foundation
import GRDB

struct CableVerdictSummary: Sendable, Equatable {
    let worstVerdict: SessionMonitor.Verdict?
    let lastSeen: Date
    let totalSessions: Int
}

struct SavedCable: Identifiable, Sendable, Equatable {
    let id: String
    let nickname: String?
    let vendorID: Int
    let productID: Int
    let vendorName: String?
    let curatedBrand: String?
    let cableVDO: UInt32
    let firstSeen: Date
    let lastSeen: Date
    let verdictSummary: CableVerdictSummary

    var displayName: String {
        nickname ?? curatedBrand ?? vendorName ?? "Cable \(id.prefix(9))"
    }
}

struct CableSession: Identifiable, Sendable, Equatable {
    let id: Int64
    let cableID: String
    let portKey: String
    let startedAt: Date
    let endedAt: Date?
    let verdict: SessionMonitor.Verdict
    let negotiatedGbps: Double?
    let negotiatedWatts: Int?
    let observationCount: Int
    let overcurrentEvents: Int
    let plugEvents: Int
}

actor CableHistoryRepository {
    private let dbPool: DatabasePool

    init(dbPool: DatabasePool) {
        self.dbPool = dbPool
    }

    func upsertSavedCable(
        id: String,
        nickname: String? = nil,
        vendorID: Int,
        productID: Int,
        vendorName: String?,
        curatedBrand: String?,
        cableVDO: UInt32,
        seenAt: Date = .now
    ) async throws {
        try await dbPool.write { db in
            try db.execute(
                sql: """
                INSERT INTO saved_cables (
                    id, nickname, vendor_id, product_id, vendor_name,
                    curated_brand, cable_vdo, first_seen, last_seen
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    nickname = COALESCE(excluded.nickname, saved_cables.nickname),
                    vendor_name = COALESCE(excluded.vendor_name, saved_cables.vendor_name),
                    curated_brand = COALESCE(excluded.curated_brand, saved_cables.curated_brand),
                    last_seen = excluded.last_seen
                """,
                arguments: [
                    id, Self.cleanNickname(nickname), vendorID, productID,
                    vendorName, curatedBrand, Int64(cableVDO), seenAt, seenAt
                ]
            )
        }
    }

    func rename(id: String, nickname: String?) async throws {
        try await dbPool.write { db in
            try db.execute(
                sql: "UPDATE saved_cables SET nickname = ? WHERE id = ?",
                arguments: [Self.cleanNickname(nickname), id]
            )
        }
    }

    func openSession(
        cableID: String,
        portKey: String,
        startedAt: Date = .now,
        verdict: SessionMonitor.Verdict = .performing
    ) async throws -> Int64 {
        try await dbPool.write { db in
            try db.execute(
                sql: """
                INSERT INTO cable_sessions (
                    cable_id, port_key, started_at, verdict, observation_count
                ) VALUES (?, ?, ?, ?, 0)
                """,
                arguments: [cableID, portKey, startedAt, verdict.rawValue]
            )
            return db.lastInsertedRowID
        }
    }

    func closeSession(
        id: Int64,
        endedAt: Date = .now,
        verdict: SessionMonitor.Verdict,
        negotiatedGbps: Double?,
        negotiatedWatts: Int?,
        observationCount: Int,
        overcurrentEvents: Int,
        plugEvents: Int
    ) async throws {
        try await dbPool.write { db in
            try db.execute(
                sql: """
                UPDATE cable_sessions SET
                    ended_at = ?, verdict = ?, negotiated_gbps = ?,
                    negotiated_watts = ?, observation_count = ?,
                    overcurrent_events = ?, plug_events = ?
                WHERE id = ?
                """,
                arguments: [
                    endedAt, verdict.rawValue, negotiatedGbps, negotiatedWatts,
                    observationCount, overcurrentEvents, plugEvents, id
                ]
            )
        }
    }

    func savedCables() async throws -> [SavedCable] {
        try await dbPool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT c.*,
                       COUNT(s.id) AS session_count,
                       MAX(CASE s.verdict
                           WHEN 'notPerforming' THEN 3
                           WHEN 'caution' THEN 2
                           WHEN 'performing' THEN 1
                           ELSE 0 END) AS worst_rank
                FROM saved_cables c
                LEFT JOIN cable_sessions s ON s.cable_id = c.id
                WHERE c.nickname IS NOT NULL AND TRIM(c.nickname) <> ''
                GROUP BY c.id
                ORDER BY c.last_seen DESC
                """
            )
            return rows.map(Self.savedCable(from:))
        }
    }

    func cable(id: String) async throws -> SavedCable? {
        try await dbPool.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT c.*,
                       COUNT(s.id) AS session_count,
                       MAX(CASE s.verdict
                           WHEN 'notPerforming' THEN 3
                           WHEN 'caution' THEN 2
                           WHEN 'performing' THEN 1
                           ELSE 0 END) AS worst_rank
                FROM saved_cables c
                LEFT JOIN cable_sessions s ON s.cable_id = c.id
                WHERE c.id = ? GROUP BY c.id
                """,
                arguments: [id]
            ) else { return nil }
            return Self.savedCable(from: row)
        }
    }

    func sessions(cableID: String) async throws -> [CableSession] {
        try await dbPool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM cable_sessions WHERE cable_id = ? ORDER BY started_at DESC",
                arguments: [cableID]
            )
            return rows.compactMap(Self.session(from:))
        }
    }

    func latestVerdict(cableID: String) async throws -> SessionMonitor.Verdict? {
        try await dbPool.read { db in
            let raw: String? = try String.fetchOne(
                db,
                sql: "SELECT verdict FROM cable_sessions WHERE cable_id = ? ORDER BY started_at DESC LIMIT 1",
                arguments: [cableID]
            )
            return raw.flatMap(SessionMonitor.Verdict.init(rawValue:))
        }
    }

    private static func savedCable(from row: Row) -> SavedCable {
        let rank: Int = row["worst_rank"] ?? 0
        let verdict: SessionMonitor.Verdict? = switch rank {
        case 3: .notPerforming
        case 2: .caution
        case 1: .performing
        default: nil
        }
        let lastSeen: Date = row["last_seen"]
        let cableVDOValue: Int64 = row["cable_vdo"]
        return SavedCable(
            id: row["id"],
            nickname: row["nickname"],
            vendorID: row["vendor_id"],
            productID: row["product_id"],
            vendorName: row["vendor_name"],
            curatedBrand: row["curated_brand"],
            cableVDO: UInt32(truncatingIfNeeded: cableVDOValue),
            firstSeen: row["first_seen"],
            lastSeen: lastSeen,
            verdictSummary: CableVerdictSummary(
                worstVerdict: verdict,
                lastSeen: lastSeen,
                totalSessions: row["session_count"] ?? 0
            )
        )
    }

    private static func session(from row: Row) -> CableSession? {
        let raw: String = row["verdict"]
        guard let verdict = SessionMonitor.Verdict(rawValue: raw) else { return nil }
        return CableSession(
            id: row["id"],
            cableID: row["cable_id"],
            portKey: row["port_key"],
            startedAt: row["started_at"],
            endedAt: row["ended_at"],
            verdict: verdict,
            negotiatedGbps: row["negotiated_gbps"],
            negotiatedWatts: row["negotiated_watts"],
            observationCount: row["observation_count"],
            overcurrentEvents: row["overcurrent_events"],
            plugEvents: row["plug_events"]
        )
    }

    private static func cleanNickname(_ nickname: String?) -> String? {
        guard let value = nickname?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }
}
