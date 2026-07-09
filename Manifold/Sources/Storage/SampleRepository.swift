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
// SampleRepository.swift
//
// Per SPEC §10.2 + §18 Phase 10 rev-5: SampleRepository owns the
// on-disk write path for telemetry samples. EventService /
// AppDelegate calls `write(_:portID:deviceID:)` on every
// `.telemetry` event. The Phase 5 in-memory `PortGraph.telemetryHistory`
// remains the live UI fast-path (popover sparklines, last-60); GRDB
// is the long-range source.
//
// Downsampling pattern: `downsampleRawTo1Min` reads raw rows older
// than the cutoff, groups them into 1-minute buckets per
// (port, device), inserts one 1-min row per bucket, then deletes
// the source raw rows. Same shape for 1min → 1hour.

import Foundation
import GRDB
import ManifoldKit

// MARK: - StoredSample

/// One row of `samples` decoded for History view consumption.
struct StoredSample: Identifiable, Sendable, Equatable {
    let id: Int64
    let timestamp: Date
    let deviceID: DeviceID?
    let portID: PortID
    let watts: Double?
    /// Mbps integer per the SPEC §10.1 column type (`mbps INTEGER`).
    /// nil when the sample didn't include a bitrate reading.
    let mbps: Int?
    let aggregation: SampleAggregation
}

// MARK: - Repository

actor SampleRepository {

    private let dbPool: DatabasePool

    init(dbPool: DatabasePool) {
        self.dbPool = dbPool
    }

    // MARK: - Write

    /// Insert one raw sample. The Phase 5 in-memory ring buffer is
    /// the UI fast-path; this is the long-range record. Watts /
    /// bitrate carry through unchanged from the supplied
    /// `TelemetrySample`.
    func write(_ sample: TelemetrySample, portID: PortID, deviceID: DeviceID?) async throws {
        let mbps: Int? = sample.bitrate.map { Int($0.bitsPerSecond / 1_000_000) }
        try await dbPool.write { db in
            try db.execute(
                sql: """
                INSERT INTO samples (ts, device_id, port_id, watts, mbps, aggregation)
                VALUES (?, ?, ?, ?, ?, 'raw')
                """,
                arguments: [
                    sample.timestamp,
                    deviceID?.rawValue,
                    portID.rawValue,
                    sample.watts?.value,
                    mbps
                ]
            )
        }
    }

    // MARK: - Reads

    /// All samples for `portID` since `since` at the requested
    /// aggregation. Ordered ascending so a sparkline can iterate
    /// left-to-right.
    func samples(forPort portID: PortID, since: Date, aggregation: SampleAggregation) async throws -> [StoredSample] {
        try await dbPool.read { db in
            try Self.fetchAll(
                db,
                sql: """
                SELECT * FROM samples
                WHERE port_id = ? AND aggregation = ? AND ts >= ?
                ORDER BY ts ASC
                """,
                arguments: [portID.rawValue, aggregation.rawValue, since]
            )
        }
    }

    /// Every distinct `port_id` present in the samples table. The
    /// export path iterates this instead of the live graph so an
    /// "All time" telemetry export includes history for hardware
    /// that isn't currently plugged in (the live graph only knows
    /// about connected ports).
    func allPortIDs() async throws -> [PortID] {
        try await dbPool.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT DISTINCT port_id FROM samples ORDER BY port_id"
            ).map { PortID($0) }
        }
    }

    // MARK: - Downsampling

    /// Promote raw → 1-min for samples older than `olderThan`.
    /// Implementation: `INSERT INTO samples ... SELECT AVG(...) ...
    /// GROUP BY 1-minute bucket`, then `DELETE` the raw source rows.
    /// Returns the number of *raw* rows pruned (the count callers
    /// care about — it's what bounds the table's growth).
    @discardableResult
    func downsampleRawTo1Min(olderThan: Date) async throws -> Int {
        try await downsample(
            from: .raw,
            to: .oneMin,
            bucketSeconds: 60,
            olderThan: olderThan
        )
    }

    /// Promote 1-min → 1-hour for samples older than `olderThan`.
    /// Same loop as above with a 3600-second bucket.
    @discardableResult
    func downsample1MinTo1Hour(olderThan: Date) async throws -> Int {
        try await downsample(
            from: .oneMin,
            to: .oneHour,
            bucketSeconds: 3600,
            olderThan: olderThan
        )
    }

    /// Generic two-stage downsampler. `bucketSeconds` is the new
    /// aggregation's granularity. Group key is the bucket's start
    /// timestamp (seconds-since-epoch / bucketSeconds × bucketSeconds)
    /// so multiple raw rows in the same minute roll into one 1-min
    /// row keyed at that minute boundary.
    private func downsample(
        from source: SampleAggregation,
        to target: SampleAggregation,
        bucketSeconds: Int,
        olderThan: Date
    ) async throws -> Int {
        try await dbPool.write { db in
            // GRDB's `Date` binding round-trips as an ISO-ish string
            // by default but SQLite's `strftime`/`%s` work on the
            // `julianday`/text form. Bind the cutoff as
            // `timeIntervalSince1970` and compare via SQLite's
            // strftime → Unix seconds path so the math matches.
            let cutoffEpoch = olderThan.timeIntervalSince1970

            try db.execute(
                sql: """
                INSERT INTO samples (ts, device_id, port_id, watts, mbps, aggregation)
                SELECT
                    datetime(CAST(strftime('%s', ts) AS INTEGER) / ? * ?, 'unixepoch'),
                    device_id,
                    port_id,
                    AVG(watts),
                    CAST(AVG(mbps) AS INTEGER),
                    ?
                FROM samples
                WHERE aggregation = ?
                  AND CAST(strftime('%s', ts) AS REAL) < ?
                GROUP BY
                    CAST(strftime('%s', ts) AS INTEGER) / ?,
                    device_id,
                    port_id
                """,
                arguments: [
                    bucketSeconds, bucketSeconds,
                    target.rawValue,
                    source.rawValue,
                    cutoffEpoch,
                    bucketSeconds
                ]
            )
            try db.execute(
                sql: """
                DELETE FROM samples
                WHERE aggregation = ?
                  AND CAST(strftime('%s', ts) AS REAL) < ?
                """,
                arguments: [source.rawValue, cutoffEpoch]
            )
            return db.changesCount
        }
    }

    // MARK: - Retention

    /// Delete every sample of `aggregation` older than `date`.
    /// Returns the number of rows pruned.
    @discardableResult
    func deleteOlderThan(_ date: Date, aggregation: SampleAggregation) async throws -> Int {
        try await dbPool.write { db in
            try db.execute(
                sql: "DELETE FROM samples WHERE aggregation = ? AND ts < ?",
                arguments: [aggregation.rawValue, date]
            )
            return db.changesCount
        }
    }

    // MARK: - Row → StoredSample

    private static func fetchAll(_ db: Database, sql: String, arguments: StatementArguments) throws -> [StoredSample] {
        try Row.fetchAll(db, sql: sql, arguments: arguments).compactMap(makeStoredSample)
    }

    private static func makeStoredSample(from row: Row) -> StoredSample? {
        let id: Int64 = row["id"]
        let ts: Date = row["ts"]
        let deviceIDRaw: String? = row["device_id"]
        let portIDRaw: String = row["port_id"]
        let watts: Double? = row["watts"]
        let mbps: Int64? = row["mbps"]
        let aggRaw: String = row["aggregation"]
        guard let aggregation = SampleAggregation(rawValue: aggRaw) else { return nil }
        return StoredSample(
            id: id,
            timestamp: ts,
            deviceID: deviceIDRaw.map { DeviceID($0) },
            portID: PortID(portIDRaw),
            watts: watts,
            mbps: mbps.map(Int.init),
            aggregation: aggregation
        )
    }
}
