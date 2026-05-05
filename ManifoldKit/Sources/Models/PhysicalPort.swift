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
// PhysicalPort.swift
//
// One physical port on the host chassis (USB-C@1, USB-C@2, MagSafe).
// Distinct from `Port`, which represents a *connected* USB/TB device
// at a registry path. Some IOKit USB-C ports have a CC contract
// (cable plugged in) but no USB device descriptor exchange — power-
// only sinks. `Port` only covers the data-enumerated case;
// `PhysicalPort` covers all four chassis ports including the empty
// and power-only states.
//
// Source: `AppleTCControllerType10` registry entries under
// `AppleHPMDevice`. `ConnectionActive` indicates a cable is detected;
// `TransportsActive` lists the protocols negotiated on the cable
// ("CC" only → power-only, "CC, USB2" / "CC, USB2, USB3" → data).

public struct PhysicalPort: Identifiable, Hashable, Sendable, Codable {

    /// 1-indexed chassis port number. Matches IOKit's
    /// `ParentBuiltInPortNumber` so port 1 = leftmost / topmost as
    /// the user sees it on the laptop.
    public let position: Int

    /// Connector kind. Distinct from `PortKind` because a physical
    /// port has different state shapes than a `Port`: a USB-C
    /// chassis port can be empty even though the data tree has no
    /// matching `Port`. Restricted to the kinds the walker can
    /// classify; everything else falls through to `.unknown`.
    public let kind: PhysicalPortKind

    /// What the OS sees on this port right now.
    public let state: OccupancyState

    /// Stable id derived from position + kind so SwiftUI ForEach can
    /// key on it. There's never more than one chassis port at a given
    /// (position, kind) pair on a host.
    public var id: String { "\(kind.rawValue)#\(position)" }

    public init(position: Int, kind: PhysicalPortKind, state: OccupancyState) {
        self.position = position
        self.kind = kind
        self.state = state
    }

    /// Connector kind for a chassis port. A separate type from
    /// `PortKind` because chassis-level connectors don't include the
    /// hub-downstream kinds (a hub cannot be a chassis port).
    public enum PhysicalPortKind: String, Sendable, Codable, CaseIterable {
        case usbC
        case magsafe
        /// Built-in SD card reader (Apple Silicon MacBook Pro 14"/16").
        /// Source: `AppleSDXCSlot` registry entries — see
        /// `SDCardSlotWalker.swift`. Distinct from `usbC` because the
        /// SD chip strip in `PortOccupancyView` renders a glyph instead
        /// of a position number, and the row ordering in
        /// `PortGraph.displayableRootPorts` puts SD between occupied
        /// USB-C and empty USB-C.
        case sd
        case unknown
    }

    /// What's plugged into the chassis port, as far as the OS can tell.
    ///
    /// - `empty`: no cable detected (`ConnectionActive = No`).
    /// - `dataDevice`: a USB or TB device is enumerating on this port.
    ///   The device itself appears in the `Host.ports` tree.
    /// - `powerOnly`: cable detected (`ConnectionActive = Yes`) but
    ///   only the CC transport is active — a USB-PD power sink with
    ///   no USB data enumeration. Tape measures, dumb battery packs,
    ///   chargers in pass-through mode. Not in the `Host.ports` tree
    ///   because there's no USB descriptor; this state is the only
    ///   surface we can give the user for these.
    /// - `unknown`: the walker couldn't classify the cable's state.
    ///   Reserved so a future IOKit schema change doesn't force a
    ///   binary-incompatible Codable shape.
    public enum OccupancyState: String, Sendable, Codable, CaseIterable {
        case empty
        case dataDevice
        case powerOnly
        case unknown
    }
}
