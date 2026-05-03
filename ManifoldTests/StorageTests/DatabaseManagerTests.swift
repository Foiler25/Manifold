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
// DatabaseManagerTests.swift
//
// Pin SPEC §18 Phase 10 #1 ("V1 migration runs on fresh install")
// and #8 ("migration is forward-only"). Each test uses an isolated
// `tmp` directory so the production DB at
// `~/Library/Application Support/com.Loofa.Manifold` is never
// touched.

import XCTest
import GRDB
@testable import Manifold

@MainActor
final class DatabaseManagerTests: XCTestCase {

    private var tmpDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("manifold-tests-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmpDir)
        tmpDir = nil
        try await super.tearDown()
    }

    /// Fresh install: init creates the directory + the .sqlite file
    /// + every V1 table. Pins SPEC §18 Phase 10 #1.
    func test_freshInstall_createsAllV1Tables() async throws {
        let manager = try DatabaseManager(directory: tmpDir)
        try await manager.dbPool.read { db in
            for table in ["devices", "events", "samples", "schema_metadata"] {
                let exists = try Self.tableExists(table, in: db)
                XCTAssertTrue(exists, "Expected V1 table '\(table)' to exist")
            }
        }
    }

    /// Re-opening a pre-existing database does not re-run V1 — GRDB's
    /// migrator tracks applied migrations. Pins forward-only contract.
    func test_reopenExistingDatabase_doesNotReRunMigrations() async throws {
        // First open creates the DB.
        do {
            let manager = try DatabaseManager(directory: tmpDir)
            // Insert a sentinel row so a re-run would either error
            // (CREATE TABLE on existing) or wipe it (DROP TABLE
            // before CREATE).
            try await manager.dbPool.write { db in
                try db.execute(sql: "INSERT INTO schema_metadata (key, value) VALUES ('sentinel', 'present')")
            }
        }
        // Second open re-runs the migrator; sentinel must survive.
        let manager = try DatabaseManager(directory: tmpDir)
        let value: String? = try await manager.dbPool.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM schema_metadata WHERE key = 'sentinel'")
        }
        XCTAssertEqual(value, "present", "Re-open must not wipe pre-existing rows.")
    }

    /// `compact()` round-trips without throwing on an empty database.
    /// VACUUM on an empty DB is a no-op for size but must succeed.
    func test_compact_succeedsOnEmptyDatabase() async throws {
        let manager = try DatabaseManager(directory: tmpDir)
        try await manager.compact()
    }

    /// `onDiskSize()` returns at least the SQLite header size for a
    /// fresh database. The actual minimum is implementation-defined
    /// but always > 0.
    func test_onDiskSize_returnsPositiveAfterInit() async throws {
        let manager = try DatabaseManager(directory: tmpDir)
        // Force WAL flush + size update.
        try await manager.dbPool.write { db in
            try db.execute(sql: "INSERT INTO schema_metadata (key, value) VALUES ('x', 'y')")
        }
        XCTAssertGreaterThan(manager.onDiskSize(), 0)
    }

    /// `schema_metadata` carries the SPEC §10.1 row at version 1.
    func test_schemaMetadata_recordsVersion1() async throws {
        let manager = try DatabaseManager(directory: tmpDir)
        let version: String? = try await manager.dbPool.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM schema_metadata WHERE key = 'schema_version'")
        }
        XCTAssertEqual(version, "1")
    }

    // MARK: - Helpers

    private nonisolated static func tableExists(_ name: String, in db: Database) throws -> Bool {
        let count: Int = try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name=?",
            arguments: [name]
        ) ?? 0
        return count > 0
    }
}
