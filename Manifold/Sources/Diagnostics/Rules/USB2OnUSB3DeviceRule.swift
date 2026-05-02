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
// USB2OnUSB3DeviceRule.swift
//
// SPEC §9 rule `running-at-usb-2`. Fires when a USB 3.x-capable
// device is currently negotiated on a USB 2.0 link — the classic
// "this should be 10× faster" cable / hub problem the popover badge
// exists to surface.
//
// The trigger from SPEC:
//   device.usbVersion >= .usb3_0 && port.negotiated.protocolName == "USB 2.0"
//
// "USB 2.0" is the protocolName `USBDiscoveryConstants.speedName(for:)`
// returns for IOKit speed code 2 → matches every High Speed
// negotiation. Comparison via the protocol-name string (not bcdUSB or
// bitrate) keeps the rule decoupled from how Phase-2 derives the link
// speed and lets the same rule trigger when Phase 5+ telemetry
// renegotiates downward.

import Foundation
import ManifoldKit

struct USB2OnUSB3DeviceRule: DiagnosticRule {

    let identifier = "running-at-usb-2"
    var title: String {
        NSLocalizedString("diagnostic.running-at-usb-2.title", comment: "Diagnostic title for USB3 device on USB 2.0 link.")
    }
    let defaultSeverity: DiagnosticSeverity = .warning

    func evaluate(against hosts: [ManifoldKit.Host]) -> [Diagnostic] {
        PortTreeWalker.allPorts(in: hosts).compactMap { port in
            guard
                let device = port.connectedDevice,
                let version = device.usbVersion,
                Self.isUSB3Capable(version),
                let negotiated = port.negotiated,
                negotiated.protocolName == "USB 2.0"
            else { return nil }

            let detail = String(
                format: NSLocalizedString(
                    "diagnostic.running-at-usb-2.detail",
                    comment: "Detail. %1$@ device name, %2$@ supported USB version."
                ),
                device.name, version.rawValue
            )
            return Diagnostic(
                target: port.id,
                severity: defaultSeverity,
                ruleIdentifier: identifier,
                title: title,
                detail: detail
            )
        }
    }

    /// USB3-or-later membership check. Centralised so the comparison
    /// stays correct when Phase 9+ adds new USB versions — adding a
    /// case to `USBVersion` requires updating this list, not every
    /// rule that asks "is this a USB 3 device".
    private static func isUSB3Capable(_ version: USBVersion) -> Bool {
        switch version {
        case .usb3_0, .usb3_1, .usb3_2, .usb4, .usb4_v2:
            return true
        case .usb2_0, .unknown:
            return false
        }
    }
}
