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
import IOKit

/// Maps each port controller's `UUID` to its physical-port key.
///
/// On Apple Silicon (all chip families: M1, M2, M3, M4, M5, Intel) every
/// USB-C / MagSafe port has a power controller (`AppleHPMDevice` base class or
/// its `AppleHPMDeviceHALType3` subclass on M3+) that carries a stable `UUID`.
/// On M3+, that same UUID is the SMC channel's `DxUI` (see ``SMCPowerReader``).
/// Matching the two ties an SMC power-OUT reading to the right physical port
/// with no index guessing, which matters because the SMC D-index and the IOKit
/// `@N` number do NOT agree (SMC `D3` can be `Port-USB-C@4`).
///
/// The UUIDs here are an internal join key only. The returned map's *values*
/// are plain port keys (`"2/4"`, `"17/1"`); the UUID keys never leave this join.
public enum HPMPortUUIDMap {
    /// `[normalised-UUID : portKey]`, e.g. `["17bd562d…fa51": "2/4"]`. UUIDs are
    /// 32 lowercase hex chars (dashes stripped) to match `SMCPortPowerChannel.uuid`.
    ///
    /// Builds the map from already-captured `AppleHPMInterface` ports when
    /// available, avoiding a second IOKit sweep. Falls back to `current()` when
    /// no ports with UUIDs are present (M1/M2 or empty set).
    public static func from(ports: [AppleHPMInterface]) -> [String: String] {
        var map: [String: String] = [:]
        for port in ports {
            guard let rawUUID = port.hpmControllerUUID else { continue }
            guard let portKey = port.portKey else { continue }
            let uuid = normalise(rawUUID)
            guard isValidNormalised(uuid) else { continue }
            if map[uuid] == nil { map[uuid] = portKey }
        }
        return map
    }

    /// Builds the map directly from IOKit. Called at startup (before ports are
    /// available) or when `from(ports:)` returns an empty map.
    ///
    /// Queries `AppleHPMDeviceHALType3`, the M3+ subclass, so **this function**
    /// returns an empty map on M1/M2. It deliberately does NOT guess a positional
    /// mapping.
    ///
    /// **Do not read that as "M1/M2 have no controller UUID". They do.** The
    /// 206-machine probe-35 corpus shows every `AppleHPMDevice` (M1/M2) port
    /// carrying one (295/295). This function simply doesn't ask for them, because
    /// it matches the subclass rather than the `AppleHPMDevice` base class.
    ///
    /// It does not need to. `from(ports:)` is the primary path and it *does* see
    /// M1/M2: it reads `AppleHPMInterface.hpmControllerUUID`, which
    /// `AppleHPMInterfaceWatcher` stamps with a class-agnostic ancestor walk
    /// (base class *or* `AppleHPMDeviceHAL*`). `PowerTelemetryWatcher.updatePorts(_:)`
    /// feeds it from every live entry point. So `current()` is the startup /
    /// no-ports-yet fallback, not the M1/M2 story.
    ///
    /// An earlier version of this comment asserted "M1/M2 do not expose this
    /// class, so the map is empty there and the caller falls back to no-per-port
    /// state". The first half is true of this function; the implication was false
    /// and it misled two separate investigations. Left explicit so it doesn't
    /// mislead a third.
    public static func current() -> [String: String] {
        var map: [String: String] = [:]

        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("AppleHPMDeviceHALType3"),
            &iterator
        ) == KERN_SUCCESS else {
            return map
        }
        defer { IOObjectRelease(iterator) }

        while case let controller = IOIteratorNext(iterator), controller != 0 {
            defer { IOObjectRelease(controller) }
            // Read the controller's own UUID, never a descendant's. The PD
            // power options in the same subtree each carry their own UUID; that
            // one identifies a PDO option, not the port.
            guard let rawUUID = readString(controller, "UUID") else { continue }
            let uuid = normalise(rawUUID)
            guard isValidNormalised(uuid) else { continue }
            guard let portKey = portKey(forController: controller) else { continue }
            // First controller wins on the off chance two report the same UUID.
            if map[uuid] == nil { map[uuid] = portKey }
        }
        return map
    }

    /// Finds the controller's physical port child (`Port-USB-C@N` /
    /// `Port-MagSafe 3@N`) and returns its `"rawType/number"` key, matching the
    /// convention used across the power pipeline (USB-C = `2`, MagSafe = `17`).
    private static func portKey(forController controller: io_service_t) -> String? {
        var childIterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(controller, kIOServicePlane, &childIterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(childIterator) }

        while case let child = IOIteratorNext(childIterator), child != 0 {
            defer { IOObjectRelease(child) }
            var name = [CChar](repeating: 0, count: 128)
            guard IORegistryEntryGetName(child, &name) == KERN_SUCCESS else { continue }
            let childName = String(cString: name)
            guard childName.hasPrefix("Port-") else { continue }

            // Port number comes from the entry's location in the service plane
            // (the "@N" suffix), falling back to a descendant "Description".
            let number = portNumber(from: child)
            guard let number else { return nil }
            let rawType = childName.contains("MagSafe") ? 0x11 : 0x2
            return "\(rawType)/\(number)"
        }
        return nil
    }

    /// The `@N` port number for a `Port-` node: its location-in-plane, or, when
    /// that is empty, the number inside a descendant `Description` like
    /// `"Port-USB-C@1/CC"`.
    private static func portNumber(from port: io_service_t) -> Int? {
        var location = [CChar](repeating: 0, count: 128)
        // The pipeline treats the location-in-plane suffix as hex (radix 16),
        // same as `wcPortIndex`, so the key here lines up with the keys
        // `resolve()` and `hpmPortKeys()` build.
        if IORegistryEntryGetLocationInPlane(port, kIOServicePlane, &location) == KERN_SUCCESS,
           let value = Int(String(cString: location), radix: 16) {
            return value
        }
        if let description = findDescriptionLocation(port, depth: 0) {
            return description
        }
        return nil
    }

    /// Walks a few levels of descendants for a `Description` containing `@N`.
    private static func findDescriptionLocation(_ service: io_service_t, depth: Int) -> Int? {
        if depth > 4 { return nil }
        if let description = readString(service, "Description"),
           let atIndex = description.firstIndex(of: "@") {
            let after = description[description.index(after: atIndex)...]
            let digits = after.prefix { $0.isHexDigit }
            if let value = Int(digits, radix: 16) { return value }
        }
        var childIterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(service, kIOServicePlane, &childIterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(childIterator) }
        while case let child = IOIteratorNext(childIterator), child != 0 {
            defer { IOObjectRelease(child) }
            if let value = findDescriptionLocation(child, depth: depth + 1) { return value }
        }
        return nil
    }

    private static func readString(_ service: io_service_t, _ key: String) -> String? {
        guard let value = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String else {
            return nil
        }
        return value
    }

    /// Strips dashes and lowercases a UUID string so it matches the SMC's raw
    /// 16-byte `DxUI` rendered as 32 hex chars.
    /// A normalised UUID is valid only if it is exactly 32 HEX characters.
    /// Length alone is not enough: a 32-char non-hex string would otherwise
    /// become a join key (Codex review, PR #403).
    static func isValidNormalised(_ uuid: String) -> Bool {
        // ASCII hex only. `Character.isHexDigit` is Unicode-aware and accepts
        // full-width forms (U+FF21 "Ａ" etc.), so 32 full-width A's would have
        // passed and become a join key. Codex review, #403.
        uuid.count == 32 && uuid.utf8.allSatisfy { c in
            (0x30...0x39).contains(c) || (0x61...0x66).contains(c) || (0x41...0x46).contains(c)
        }
    }

    static func normalise(_ uuid: String) -> String {
        uuid.replacingOccurrences(of: "-", with: "").lowercased()
    }
}
