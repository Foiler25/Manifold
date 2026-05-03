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
// EventRepository.swift
//
// Per SPEC §10.2. Owns the `events` table.
//
// `write(_:)` accepts only the three event kinds that carry user-
// visible meaning ("attached", "detached", "diagnostic") — the
// in-memory-only kinds (`.telemetry`, `.fullRefresh`) skip persistence
// because they'd swamp the table at no analytic benefit. `payload_json`
// holds per-kind extras (diagnostic detail/severity/title for
// diagnostic, link speed + watts at the moment-of-event for
// attached/detached) so future fields don't need a schema migration.

import Foundation
import GRDB
import ManifoldKit

// MARK: - StoredEvent

/// Phase 10 read-back type per SPEC §10.2. Each row of `events`
/// surfaces as one of these to the History view.
struct StoredEvent: Identifiable, Sendable, Equatable {

    /// SQLite rowid (auto-increment primary key). Distinct from the
    /// `Diagnostic.id` UUID — that lives inside the JSON payload.
    let id: Int64

    let timestamp: Date

    /// Stable string identifier per SPEC §10.1 — "attached" /
    /// "detached" / "diagnostic". Mirrors `EventKind` below.
    let kind: EventKind

    /// nil for non-device events (none yet; reserved for future
    /// system-level events).
    let deviceID: DeviceID?

    let portID: PortID

    /// Decoded per-kind extras. Use `payloadJSON` if you need the
    /// raw string (e.g., for export).
    let payload: EventPayload

    /// Original JSON string — preserved so the export layer (Phase 11)
    /// can pass it through verbatim.
    let payloadJSON: String
}

/// Kind enum that mirrors the persisted `kind` column. Separated from
/// `PortEvent` so persistence stays an explicit projection — adding
/// a new `PortEvent` case doesn't accidentally start writing rows.
enum EventKind: String, Sendable, Codable {
    case attached
    case detached
    case diagnostic
}

/// Per-kind payload. JSON-encoded into `payload_json` on write,
/// JSON-decoded on read. Adding a new payload field is forward-
/// compatible (new field absent in old rows decodes as nil).
enum EventPayload: Sendable, Equatable {
    case attached(deviceName: String, linkProtocol: String?, watts: Double?)
    case detached(lastKnownDeviceName: String?)
    case diagnostic(severity: String, ruleIdentifier: String, title: String, detail: String)

    fileprivate var kind: EventKind {
        switch self {
        case .attached:   return .attached
        case .detached:   return .detached
        case .diagnostic: return .diagnostic
        }
    }
}

// MARK: - Repository

actor EventRepository {

    private let dbPool: DatabasePool

    init(dbPool: DatabasePool) {
        self.dbPool = dbPool
    }

    // MARK: - Write

    /// Optional extras the caller (typically `AppDelegate`) snapshots
    /// from the live PortGraph at event-arrival time and threads
    /// through to the persisted payload. Phase 10 review F23
    /// closure: previously `.attached` rows always serialized with
    /// `linkProtocol: nil, watts: nil` because the encode site had
    /// no port reference. Now the caller passes them explicitly.
    struct AttachedExtras: Sendable {
        var linkProtocol: String?
        var watts: Double?
        init(linkProtocol: String? = nil, watts: Double? = nil) {
            self.linkProtocol = linkProtocol
            self.watts = watts
        }
    }

    /// Persist `event`. No-ops for `.telemetry` and `.fullRefresh`
    /// (those don't belong in the events log). `attachedExtras`
    /// supplies the link-protocol + watts values for `.attached`
    /// events when the caller has them; ignored for other event
    /// kinds. Caller can `await` to ensure write durability before
    /// returning, but in practice callers use
    /// `Task { try? await repo.write(event) }` for fire-and-forget —
    /// losing one row across an unclean exit is acceptable.
    func write(
        _ event: PortEvent,
        at timestamp: Date = .now,
        attachedExtras: AttachedExtras = .init()
    ) async throws {
        guard let row = encode(event: event, timestamp: timestamp, attachedExtras: attachedExtras) else { return }
        try await dbPool.write { db in
            try db.execute(
                sql: """
                INSERT INTO events (ts, kind, device_id, port_id, payload_json)
                VALUES (?, ?, ?, ?, ?)
                """,
                arguments: [
                    row.timestamp,
                    row.kind.rawValue,
                    row.deviceID?.rawValue,
                    row.portID.rawValue,
                    row.payloadJSON
                ]
            )
        }
    }

    // MARK: - Reads

    /// Most recent `limit` events (default 100). Used by the History
    /// view's default load.
    func recentEvents(limit: Int = 100) async throws -> [StoredEvent] {
        try await dbPool.read { db in
            try Self.fetchAll(
                db,
                sql: "SELECT * FROM events ORDER BY ts DESC LIMIT ?",
                arguments: [limit]
            )
        }
    }

    /// Most-recent `limit` events whose `ts >= since`. Phase 14
    /// closure of F24 (Phase 11 review): the export-CSV path
    /// previously fetched `recentEvents(limit: 100_000)` then
    /// in-memory filtered by time range, which was bounded but
    /// O(N) on the table. SQL-side `WHERE ts >= ?` is the cheap
    /// shape; pass `.distantPast` for the legacy "no time filter"
    /// behaviour. Ordered DESC by ts so callers don't need to
    /// re-sort.
    func events(since: Date, limit: Int = 100_000) async throws -> [StoredEvent] {
        try await dbPool.read { db in
            try Self.fetchAll(
                db,
                sql: "SELECT * FROM events WHERE ts >= ? ORDER BY ts DESC LIMIT ?",
                arguments: [since, limit]
            )
        }
    }

    /// Every event for one device, oldest first. Used by the
    /// per-device drill-down in History.
    func events(forDevice deviceID: DeviceID) async throws -> [StoredEvent] {
        try await dbPool.read { db in
            try Self.fetchAll(
                db,
                sql: "SELECT * FROM events WHERE device_id = ? ORDER BY ts ASC",
                arguments: [deviceID.rawValue]
            )
        }
    }

    // MARK: - Retention

    /// Delete every event older than `date`. Returns the number of
    /// rows pruned. Called by `DownsamplingJob` per SPEC §18 Phase 10
    /// "RetentionPolicy enforced".
    @discardableResult
    func deleteOlderThan(_ date: Date) async throws -> Int {
        try await dbPool.write { db in
            try db.execute(sql: "DELETE FROM events WHERE ts < ?", arguments: [date])
            return db.changesCount
        }
    }

    // MARK: - Encode

    /// Project a `PortEvent` to an insertable row. nil for events
    /// that should not be persisted.
    private func encode(event: PortEvent, timestamp: Date, attachedExtras: AttachedExtras) -> StoredEvent? {
        switch event {
        case .attached(let device, at: let portID):
            let payload = EventPayload.attached(
                deviceName: device.name,
                linkProtocol: attachedExtras.linkProtocol,
                watts: attachedExtras.watts
            )
            return StoredEvent(
                id: 0,
                timestamp: timestamp,
                kind: .attached,
                deviceID: device.id,
                portID: portID,
                payload: payload,
                payloadJSON: encodePayloadJSON(payload)
            )

        case .detached(let deviceID, from: let portID):
            let payload = EventPayload.detached(lastKnownDeviceName: nil)
            return StoredEvent(
                id: 0,
                timestamp: timestamp,
                kind: .detached,
                deviceID: deviceID,
                portID: portID,
                payload: payload,
                payloadJSON: encodePayloadJSON(payload)
            )

        case .diagnostic(let diag):
            let payload = EventPayload.diagnostic(
                severity: diag.severity.rawValue,
                ruleIdentifier: diag.ruleIdentifier,
                title: diag.title,
                detail: diag.detail
            )
            return StoredEvent(
                id: 0,
                timestamp: diag.triggeredAt,
                kind: .diagnostic,
                deviceID: nil,
                portID: diag.target,
                payload: payload,
                payloadJSON: encodePayloadJSON(payload)
            )

        case .telemetry, .fullRefresh:
            return nil
        }
    }

    // MARK: - JSON codec

    /// Encode payload to JSON string. Encoding can't realistically
    /// fail for the payload shapes we use; on failure we return an
    /// empty `{}` so the column NOT NULL constraint holds and the
    /// row still inserts (the export reader will tolerate missing
    /// fields).
    private func encodePayloadJSON(_ payload: EventPayload) -> String {
        guard let data = try? JSONEncoder().encode(payload),
              let s = String(data: data, encoding: .utf8)
        else { return "{}" }
        return s
    }

    // MARK: - Row → StoredEvent

    private static func fetchAll(_ db: Database, sql: String, arguments: StatementArguments) throws -> [StoredEvent] {
        try Row.fetchAll(db, sql: sql, arguments: arguments).compactMap(makeStoredEvent)
    }

    private static func makeStoredEvent(from row: Row) -> StoredEvent? {
        let id: Int64 = row["id"]
        let ts: Date = row["ts"]
        let kindRaw: String = row["kind"]
        let deviceIDRaw: String? = row["device_id"]
        let portIDRaw: String = row["port_id"]
        let payloadJSON: String = row["payload_json"]
        guard let kind = EventKind(rawValue: kindRaw) else { return nil }
        let payload = decodePayload(json: payloadJSON, kind: kind)
        return StoredEvent(
            id: id,
            timestamp: ts,
            kind: kind,
            deviceID: deviceIDRaw.map { DeviceID($0) },
            portID: PortID(portIDRaw),
            payload: payload,
            payloadJSON: payloadJSON
        )
    }

    private static func decodePayload(json: String, kind: EventKind) -> EventPayload {
        guard let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(EventPayload.self, from: data)
        else {
            // Decoding failure (corrupt row, payload from a future
            // schema version we don't recognise) — fall back to a
            // placeholder shape that keeps the row visible without
            // claiming to know its contents.
            switch kind {
            case .attached:   return .attached(deviceName: "", linkProtocol: nil, watts: nil)
            case .detached:   return .detached(lastKnownDeviceName: nil)
            case .diagnostic: return .diagnostic(severity: "warning", ruleIdentifier: "", title: "", detail: "")
            }
        }
        return decoded
    }
}

// MARK: - EventPayload Codable

/// Hand-written Codable so the on-disk JSON shape is stable and
/// greppable (auto-synthesised would key cases via Swift naming
/// conventions that could shift across compiler versions).
extension EventPayload: Codable {

    private enum CodingKeys: String, CodingKey {
        case kind
        case deviceName
        case linkProtocol
        case watts
        case lastKnownDeviceName
        case severity
        case ruleIdentifier
        case title
        case detail
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind.rawValue, forKey: .kind)
        switch self {
        case .attached(let deviceName, let linkProtocol, let watts):
            try container.encode(deviceName, forKey: .deviceName)
            try container.encodeIfPresent(linkProtocol, forKey: .linkProtocol)
            try container.encodeIfPresent(watts, forKey: .watts)
        case .detached(let lastKnown):
            try container.encodeIfPresent(lastKnown, forKey: .lastKnownDeviceName)
        case .diagnostic(let severity, let ruleIdentifier, let title, let detail):
            try container.encode(severity, forKey: .severity)
            try container.encode(ruleIdentifier, forKey: .ruleIdentifier)
            try container.encode(title, forKey: .title)
            try container.encode(detail, forKey: .detail)
        }
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kindRaw = try container.decode(String.self, forKey: .kind)
        guard let kind = EventKind(rawValue: kindRaw) else {
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: "Unknown payload kind: \(kindRaw)"
            )
        }
        switch kind {
        case .attached:
            self = .attached(
                deviceName: try container.decode(String.self, forKey: .deviceName),
                linkProtocol: try container.decodeIfPresent(String.self, forKey: .linkProtocol),
                watts: try container.decodeIfPresent(Double.self, forKey: .watts)
            )
        case .detached:
            self = .detached(
                lastKnownDeviceName: try container.decodeIfPresent(String.self, forKey: .lastKnownDeviceName)
            )
        case .diagnostic:
            self = .diagnostic(
                severity: try container.decode(String.self, forKey: .severity),
                ruleIdentifier: try container.decode(String.self, forKey: .ruleIdentifier),
                title: try container.decode(String.self, forKey: .title),
                detail: try container.decode(String.self, forKey: .detail)
            )
        }
    }
}
