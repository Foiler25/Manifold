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

/// One PDO (Power Data Object) advertised by the connected source.
public struct PowerOption: Hashable {
    public let voltageMV: Int
    public let maxCurrentMA: Int
    public let maxPowerMW: Int

    public init(voltageMV: Int, maxCurrentMA: Int, maxPowerMW: Int) {
        self.voltageMV = voltageMV
        self.maxCurrentMA = maxCurrentMA
        self.maxPowerMW = maxPowerMW
    }

    public var voltsLabel: String {
        String(format: "%.0fV", Double(voltageMV) / 1000)
    }
    public var ampsLabel: String {
        String(format: "%.2fA", Double(maxCurrentMA) / 1000)
    }
    public var wattsLabel: String {
        String(format: "%.0fW", Double(maxPowerMW) / 1000)
    }
}

/// A power source advertised on a USB-C / MagSafe port (parsed from
/// `IOPortFeaturePowerSource`). One port may have multiple sources
/// (e.g. "USB-PD" + "Brick ID").
public struct PowerSource: Identifiable, Hashable {
    public let id: UInt64
    public let name: String                // "USB-PD", "Brick ID"
    public let parentPortType: Int         // 0x2 = USB-C, 0x11 = MagSafe 3
    public let parentPortNumber: Int
    public let options: [PowerOption]
    public let winning: PowerOption?
    /// HPM controller UUID for this port, captured by walking the IOKit
    /// parent chain from the `IOPortFeaturePowerSource` node up through the
    /// HPM interface to the HPM device (`AppleHPMDevice` / `AppleHPMDeviceHALType3`).
    /// Internal join key only. Never serialised to JSON or text output.
    public let hpmControllerUUID: String?
    /// True when this source was built by `PowerSourceSynthesis` from
    /// `AppleSmartBattery`'s `PortControllerInfo` rather than read from a
    /// real `IOPortFeaturePowerSource` node (issue #401: macOS never
    /// creates that node for USB-C on M1 Pro/Max/Ultra). Defaults to false
    /// so every existing call site and fixture keeps working unchanged.
    public let isSynthesized: Bool

    public init(
        id: UInt64,
        name: String,
        parentPortType: Int,
        parentPortNumber: Int,
        options: [PowerOption],
        winning: PowerOption?,
        hpmControllerUUID: String? = nil,
        isSynthesized: Bool = false
    ) {
        self.id = id
        self.name = name
        self.parentPortType = parentPortType
        self.parentPortNumber = parentPortNumber
        self.options = options
        self.winning = winning
        self.hpmControllerUUID = hpmControllerUUID
        self.isSynthesized = isSynthesized
    }

    public var maxPowerMW: Int {
        if let max = options.map(\.maxPowerMW).max(), max > 0 {
            return max
        }
        return winning?.maxPowerMW ?? 0
    }

    /// Match key joining a power source to its port.
    public var portKey: String { "\(parentPortType)/\(parentPortNumber)" }

    /// Canonical in-session join key: normalised UUID (32 lowercase hex chars)
    /// when one was captured, else `portKey`. Mirrors `AppleHPMInterface.canonicalJoinKey`.
    /// Internal only; never expose in JSON or text output.
    public var canonicalJoinKey: String {
        if let uuid = hpmControllerUUID {
            let normalised = uuid.replacingOccurrences(of: "-", with: "").lowercased()
            if normalised.count == 32 { return normalised }
        }
        return portKey
    }
}

extension PowerSource {
    /// True when this source belongs to the same physical port as `port`.
    ///
    /// Matching is UUID-based when both sides resolved a UUID (M3+, guaranteed
    /// correct: distinct HPM controller dies have distinct UUIDs). Falls back to
    /// `portKey` comparison when either side is missing a UUID (M1/M2, or a
    /// defensive nil from an unusual registry layout). The fallback preserves
    /// existing behaviour on hardware that predates the UUID probe.
    ///
    /// A source that fails to resolve a UUID while the port has one is NOT
    /// silently dropped: `canonicalJoinKey` falls back to `portKey` on the
    /// source side, so it still matches the port's `portKey` fallback, and
    /// the match still fires as long as `ParentPortType/Number` agrees.
    public func canonicallyMatches(port: AppleHPMInterface) -> Bool {
        guard let portKey = port.portKey else { return false }
        // When both sides have a UUID, compare them directly. This is the
        // collision-proof path on M3+.
        if let sourceUUID = hpmControllerUUID,
           let portUUID = port.hpmControllerUUID {
            let sn = sourceUUID.replacingOccurrences(of: "-", with: "").lowercased()
            let pn = portUUID.replacingOccurrences(of: "-", with: "").lowercased()
            if sn.count == 32 && pn.count == 32 { return sn == pn }
        }
        // Fallback: compare portKey strings. Works correctly on M1/M2 where
        // MagSafe and USB-C portKeys already differ by type prefix (17/ vs 2/).
        return self.portKey == portKey
    }

    public static func preferredChargingSource(in sources: [PowerSource]) -> PowerSource? {
        sources.first { $0.name == "USB-PD" }
            ?? sources.first { $0.name == "Brick ID" }
    }

    /// True when these sources hold a live, negotiated charging contract,
    /// meaning the Mac is actually drawing power through this port (a
    /// `winning` PDO with positive wattage). A charger that is merely
    /// connected and advertising capability, but that the Mac has not
    /// chosen to draw from, returns false. Used to tell a standby second
    /// charger apart from one whose negotiation is still in progress.
    public static func hasLiveChargingContract(in sources: [PowerSource]) -> Bool {
        guard let source = preferredChargingSource(in: sources),
              let winning = source.winning else { return false }
        return winning.maxPowerMW > 0
    }
}

extension AppleHPMInterface {
    public var portKey: String? {
        guard let n = portNumber else { return nil }
        let rawType: Int
        if portTypeDescription?.hasPrefix("MagSafe") == true {
            rawType = 0x11
        } else {
            rawType = rawProperties["PortType"].flatMap { Int($0) } ?? 0x2
        }
        return "\(rawType)/\(n)"
    }

    /// The canonical in-session join key for this port.
    ///
    /// When `hpmControllerUUID` is present, this is the UUID with dashes
    /// stripped and lowercased (32 hex chars) -- the same normalised form
    /// `HPMPortUUIDMap` uses. When absent (M1/M2 or defensive nil), it falls
    /// back to `portKey` so every port still has a key.
    ///
    /// **Internal only.** This value must never appear in JSON, text output,
    /// or the UI. Use `portKey` for all user-visible output.
    ///
    /// Two ports that share the same `@N` suffix but belong to different
    /// physical connectors (MagSafe@1 and USB-C@1, both wired to separate
    /// HPM controller dies) carry distinct UUIDs. Their canonical join keys
    /// are therefore distinct even when their `portKey` values would agree.
    public var canonicalJoinKey: String? {
        if let uuid = hpmControllerUUID {
            let normalised = uuid.replacingOccurrences(of: "-", with: "").lowercased()
            if normalised.count == 32 { return normalised }
        }
        return portKey
    }
}
