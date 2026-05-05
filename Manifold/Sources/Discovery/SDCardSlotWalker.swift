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
// SDCardSlotWalker.swift
//
// Walks `AppleSDXCSlot` registry entries — the IOKit class for the
// built-in SD card reader on Apple Silicon MacBook Pros (14"/16").
// Mirrors `USBCPortWalker`: the slot's properties tell us whether a
// card is inserted and (when one is) what kind it is. Macs without
// the reader (M-series Air, base 13" Pro, all Mac mini / Studio /
// Pro models) return zero matching services and we emit an empty
// snapshot list — same defensive shape as the TB walker on a non-TB
// host.
//
// IOKit keys read (verified via `ioreg -c AppleSDXCSlot` on Brandon's
// Mac):
//   - `IOUnit` (Int) — 1-indexed slot number.
//   - `ConnectionActive` (Bool) — cable / card detected at the slot.
//   - `Card Present` (Bool) — card is enumerated. Distinct from
//     `ConnectionActive`: a card mid-eject can have ConnectionActive
//     true while Card Present is already false. We trust Card Present
//     for "is there a card we can talk to" decisions.
//   - `PortTypeDescription` (String) — `"SD Card"` on this hardware.
//   - `Card Characteristics` (Dict, when card present):
//       - `Product Name` (String, e.g. `"SE32G"`)
//       - `Card Type` (String, e.g. `"SDHC"` / `"SDXC"`)
//       - `Block Count` (UInt64) — capacity in 512-byte blocks
//       - `Manufacturer ID` (Int) — vendor ID equivalent
//       - `Serial Number` (Int)
//
// The card itself appears as a child `AppleSDXCBlockStorageDevice`
// when one is inserted; that's the IOService `EventService` watches
// for hot-plug notifications.

import Foundation
import IOKit
import os
import ManifoldKit

// MARK: - SDCardSlotSnapshot

/// Phase-20 internal projection of one chassis SD card slot.
/// `PortGraphBuilder` lifts these into `Host.physicalPorts` (kind
/// `.sd`) and, when a card is present, also into `Host.ports`.
///
/// `Sendable` because the walker hops onto the `IOKitQueue` actor
/// and returns the snapshot to MainActor.
struct SDCardSlotSnapshot: Sendable, Equatable {

    /// 1-indexed slot position. There's typically only one SD slot
    /// per Mac — the field is preserved for symmetry with
    /// `USBCPortSnapshot.position` and to keep the door open for
    /// multi-slot hardware (none currently shipping).
    let position: Int

    /// True when IOKit reports a cable / card at the receptacle.
    let connectionActive: Bool

    /// True when the card has enumerated (descriptors exchanged,
    /// `Card Characteristics` populated). The trustworthy "is there
    /// a card here right now" signal — `connectionActive` alone is
    /// noisier mid-eject.
    let cardPresent: Bool

    /// `"SD Card"` on Apple Silicon MBPs. Surfaced verbatim; the
    /// builder picks the localized label.
    let portTypeDescription: String?

    /// Decoded `Card Characteristics` dict when `cardPresent == true`,
    /// nil otherwise.
    let card: SDCardCharacteristics?
}

// MARK: - SDCardCharacteristics

/// The fields we currently consume from IOKit's `Card Characteristics`
/// dict. Capacity-bearing properties are kept as raw `UInt64` block
/// counts — the builder converts to bytes when it needs to render
/// "32 GB". Optional everywhere because the dict's contents drift
/// across macOS releases and we'd rather show a partial card than
/// drop the snapshot entirely.
struct SDCardCharacteristics: Sendable, Equatable {

    /// `Product Name` field. Typically the SKU printed on the card
    /// (e.g. `"SE32G"` for a SanDisk 32GB SDHC).
    let productName: String?

    /// `Card Type` field — currently `"SDHC"` or `"SDXC"`.
    let cardType: String?

    /// `Block Count` — number of 512-byte blocks. Capacity in bytes
    /// is `blockCount * 512` (the SD spec mandates 512-byte blocks
    /// regardless of class).
    let blockCount: UInt64?

    /// `Manufacturer ID` — small integer assigned by the SD
    /// Association. `3` = SanDisk, `27` = Samsung, etc.
    let manufacturerID: UInt16?

    /// `Serial Number` formatted as a hex string. Stored as a string
    /// so DeviceID generation behaves like the USB-side serial.
    let serial: String?
}

// MARK: - SDCardSlotRegistrySource

/// Anything that can produce a flat list of `SDCardSlotSnapshot`s.
/// One live IOKit implementation; tests inject stubs returning
/// hand-built snapshots rather than fixture-replaying IOKit.
protocol SDCardSlotRegistrySource: Sendable {
    func enumerate() throws -> [SDCardSlotSnapshot]
}

// MARK: - LiveIOKitSDCardSlotSource

struct LiveIOKitSDCardSlotSource: SDCardSlotRegistrySource {

    /// `AppleSDXCSlot` is the class on M-series MacBook Pros. If a
    /// future Mac bumps the suffix, the matching dict returns zero
    /// results and the walker soft-fails to an empty list — same
    /// defensive shape as the USB-C / TB walkers.
    let matchingClassName: String

    init(matchingClassName: String = "AppleSDXCSlot") {
        self.matchingClassName = matchingClassName
    }

    func enumerate() throws -> [SDCardSlotSnapshot] {
        guard let matching = IOServiceMatching(matchingClassName) else {
            throw IOKitError.matchingDictionaryFailed
        }

        var results: [SDCardSlotSnapshot] = []
        withMatchingServices(matching) { iter in
            forEachEntry(in: iter) { entry in
                if let snapshot = Self.makeSnapshot(from: entry) {
                    results.append(snapshot)
                }
            }
        }
        // Sort by position so callers get a stable order regardless
        // of registry iteration order (matches `USBCPortWalker`).
        return results.sorted { $0.position < $1.position }
    }

    static func makeSnapshot(from entry: borrowing IOObject) -> SDCardSlotSnapshot? {
        // Position is required — without it we can't address the
        // slot. `IOUnit` is the standard place IOKit publishes a
        // unit index; AppleSDXCSlot uses it 1-indexed.
        guard let position = intProperty("IOUnit", of: entry) else {
            return nil
        }
        let connectionActive = boolProperty("ConnectionActive", of: entry) ?? false
        let cardPresent = boolProperty("Card Present", of: entry) ?? false
        let typeDesc = stringProperty("PortTypeDescription", of: entry)

        let card: SDCardCharacteristics? = cardPresent
            ? readCharacteristics(from: entry)
            : nil

        return SDCardSlotSnapshot(
            position: position,
            connectionActive: connectionActive,
            cardPresent: cardPresent,
            portTypeDescription: typeDesc,
            card: card
        )
    }

    /// Read the `Card Characteristics` dict and bridge each field
    /// individually. Returns nil only if the dict itself is missing —
    /// individual missing fields surface as nil on the result so the
    /// UI can still render whatever the OS did publish.
    private static func readCharacteristics(from entry: borrowing IOObject) -> SDCardCharacteristics? {
        guard let dict = property(
            "Card Characteristics",
            of: entry,
            as: NSDictionary.self
        ) else {
            return nil
        }

        let productName = (dict["Product Name"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmptyOrNil
        let cardType = (dict["Card Type"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmptyOrNil
        let blockCount = (dict["Block Count"] as? NSNumber)?.uint64Value
        let manufacturerID = (dict["Manufacturer ID"] as? NSNumber)?.uint16Value
        let rawSerial = (dict["Serial Number"] as? NSNumber)?.uint64Value
        // Format serial as 8-hex so it reads stably the way USB-side
        // serials do. Most SD cards publish a 32-bit serial; padding
        // is harmless for the rare 64-bit ones that show up in IOKit.
        let serial = rawSerial.map { String(format: "%08llX", $0) }

        return SDCardCharacteristics(
            productName: productName,
            cardType: cardType,
            blockCount: blockCount,
            manufacturerID: manufacturerID,
            serial: serial
        )
    }
}

// MARK: - SDCardSlotWalker

/// Adapter that owns an `SDCardSlotRegistrySource` and exposes a
/// `walk()` matching the shape of `USBWalker.walk()` /
/// `USBCPortWalker.walk()`. Production and tests share one entry point.
struct SDCardSlotWalker: Sendable {

    private let source: any SDCardSlotRegistrySource

    init(source: any SDCardSlotRegistrySource = LiveIOKitSDCardSlotSource()) {
        self.source = source
    }

    func walk() throws -> [SDCardSlotSnapshot] {
        try source.enumerate()
    }
}

// MARK: - String helper

private extension String {
    /// `nil` when the string is empty after trimming, otherwise `self`.
    /// Mirrors the helper in `IORegistryEntry+Properties.swift`; kept
    /// fileprivate here so the walker stays self-contained.
    var nonEmptyOrNil: String? { isEmpty ? nil : self }
}
