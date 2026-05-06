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

/// Discover Identity response from a USB-PD endpoint, parsed from
/// `IOPortTransportComponentCCUSBPDSOP` services.
public struct PDIdentity: Identifiable, Hashable {
    public enum Endpoint: String {
        case sop = "SOP"        // Port partner (the connected device/charger)
        case sopPrime = "SOP'"  // Cable's near-side e-marker
        case sopDoublePrime = "SOP''" // Cable's far-side e-marker
        case unknown
    }

    public let id: UInt64
    public let endpoint: Endpoint
    public let parentPortType: Int
    public let parentPortNumber: Int
    public let vendorID: Int
    public let productID: Int
    public let bcdDevice: Int
    public let vdos: [UInt32]
    public let specRevision: Int

    public init(
        id: UInt64,
        endpoint: Endpoint,
        parentPortType: Int,
        parentPortNumber: Int,
        vendorID: Int,
        productID: Int,
        bcdDevice: Int,
        vdos: [UInt32],
        specRevision: Int
    ) {
        self.id = id
        self.endpoint = endpoint
        self.parentPortType = parentPortType
        self.parentPortNumber = parentPortNumber
        self.vendorID = vendorID
        self.productID = productID
        self.bcdDevice = bcdDevice
        self.vdos = vdos
        self.specRevision = specRevision
    }

    public var portKey: String { "\(parentPortType)/\(parentPortNumber)" }

    public var idHeader: PDVDO.IDHeader? {
        guard let v = vdos.first else { return nil }
        return PDVDO.decodeIDHeader(v)
    }

    /// The Cert Stat VDO is at index 1. Carries the USB-IF-issued XID,
    /// or 0 for cables that haven't gone through certification.
    public var certStatVDO: PDVDO.CertStat? {
        guard endpoint == .sopPrime || endpoint == .sopDoublePrime,
              vdos.count > 1 else { return nil }
        return PDVDO.decodeCertStat(vdos[1])
    }

    /// The Cable VDO is at index 3 (VDO[3] in 1-indexed PD spec terms).
    public var cableVDO: PDVDO.CableVDO? {
        guard endpoint == .sopPrime || endpoint == .sopDoublePrime,
              vdos.count > 3 else { return nil }
        let header = idHeader
        let isActive = header?.ufpProductType == .activeCable
        return PDVDO.decodeCableVDO(vdos[3], isActive: isActive)
    }
}
