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

/// What a USB-C device's Billboard Capability Descriptor advertises: the list
/// of Alternate Modes it declares support for (DisplayPort, Thunderbolt, ...)
/// and, per mode, whether that mode actually came up.
///
/// This is read from the device's BOS descriptor (Binary Object Store, device
/// capability type `0x0d`). It is *platform-free*: the Darwin backend reads the
/// raw bytes from IOKit and hands a parsed value in here; Core never touches
/// IOKit.
///
/// Plain-English framing: a device advertising DisplayPort Alt Mode is normal,
/// not a fault. Only a per-mode *failed* state (`unsuccessful` / `error`)
/// suggests something didn't come up. `notAttempted` stays benign: the 2-bit
/// field can't tell "never tried" apart from "was up, then exited".
public struct BillboardCapability: Codable, Hashable, Sendable {
    /// The per-mode "Alternate Mode State" from the descriptor's `bmConfigured`
    /// field (2 bits per mode). Raw values match the USB Billboard Device Class
    /// spec encoding so the backend can build them straight from the bits and
    /// the JSON stays stable.
    public enum AltModeState: Int, Codable, Hashable, Sendable {
        case error = 0          // unspecified error
        case notAttempted = 1   // not attempted, or entered then exited
        case unsuccessful = 2   // attempted but did not come up
        case configured = 3     // came up successfully

        /// True only for states that indicate a mode tried and did not come up.
        /// `notAttempted` is deliberately excluded (it is benign).
        public var isFailure: Bool {
            self == .error || self == .unsuccessful
        }
    }

    /// One advertised Alternate Mode.
    public struct AltMode: Codable, Hashable, Sendable {
        /// Standard or Vendor ID identifying the Alt Mode (e.g. `0xFF01` for
        /// DisplayPort, `0x8087` for Thunderbolt).
        public let svid: UInt16
        public let state: AltModeState

        public init(svid: UInt16, state: AltModeState) {
            self.svid = svid
            self.state = state
        }

        /// Plain-English name for well-known SVIDs, else `nil`.
        public var protocolName: String? {
            switch svid {
            case 0xFF01: return "DisplayPort"
            case 0x8087: return "Thunderbolt"
            case 0xFF00: return "USB"
            default: return nil
            }
        }
    }

    public let altModes: [AltMode]
    /// Index into `altModes` of the device's preferred mode, if the descriptor
    /// names one and it is in range. `nil` otherwise.
    public let preferredIndex: Int?

    public init(altModes: [AltMode], preferredIndex: Int? = nil) {
        self.altModes = altModes
        if let preferredIndex, altModes.indices.contains(preferredIndex) {
            self.preferredIndex = preferredIndex
        } else {
            self.preferredIndex = nil
        }
    }

    /// True when the device advertises DisplayPort Alt Mode at all (any state).
    public var advertisesDisplayPort: Bool {
        altModes.contains { $0.svid == 0xFF01 }
    }

    /// Advertised modes that named a protocol we recognise, in order. Used for
    /// the informational "advertises DisplayPort, Thunderbolt" line.
    public var namedProtocols: [String] {
        altModes.compactMap { $0.protocolName }
    }

    /// Any advertised mode in a failed state (`unsuccessful` / `error`). This is
    /// the only signal that should drive a (hedged) "this Alt Mode didn't come
    /// up" note.
    public var hasFailedAltMode: Bool {
        altModes.contains { $0.state.isFailure }
    }

    // MARK: - Parsing

    /// Parses a raw BOS (Binary Object Store) descriptor and returns the first
    /// Billboard capability (`0x0d`) it contains, or `nil` if there is none.
    ///
    /// Pure function over bytes (no IOKit), so the Darwin backend reads the raw
    /// descriptor and hands it here, and tests can feed corpus samples directly.
    public static func parse(bos: [UInt8]) -> BillboardCapability? {
        let total = bos.count
        // 5-byte BOS header; byte 1 is bDescriptorType (0x0F = BOS).
        guard total >= 5, bos[1] == 0x0F else { return nil }

        var offset = 5
        while offset + 3 <= total {
            let capLen = Int(bos[offset])
            guard capLen >= 3, offset + capLen <= total else { break }
            // bDescriptorType 0x10 = DEVICE CAPABILITY; bDevCapabilityType 0x0d = Billboard.
            if bos[offset + 1] == 0x10, bos[offset + 2] == 0x0d {
                return parseCapability(Array(bos[offset..<offset + capLen]))
            }
            offset += capLen
        }
        return nil
    }

    /// Decodes one Billboard Capability Descriptor (USB Billboard Device Class
    /// 1.2.2). Fixed header is 44 bytes, then 4 bytes per Alt Mode:
    /// `{ wSVID(2), bAlternateMode(1), iAlternateModeString(1) }`. The per-mode
    /// state lives in the 32-byte `bmConfigured` field at offset 8, two bits
    /// per mode.
    private static func parseCapability(_ cap: [UInt8]) -> BillboardCapability? {
        // Need the full 44-byte header before reading any of its fields.
        guard cap.count >= 44 else { return nil }
        let count = Int(cap[4])                   // bNumberOfAlternateModes
        // Reject truncated descriptors up front: the full alt-mode array must
        // be present, or we'd return a partial result built from whatever
        // prefix happened to fit.
        guard count > 0, cap.count >= 44 + count * 4 else { return nil }
        let preferred = Int(cap[5])              // bPreferredAlternateMode (index)
        let bmConfigured = Array(cap[8..<40])    // 2 bits per mode

        var modes: [AltMode] = []
        modes.reserveCapacity(count)
        for index in 0..<count {
            let entry = 44 + index * 4
            let svid = UInt16(cap[entry]) | (UInt16(cap[entry + 1]) << 8)
            let bits = (Int(bmConfigured[index / 4]) >> ((index % 4) * 2)) & 0x3
            let state = AltModeState(rawValue: bits) ?? .error
            modes.append(AltMode(svid: svid, state: state))
        }
        return BillboardCapability(altModes: modes, preferredIndex: preferred)
    }
}
