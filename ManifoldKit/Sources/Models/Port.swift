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
// Port.swift
//
// One physical port on a host (or one downstream port on a hub/TB
// device). Per SPEC.md §4.3.
//
// Why `children` not `parentID` only: the popover and topology canvas
// render hierarchically, and `OutlineGroup` needs a `children` keypath
// it can recurse on. `parentID` is kept too for the rare cases where a
// caller has only the leaf and needs to walk up — Phase 8's
// daisy-chain depth rule, for example.

// No Foundation types referenced — only ManifoldKit types and the
// stdlib's `Int`/`String`/`Array`.

// MARK: - PortKind

/// Physical port classification. Exhaustive for what the discovery
/// walkers can identify; everything else falls through to `.unknown`
/// rather than throwing, so a strange display adapter doesn't break
/// the whole walk. Phase 7 expands the set if Thunderbolt-specific
/// kinds become visible.
public enum PortKind: String, Sendable, Codable, CaseIterable {
    case usbA, usbC, thunderbolt, hdmi, sd, audio, ethernet, magsafe, unknown
}

// MARK: - Port

public struct Port: Identifiable, Hashable, Sendable, Codable {

    /// Stable port identifier — derived from the IOKit registry path
    /// per DECISIONS.md D9. Stays constant across replug events on
    /// this physical port.
    public let id: PortID

    /// 1-indexed display position ("P1", "P2", …). Comes from IOKit's
    /// `PortNum` where available; falls back to discovery order when
    /// the property is missing.
    public let position: Int

    /// Connector type. Drives the popover's icon and Phase 8's
    /// connector-specific diagnostic rules.
    public let kind: PortKind

    /// Parent port if this is downstream of a hub or TB device, nil
    /// for host-rooted ports. Phase 2 sets this from the locationID
    /// nibble structure.
    public let parentID: PortID?

    /// The device currently plugged into this port, or nil if empty.
    /// A hub appearing here is itself a Device (`kind = .hub`); its
    /// downstream devices live in `children[*].connectedDevice`.
    public let connectedDevice: Device?

    /// Negotiated link characteristics if the OS reports them. nil for
    /// empty ports and for some non-USB connectors.
    public let negotiated: LinkSpeed?

    /// This port's own draw, ignoring downstream children. Use
    /// `totalDraw` for the recursive sum.
    public let powerDraw: Watts?

    /// Per-port budget the host advertises to the connected device,
    /// in watts. Phase 8's `PowerDeficitRule` fires when
    /// `powerDraw > availablePower` (a device asking for more than
    /// the port can supply). nil → port doesn't advertise a budget;
    /// the rule treats absent budget as "infinite" and skips firing.
    public let availablePower: Watts?

    /// Downstream ports for hubs / TB daisy chains. Empty for ports
    /// that cannot have children (USB-A, SD card slot, etc.).
    public let children: [Port]

    /// Recursive sum: this port's draw plus every descendant port's
    /// draw. Used by Phase 8's hub-overcommit rule and by the popover's
    /// per-host total. Computed (no cache) so the value stays consistent
    /// as the tree mutates.
    public var totalDraw: Watts {
        let me = powerDraw?.value ?? 0
        let kids = children.reduce(0.0) { $0 + $1.totalDraw.value }
        return Watts(me + kids)
    }

    public init(
        id: PortID,
        position: Int,
        kind: PortKind,
        parentID: PortID?,
        connectedDevice: Device?,
        negotiated: LinkSpeed?,
        powerDraw: Watts?,
        availablePower: Watts? = nil,
        children: [Port]
    ) {
        self.id = id
        self.position = position
        self.kind = kind
        self.parentID = parentID
        self.connectedDevice = connectedDevice
        self.negotiated = negotiated
        self.powerDraw = powerDraw
        self.availablePower = availablePower
        self.children = children
    }
}
