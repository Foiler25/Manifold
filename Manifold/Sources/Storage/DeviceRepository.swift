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
// DeviceRepository.swift
//
// Per SPEC §10.2. Owns the `devices` table.
//
// **F10 closure (Phase 2 review).** `PortGraphBuilder.makeDevice`
// stamps `firstSeen` with the current walk's timestamp on every
// observation, so writing it naively would clobber the historical
// "first observed at" value on every replug. `upsert(_:)` reads any
// existing row by `DeviceID` and reuses its `first_seen`; only the
// `last_seen` and other mutable fields update.

import Foundation
import GRDB
import ManifoldKit

actor DeviceRepository {

    private let dbPool: DatabasePool

    init(dbPool: DatabasePool) {
        self.dbPool = dbPool
    }

    // MARK: - Upsert (F10 reconcile)

    /// Insert or update `device`. If a row with this `DeviceID`
    /// already exists, its `first_seen` is preserved; everything
    /// else takes the new value. **This is the F10 closure** — see
    /// the file header.
    func upsert(_ device: Device) async throws {
        try await dbPool.write { db in
            let existingFirstSeen: Date? = try Date.fetchOne(
                db,
                sql: "SELECT first_seen FROM devices WHERE id = ?",
                arguments: [device.id.rawValue]
            )
            let resolvedFirstSeen = existingFirstSeen ?? device.firstSeen

            try db.execute(
                sql: """
                INSERT INTO devices
                    (id, vendor_id, product_id, serial, name_resolved, kind, usb_version, first_seen, last_seen)
                VALUES
                    (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    vendor_id     = excluded.vendor_id,
                    product_id    = excluded.product_id,
                    serial        = excluded.serial,
                    name_resolved = excluded.name_resolved,
                    kind          = excluded.kind,
                    usb_version   = excluded.usb_version,
                    last_seen     = excluded.last_seen
                """,
                arguments: [
                    device.id.rawValue,
                    Int64(device.vendorID),
                    Int64(device.productID),
                    device.serial,
                    device.name,
                    device.kind.rawValue,
                    device.usbVersion?.rawValue,
                    resolvedFirstSeen,
                    device.lastSeen
                ]
            )
        }
    }

    // MARK: - Reads

    /// Fetch a single device by id, or nil if not found.
    func device(id: DeviceID) async throws -> Device? {
        try await dbPool.read { db in
            try Self.fetchOne(db, sql: "SELECT * FROM devices WHERE id = ?", arguments: [id.rawValue])
        }
    }

    /// Fetch every device, ordered by most-recently-seen first. Used
    /// by the History view's device-filter drop-down.
    func allDevices() async throws -> [Device] {
        try await dbPool.read { db in
            try Self.fetchAll(db, sql: "SELECT * FROM devices ORDER BY last_seen DESC")
        }
    }

    // MARK: - Row → Device

    /// Pulled out so both `device(id:)` and `allDevices()` can share
    /// the column-by-column decode. Repository keeps the shape close
    /// to SPEC §10.1 to make the row → struct mapping greppable.
    private static func fetchOne(_ db: Database, sql: String, arguments: StatementArguments) throws -> Device? {
        guard let row = try Row.fetchOne(db, sql: sql, arguments: arguments) else {
            return nil
        }
        return makeDevice(from: row)
    }

    private static func fetchAll(_ db: Database, sql: String, arguments: StatementArguments = .init()) throws -> [Device] {
        try Row.fetchAll(db, sql: sql, arguments: arguments).map(makeDevice)
    }

    private static func makeDevice(from row: Row) -> Device {
        let id: String = row["id"]
        let vendorID: Int64 = row["vendor_id"]
        let productID: Int64 = row["product_id"]
        let serial: String? = row["serial"]
        let name: String = row["name_resolved"]
        let kindRaw: String = row["kind"]
        let usbVersionRaw: String? = row["usb_version"]
        let firstSeen: Date = row["first_seen"]
        let lastSeen: Date = row["last_seen"]
        return Device(
            id: DeviceID(id),
            name: name,
            kind: DeviceKind(rawValue: kindRaw) ?? .other,
            vendorID: UInt16(vendorID),
            productID: UInt16(productID),
            serial: serial,
            usbVersion: usbVersionRaw.flatMap(USBVersion.init(rawValue:)),
            displayInfo: nil,  // displayInfo isn't persisted in V1; rebuild from a live walk if needed
            firstSeen: firstSeen,
            lastSeen: lastSeen
        )
    }
}
