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

/// USB-IF vendor name lookup, backed by the bundled USB-IF list shipped
/// in `Sources/WhatCableCore/Resources/usbif-vendors.tsv` (refreshed by
/// `scripts/update-vendor-db.sh`).
///
/// A `curatedOverrides` escape hatch is kept available for the rare
/// cases where USB-IF's published name is genuinely wrong, mojibake'd,
/// or unintelligible. The default policy is **don't add overrides**.
/// Trust upstream; if you're tempted to shorten "Anker Innovations
/// Limited" to "Anker", don't, the longer form is accurate. Past
/// curated entries drifted out of date (e.g. `0x103C` was labelled
/// "HP" in the curated map but is registered to AMX Corp. per
/// USB-IF, and we shipped that wrong label for months).
public enum VendorDB {
    /// Override map. Empty by default. Add an entry only when the
    /// upstream USB-IF name is materially wrong or unusable, not
    /// merely verbose.
    private static let curatedOverrides: [Int: String] = [:]

    public static func name(for vendorID: Int) -> String? {
        if let override = curatedOverrides[vendorID] { return override }
        // 0xFFFF is the USB-PD spec-defined "no vendor ID assigned"
        // sentinel (PID forced to 0). Surface that neutrally rather
        // than letting it look unregistered.
        if vendorID == 0xFFFF {
            return "No vendor ID assigned (USB-PD spec sentinel)"
        }
        return USBIFVendors.name(for: vendorID)
    }

    /// True if the VID is present in either the override map or the
    /// bundled USB-IF list. Distinct from `name(for:) != nil` only for
    /// VID 0 (which the bundled lookup hides for display purposes but
    /// is still considered "registered" — USB-IF assigns 0 to itself)
    /// and the spec sentinel `0xFFFF`, which we name but treat as not
    /// a registered assignment.
    public static func isRegistered(_ vendorID: Int) -> Bool {
        if curatedOverrides[vendorID] != nil { return true }
        if vendorID == 0xFFFF { return false }
        return USBIFVendors.isRegistered(vendorID)
    }

    /// Returns "Apple (0x05AC)" if known, else "0x05AC".
    public static func label(for vendorID: Int) -> String {
        if let n = name(for: vendorID) {
            return "\(n) (0x\(String(format: "%04X", vendorID)))"
        }
        return "0x\(String(format: "%04X", vendorID))"
    }
}
