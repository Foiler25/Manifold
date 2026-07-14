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
// Portions of this file derive from WhatCable
// (https://github.com/darrylmorley/whatcable) by Darryl Morley,
// originally distributed under the MIT licence. See
// `Manifold/Sources/Cables/ATTRIBUTION.md` for the full original
// copyright + permission notice.
//
// ─────────────────────────────────────────────────────────────────────
public import Foundation
import SQLite3

/// Read-only SQLite-backed lookup for vendors and known cables.
///
/// Loaded lazily on first use from the bundled `whatcable.db`. All rows
/// are read into in-memory dictionaries on init, then the database handle
/// is closed. For ~14k vendors and a handful of cables this is a few
/// hundred KB of resident memory, same as the old TSV loader.
///
/// Uses the system SQLite3 C API (a macOS system framework), so there's
/// no SPM dependency to add.
public enum CableDB {
    /// Vendor entry with provenance tracking.
    struct VendorEntry: Sendable {
        let name: String
        /// "usbif", "usbids", or "manual".
        let source: String
    }

    private static let store: Store = Store.load()

    /// Look up a vendor name by VID. Returns names from any source
    /// (USB-IF, usb.ids, manual). Returns nil for unknown VIDs and
    /// for VID 0 (which is filtered at the presentation layer by
    /// `VendorDB`, not here).
    public static func vendorName(vid: Int) -> String? {
        store.vendors[vid]?.name
    }

    /// True only if the VID is in USB-IF's official published list.
    /// Used by `CableTrustReport` to decide whether to fire the
    /// `vidNotInUSBIFList` flag. A VID present via usb.ids or manual
    /// override returns false here, preserving the trust signal
    /// semantics.
    public static func isUSBIFRegistered(_ vid: Int) -> Bool {
        store.vendors[vid]?.source == "usbif"
    }

    /// Look up known cables by identity: the (VID, PID) pair.
    ///
    /// Identity is the VID + PID only. The Cable VDO is deliberately NOT
    /// part of the key: it encodes capability (speed / power / type), not
    /// identity, and the same VDO is shared by unrelated brands (a generic
    /// "USB 2.0 / 100 W" VDO appears across Anker, iottie, Statik, and many
    /// more). Keying a brand/model match on it mislabels cables. See #239.
    ///
    /// A cable missing either half of its identity cannot be pinned to a
    /// brand, so a zero VID or zero PID returns an empty array. (A non-zero
    /// VID with a zero PID still resolves the silicon vendor via VendorDB,
    /// but never a curated retail brand.) The all-zero case (#161) is
    /// covered by the same guard.
    ///
    /// Multiple entries can still share one (VID, PID) when the same product
    /// was reported more than once; the caller decides how to present them.
    public static func curatedCables(
        vid: Int,
        pid: Int
    ) -> [CuratedCable] {
        guard vid != 0, pid != 0 else { return [] }
        return store.cables[CableKey(vid: vid, pid: pid)] ?? []
    }

    /// Number of vendor entries loaded. Exposed for tests.
    public static var vendorCount: Int { store.vendors.count }

    /// Total number of cable entries loaded (counts every row, not
    /// unique fingerprints). Exposed for tests.
    public static var cableCount: Int {
        store.cables.values.reduce(0) { $0 + $1.count }
    }

    /// Number of distinct (VID, PID, Cable VDO) fingerprints.
    public static var fingerprintCount: Int { store.cables.count }
}

/// A cable identified by user reports and curated into the database.
public struct CuratedCable: Sendable {
    public let brand: String
    public let speed: String
    public let power: String
    public let type: String
    public let issueURL: String
}

// MARK: - Internal types

private struct CableKey: Hashable, Sendable {
    let vid: Int
    let pid: Int
}

private struct Store: Sendable {
    let vendors: [Int: CableDB.VendorEntry]
    let cables: [CableKey: [CuratedCable]]

    static func load() -> Store {
        guard let url = Bundle.main.url(forResource: "whatcable", withExtension: "db")
                ?? findResourceURL(name: "whatcable", ext: "db") else {
            return Store(vendors: [:], cables: [:])
        }

        var db: OpaquePointer?
        defer { sqlite3_close(db) } // sqlite3_close(nil) is a documented no-op
        guard sqlite3_open_v2(
            url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil
        ) == SQLITE_OK else {
            return Store(vendors: [:], cables: [:])
        }
        guard let db else {
            return Store(vendors: [:], cables: [:])
        }

        let vendors = loadVendors(db: db)
        let cables = loadCables(db: db)

        return Store(vendors: vendors, cables: cables)
    }

    private static func loadVendors(db: OpaquePointer) -> [Int: CableDB.VendorEntry] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(
            db, "SELECT vid, name, source FROM vendors", -1, &stmt, nil
        ) == SQLITE_OK else {
            return [:]
        }
        defer { sqlite3_finalize(stmt) }

        var map: [Int: CableDB.VendorEntry] = [:]
        map.reserveCapacity(15000)

        while sqlite3_step(stmt) == SQLITE_ROW {
            let vid = Int(sqlite3_column_int(stmt, 0))
            guard let namePtr = sqlite3_column_text(stmt, 1),
                  let sourcePtr = sqlite3_column_text(stmt, 2) else { continue }
            let name = String(cString: namePtr)
            let source = String(cString: sourcePtr)
            map[vid] = CableDB.VendorEntry(name: name, source: source)
        }
        return map
    }

    private static func loadCables(db: OpaquePointer) -> [CableKey: [CuratedCable]] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(
            db, """
            SELECT vid, pid, cable_vdo, brand, speed, power, type, issue_url
            FROM cables
            ORDER BY vid, pid, cable_vdo, brand
            """,
            -1, &stmt, nil
        ) == SQLITE_OK else {
            return [:]
        }
        defer { sqlite3_finalize(stmt) }

        var map: [CableKey: [CuratedCable]] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            let vid = Int(sqlite3_column_int(stmt, 0))
            let pid = Int(sqlite3_column_int(stmt, 1))
            // Column 2 (cable_vdo) is intentionally not read into the key:
            // identity is (VID, PID) only. The column stays in the DB for the
            // website catalog and reference. See #239.
            guard let brandPtr = sqlite3_column_text(stmt, 3) else { continue }

            let key = CableKey(vid: vid, pid: pid)
            map[key, default: []].append(CuratedCable(
                brand: String(cString: brandPtr),
                speed: sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? "",
                power: sqlite3_column_text(stmt, 5).map { String(cString: $0) } ?? "",
                type: sqlite3_column_text(stmt, 6).map { String(cString: $0) } ?? "",
                issueURL: sqlite3_column_text(stmt, 7).map { String(cString: $0) } ?? ""
            ))
        }
        return map
    }
}

// MARK: - Resource resolution

/// Find a bundled resource in Manifold's app or test-host bundle. The Cables
/// sources are part of the app target rather than a SwiftPM resource bundle,
/// so resources are loaded through `Bundle.main` (with the containing bundle
/// retained as a test-host fallback).
func findResourceURL(name: String, ext: String) -> URL? {
    let fm = FileManager.default

    var roots: [URL] = []

    if let r = Bundle.main.resourceURL { roots.append(r) }
    if let r = Bundle(for: BundleFinder.self).resourceURL { roots.append(r) }
    roots.append(Bundle.main.bundleURL)
    roots.append(Bundle.main.bundleURL.deletingLastPathComponent())
    roots.append(Bundle(for: BundleFinder.self).bundleURL.deletingLastPathComponent())

    if let exe = Bundle.main.executableURL {
        let parent = exe.deletingLastPathComponent()
        let contents = parent.deletingLastPathComponent()
        roots.append(contents.appendingPathComponent("Resources"))
    }

    for root in roots {
        let loose = root.appendingPathComponent("\(name).\(ext)")
        if fm.fileExists(atPath: loose.path) { return loose }

        let mirrored = root
            .appendingPathComponent("Cables")
            .appendingPathComponent("Resources")
            .appendingPathComponent("\(name).\(ext)")
        if fm.fileExists(atPath: mirrored.path) { return mirrored }
    }
    return nil
}

private final class BundleFinder {}
