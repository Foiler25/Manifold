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
// V1Initial.swift
//
// First (and so far only) schema migration. Per SPEC §10.1.
// Append-only forever — V1 SQL must NEVER change once shipped, even
// if a future migration drops or alters the table. New migrations
// add new files; this file stays frozen as the historical baseline.

import Foundation
import GRDB

enum V1Initial {

    /// Stable identifier — GRDB stores this in `grdb_migrations` so
    /// it knows which migrations have already run on a given DB.
    /// MUST NOT change once the app has shipped.
    static let identifier = "v1.initial"

    /// Register this migration with the supplied migrator.
    /// `DatabaseManager`'s static init wires every migration in
    /// chronological order; future V2+ files follow the same shape.
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration(identifier) { db in
            try createDevicesTable(db)
            try createEventsTable(db)
            try createSamplesTable(db)
            try createSchemaMetadataTable(db)
        }
    }

    // MARK: - Tables

    /// `devices` per SPEC §10.1. `id` is `DeviceID.rawValue`
    /// (composite VID:PID:serial — see DECISIONS.md D9). `first_seen`
    /// must NEVER be overwritten on subsequent observations of the
    /// same device — `DeviceRepository.upsert` reads the existing
    /// row and reuses its `first_seen` per F10 (Phase 2 review).
    private static func createDevicesTable(_ db: Database) throws {
        try db.execute(sql: """
        CREATE TABLE devices (
            id              TEXT PRIMARY KEY NOT NULL,
            vendor_id       INTEGER NOT NULL,
            product_id      INTEGER NOT NULL,
            serial          TEXT,
            name_resolved   TEXT NOT NULL,
            kind            TEXT NOT NULL,
            usb_version     TEXT,
            first_seen      DATETIME NOT NULL,
            last_seen       DATETIME NOT NULL
        )
        """)
        try db.execute(sql: "CREATE INDEX idx_devices_last_seen ON devices(last_seen)")
    }

    /// `events` per SPEC §10.1. `kind` is one of "attached",
    /// "detached", "diagnostic". `payload_json` carries the per-kind
    /// extras (diagnostic detail, link speed, watts at the moment of
    /// the event, etc.) so the schema doesn't grow per new field.
    private static func createEventsTable(_ db: Database) throws {
        try db.execute(sql: """
        CREATE TABLE events (
            id              INTEGER PRIMARY KEY AUTOINCREMENT,
            ts              DATETIME NOT NULL,
            kind            TEXT NOT NULL,
            device_id       TEXT,
            port_id         TEXT NOT NULL,
            payload_json    TEXT NOT NULL,
            FOREIGN KEY (device_id) REFERENCES devices(id) ON DELETE SET NULL
        )
        """)
        try db.execute(sql: "CREATE INDEX idx_events_ts ON events(ts)")
        try db.execute(sql: "CREATE INDEX idx_events_device_id ON events(device_id)")
    }

    /// `samples` per SPEC §10.1. `aggregation` is "raw" / "1min" /
    /// "1hour" — `DownsamplingJob` reads raw, writes 1min, deletes
    /// raw past retention; same loop for 1min → 1hour.
    private static func createSamplesTable(_ db: Database) throws {
        try db.execute(sql: """
        CREATE TABLE samples (
            id              INTEGER PRIMARY KEY AUTOINCREMENT,
            ts              DATETIME NOT NULL,
            device_id       TEXT,
            port_id         TEXT NOT NULL,
            watts           REAL,
            mbps            INTEGER,
            aggregation     TEXT NOT NULL DEFAULT 'raw',
            FOREIGN KEY (device_id) REFERENCES devices(id) ON DELETE SET NULL
        )
        """)
        try db.execute(sql: "CREATE INDEX idx_samples_ts ON samples(ts)")
        try db.execute(sql: "CREATE INDEX idx_samples_device_ts ON samples(device_id, ts)")
        try db.execute(sql: "CREATE INDEX idx_samples_aggregation ON samples(aggregation)")
    }

    /// `schema_metadata` per SPEC §10.1. We don't strictly need this
    /// table because GRDB's own `grdb_migrations` tracks applied
    /// migrations, but the SPEC's `schema_version = '1'` row exists
    /// for tools that want to read the version without going through
    /// GRDB's API (CLI dumps, recovery scripts, etc.).
    private static func createSchemaMetadataTable(_ db: Database) throws {
        try db.execute(sql: """
        CREATE TABLE schema_metadata (
            key             TEXT PRIMARY KEY,
            value           TEXT NOT NULL
        )
        """)
        try db.execute(sql: """
        INSERT INTO schema_metadata (key, value) VALUES ('schema_version', '1')
        """)
    }
}
