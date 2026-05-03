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
// ExportTopologySnapshotIntentTests.swift
//
// Pin SPEC §18 Phase 12 #4: returns IntentFile carrying the
// schemaVersion-stamped JSON. Reuses Phase 11's TopologyJSONExporter
// so the wire format matches the menu-driven export.

import XCTest
import AppIntents
@testable import Manifold
import ManifoldKit

@MainActor
final class ExportTopologySnapshotIntentTests: XCTestCase {

    private var stub: StubIntentDataSource!

    override func setUp() async throws {
        try await super.setUp()
        stub = StubIntentDataSource()
        IntentEnvironment.dataSource = stub
    }

    override func tearDown() async throws {
        IntentEnvironment.dataSource = nil
        stub = nil
        try await super.tearDown()
    }

    /// Happy path: returns an `IntentFile` with `data` decoding to
    /// JSON whose top level carries `schemaVersion: 1`.
    func test_perform_returnsSchemaVersionedJSON() async throws {
        stub.hosts = [
            IntentTestFixtures.host(ports: [IntentTestFixtures.port(id: "/p1", device: IntentTestFixtures.device(name: "Mouse"))])
        ]
        let intent = ExportTopologySnapshotIntent()
        let result = try await intent.perform()
        let file = try intentValue(of: result, as: IntentFile.self)

        let parsed = try JSONSerialization.jsonObject(with: file.data) as? [String: Any]
        XCTAssertEqual(parsed?["schemaVersion"] as? Int, 1)
    }

    /// Default filename is honored when the user doesn't override.
    func test_perform_usesDefaultFilenameWhenNotOverridden() async throws {
        stub.hosts = [IntentTestFixtures.host(ports: [])]
        let intent = ExportTopologySnapshotIntent()
        let result = try await intent.perform()
        let file = try intentValue(of: result, as: IntentFile.self)
        XCTAssertEqual(file.filename, "manifold-topology.json")
    }

    /// Custom filename parameter flows through to the IntentFile.
    func test_perform_customFilename_isUsed() async throws {
        stub.hosts = [IntentTestFixtures.host(ports: [])]
        let intent = ExportTopologySnapshotIntent()
        intent.filename = "my-export-2026-05-03.json"
        let result = try await intent.perform()
        let file = try intentValue(of: result, as: IntentFile.self)
        XCTAssertEqual(file.filename, "my-export-2026-05-03.json")
    }

    /// No data source → throws `dataSourceUnavailable`. Pins the
    /// cold-launch error path so Shortcuts shows a clean message
    /// instead of a fatal-error trap.
    func test_perform_noDataSource_throwsDataSourceUnavailable() async throws {
        IntentEnvironment.dataSource = nil
        let intent = ExportTopologySnapshotIntent()
        do {
            _ = try await intent.perform()
            XCTFail("Expected throw")
        } catch let error as ExportTopologyError {
            guard case .dataSourceUnavailable = error else {
                XCTFail("Expected .dataSourceUnavailable, got \(error)")
                return
            }
        } catch {
            XCTFail("Expected ExportTopologyError, got \(error)")
        }
    }
}
