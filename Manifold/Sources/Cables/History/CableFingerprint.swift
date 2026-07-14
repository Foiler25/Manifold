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
// CableFingerprint.swift

import Foundation

enum CableIdentity {
    static func key(for identity: USBPDSOP) -> String? {
        guard identity.vendorID != 0, identity.productID != 0 else { return nil }
        let certificationXID = identity.certStatVDO?.xid ?? 0
        let cableVDO1 = identity.vdos.count > 3 ? identity.vdos[3] : 0
        let activeCableVDO2 = identity.vdos.count > 4 ? identity.vdos[4] : 0
        return String(
            format: "%04X:%04X:%04X:%08X:%08X:%08X",
            identity.vendorID,
            identity.productID,
            identity.bcdDevice,
            certificationXID,
            cableVDO1,
            activeCableVDO2
        )
    }

    static func cableVDORaw(for identity: USBPDSOP) -> UInt32 {
        identity.vdos.count > 3 ? identity.vdos[3] : 0
    }
}
