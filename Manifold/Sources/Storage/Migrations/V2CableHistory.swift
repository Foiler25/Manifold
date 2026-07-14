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
// V2CableHistory.swift

import GRDB

enum V2CableHistory {
    static let identifier = "v2.cable-history"

    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration(identifier) { db in
            try db.execute(sql: """
            CREATE TABLE saved_cables (
                id              TEXT PRIMARY KEY NOT NULL,
                nickname        TEXT,
                vendor_id       INTEGER NOT NULL,
                product_id      INTEGER NOT NULL,
                vendor_name     TEXT,
                curated_brand   TEXT,
                cable_vdo       INTEGER NOT NULL,
                first_seen      DATETIME NOT NULL,
                last_seen       DATETIME NOT NULL
            )
            """)
            try db.execute(sql: "CREATE INDEX idx_saved_cables_last_seen ON saved_cables(last_seen)")
            try db.execute(sql: """
            CREATE TABLE cable_sessions (
                id                  INTEGER PRIMARY KEY AUTOINCREMENT,
                cable_id            TEXT NOT NULL,
                port_key            TEXT NOT NULL,
                started_at          DATETIME NOT NULL,
                ended_at            DATETIME,
                verdict             TEXT NOT NULL,
                negotiated_gbps     REAL,
                negotiated_watts    INTEGER,
                observation_count   INTEGER NOT NULL,
                overcurrent_events  INTEGER NOT NULL DEFAULT 0,
                plug_events         INTEGER NOT NULL DEFAULT 0,
                FOREIGN KEY (cable_id) REFERENCES saved_cables(id) ON DELETE CASCADE
            )
            """)
            try db.execute(sql: "CREATE INDEX idx_cable_sessions_cable_started ON cable_sessions(cable_id, started_at DESC)")
            try db.execute(
                sql: "UPDATE schema_metadata SET value = '2' WHERE key = 'schema_version'"
            )
        }
    }
}
