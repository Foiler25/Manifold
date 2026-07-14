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

/// Per-port federated identity from the AppleSmartBattery's FedDetails array.
/// Each entry describes the PD partner connected to a physical port, using
/// data the battery controller collects independently of the HPM/TC services.
/// Available on laptops only (the array is absent or all-zeros on desktops).
public struct FederatedIdentity: Hashable, Sendable {
    /// 1-based port index (offset in the FedDetails array + 1).
    public let portIndex: Int
    public let vendorID: Int
    public let productID: Int
    public let pdSpecRevision: Int
    /// 0 = sink, 1 = source.
    public let powerRole: Int
    public let dualRolePower: Bool
    public let externalConnected: Bool

    public init(
        portIndex: Int,
        vendorID: Int,
        productID: Int,
        pdSpecRevision: Int,
        powerRole: Int,
        dualRolePower: Bool,
        externalConnected: Bool
    ) {
        self.portIndex = portIndex
        self.vendorID = vendorID
        self.productID = productID
        self.pdSpecRevision = pdSpecRevision
        self.powerRole = powerRole
        self.dualRolePower = dualRolePower
        self.externalConnected = externalConnected
    }

    /// True when this entry represents an actual connected device (VID != 0).
    public var hasDevice: Bool { vendorID != 0 }
}
