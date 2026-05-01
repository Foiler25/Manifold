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
// LinkSpeed.swift
//
// Negotiated per-port link characteristics — the protocol the device
// is actually running, plus the resulting bitrate. Per SPEC.md §4.3.
//
// Why both `protocolName` and `bitrate`: Phase 8's "Running @ USB 2.0"
// diagnostic compares protocol names directly ("the cable / hub
// downgraded a USB 3 device to USB 2"), while the popover and exports
// want the user-facing bitrate. Carrying both avoids re-parsing the
// label every time.

// No Foundation types referenced — only `String` (stdlib) and the
// ManifoldKit `Bitrate` type appear in the public API.

public struct LinkSpeed: Hashable, Sendable, Codable {

    /// Negotiated protocol label as the discovery layer resolved it:
    /// "USB 2.0", "USB 3.2", "USB4 v2", "Thunderbolt 4". Free-form
    /// string so vendor-specific protocol names (e.g. "DisplayPort
    /// Alt Mode 2.1") can flow through without an enum extension.
    public let protocolName: String

    /// Bitrate of the negotiated link. Always populated; if the
    /// discovery layer couldn't read the protocol speed it produces
    /// `Bitrate(bitsPerSecond: 0)` rather than erasing the field.
    public let bitrate: Bitrate

    public init(protocolName: String, bitrate: Bitrate) {
        self.protocolName = protocolName
        self.bitrate = bitrate
    }
}
