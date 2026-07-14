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
// DatabaseManager.swift
//
// Per SPEC §10 — opens (or creates) the SQLite database, runs all
// pending migrations, and exposes the underlying GRDB `DatabasePool`
// to the three repositories. `compact()` (vacuum) is exposed for
// the Settings "compact database now" affordance.
//
// Storage location deviation: SPEC §10 implies an App Group container
// path, but Phase 0 deferred App Group entitlement to Phase 13 (per
// `Manifold.entitlements`'s comment) because adding it breaks the
// ad-hoc-signing flow per DECISIONS.md D11. Phase 10 stores the DB
// in `~/Library/Application Support/com.Loofa.Manifold/manifold.sqlite`
// instead — the GRDB store is single-process anyway (the widget reads
// `snapshot.json` via App Group per SPEC §12, not the SQLite file).
// Documented as a Phase-10 deviation; Phase 13's App Group enablement
// can choose to migrate the DB or leave it where it is.

import Foundation
import GRDB
import os

@MainActor
final class DatabaseManager {

    /// Underlying connection pool. `internal` so the three repository
    /// actors can construct themselves with it. Repositories own all
    /// SQL; this class only owns lifecycle + migrations.
    let dbPool: DatabasePool

    /// Resolved on-disk URL for the database file. Exposed so the
    /// HistoryPane "database size" affordance can `attributesOfItem`
    /// the file; tests can also use it to verify migrations created
    /// the file shape they expect.
    let databaseURL: URL

    /// Init opens (or creates) the database and runs every migration.
    /// `directory` is injectable so tests use a `tmp` dir without
    /// touching the production path.
    init(directory: URL? = nil) throws {
        let dir = try directory ?? Self.defaultDirectory()
        try FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true,
            attributes: nil
        )
        let url = dir.appendingPathComponent("manifold.sqlite")
        self.databaseURL = url
        // GRDB's DatabasePool wraps SQLite in WAL mode by default,
        // which is what we want — concurrent reads + serialised writes
        // matches the actor-per-repository pattern.
        self.dbPool = try DatabasePool(path: url.path)
        try Self.migrator.migrate(dbPool)
        Log.app.notice("Database opened at \(url.path, privacy: .public)")
    }

    /// One-shot vacuum. SQLite's `VACUUM` rebuilds the file in place,
    /// reclaiming space from deleted rows. Called from the HistoryPane
    /// "compact database now" button.
    ///
    /// Why `barrierWriteWithoutTransaction`: SQLite refuses to VACUUM
    /// from inside a transaction (which is what GRDB's default
    /// `write { … }` block opens). The barrier variant blocks until
    /// other readers drain, then runs the closure with no surrounding
    /// BEGIN/COMMIT — the right shape for VACUUM, REINDEX, and
    /// `PRAGMA journal_mode` mutations.
    func compact() async throws {
        try await dbPool.barrierWriteWithoutTransaction { db in
            try db.execute(sql: "VACUUM")
        }
    }

    // MARK: - On-disk size

    /// Total bytes occupied by the database file (plus its WAL +
    /// shm sidecars when present). Returned as a single number so
    /// the HistoryPane can format it via `ByteCountFormatter`.
    func onDiskSize() -> Int64 {
        let fm = FileManager.default
        let candidates = [
            databaseURL,
            databaseURL.appendingPathExtension("wal"),
            databaseURL.appendingPathExtension("shm")
        ]
        return candidates.reduce(0) { acc, url in
            guard let attrs = try? fm.attributesOfItem(atPath: url.path),
                  let size = attrs[.size] as? Int64 else { return acc }
            return acc + size
        }
    }

    // MARK: - Migration registry

    /// Append-only migration list per SPEC §10.1: *"Migrations are
    /// append-only forever. V1 stays untouched. V2+ add new files in
    /// `Migrations/`."* Each migration registers itself by stable
    /// identifier; GRDB tracks which have run via the
    /// `grdb_migrations` table.
    private static let migrator: DatabaseMigrator = {
        var migrator = DatabaseMigrator()
        // Disable foreign keys during migration setup is GRDB's
        // default; we leave it on for V1 because the FKs (events ↔
        // devices, samples ↔ devices) are part of the schema we want
        // enforced from the start.
        V1Initial.register(in: &migrator)
        V2CableHistory.register(in: &migrator)
        return migrator
    }()

    // MARK: - Default storage directory

    /// `~/Library/Application Support/com.Loofa.Manifold/`. Phase 13
    /// may revisit if/when the App Group container becomes available.
    private static func defaultDirectory() throws -> URL {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return appSupport.appendingPathComponent("com.Loofa.Manifold", isDirectory: true)
    }
}
