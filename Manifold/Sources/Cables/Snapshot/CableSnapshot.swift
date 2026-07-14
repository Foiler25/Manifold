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

/// One voltage/current combo from the charger's HVC (High Voltage Charging)
/// menu. This is what the charger advertises it can deliver at the system
/// level, read from `IOPSCopyExternalPowerAdapterDetails()`. Distinct from
/// `PowerOption` (which is the per-port USB-PD negotiation result).
public struct AdapterHVCEntry: Hashable, Sendable {
    /// Voltage in millivolts (e.g. 20000 for 20V).
    public let voltageMV: Int
    /// Maximum current in milliamps (e.g. 4990 for ~5A).
    public let currentMA: Int

    public init(voltageMV: Int, currentMA: Int) {
        self.voltageMV = voltageMV
        self.currentMA = currentMA
    }

    /// Watts this entry can deliver (voltage * current).
    public var wattsInt: Int {
        Int((Double(voltageMV) * Double(currentMA) / 1_000_000).rounded())
    }

    public var label: String {
        let v = String(format: "%.0fV", Double(voltageMV) / 1000)
        let a = String(format: "%.2fA", Double(currentMA) / 1000)
        return "\(v)/\(a)"
    }
}

/// External power adapter info. Populated by the Darwin backend from
/// `IOPSCopyExternalPowerAdapterDetails()`. This is a system-wide view
/// of the connected charger brick, not a per-port reading.
public struct CableAdapterInfo: Hashable, Sendable {
    public let watts: Int?
    public let isCharging: Bool?
    public let source: String?  // "AC" / "Battery" / nil
    /// Negotiated adapter voltage in millivolts (e.g. 20000 for 20V).
    public let voltageMV: Int?
    /// Negotiated adapter current in milliamps (e.g. 4990 for ~5A).
    public let currentMA: Int?
    /// Short description from IOKit, e.g. "pd charger" or "magsafe charger".
    public let adapterDescription: String?
    /// Apple's internal power tier classification (e.g. 2 for 100W).
    public let powerTier: Int?
    /// True when the adapter is wireless (MagSafe pad, etc.).
    public let isWireless: Bool?
    /// The charger's HVC (High Voltage Charging) menu: all voltage/current
    /// combos the charger says it can deliver. Empty when not available.
    public let hvcMenu: [AdapterHVCEntry]
    /// Index into hvcMenu indicating the currently active PDO step.
    public let hvcActiveIndex: Int?
    /// Charger family code from Apple's internal classification.
    public let familyCode: Int?
    /// Unique adapter identifier.
    public let adapterID: Int?
    /// PMU (Power Management Unit) configuration value.
    public let pmuConfiguration: Int?
    /// Charger brand from the IOKit `AdapterDetails.Manufacturer` key
    /// (e.g. "Apple Inc."). Present mostly on Apple bricks. Nil when the
    /// field is absent or empty.
    public let manufacturer: String?
    /// Product name from the IOKit `AdapterDetails.Name` key (e.g.
    /// "140W USB-C Power Adapter"). Pairs with `manufacturer`. Nil when
    /// the field is absent or empty.
    public let name: String?
    /// Apple-internal model code from `AdapterDetails.Model` (e.g. "0x7019").
    /// Distinct from the `Name`; not currently surfaced to users.
    public let model: String?

    public init(
        watts: Int?,
        isCharging: Bool?,
        source: String?,
        voltageMV: Int? = nil,
        currentMA: Int? = nil,
        adapterDescription: String? = nil,
        powerTier: Int? = nil,
        isWireless: Bool? = nil,
        hvcMenu: [AdapterHVCEntry] = [],
        hvcActiveIndex: Int? = nil,
        familyCode: Int? = nil,
        adapterID: Int? = nil,
        pmuConfiguration: Int? = nil,
        manufacturer: String? = nil,
        name: String? = nil,
        model: String? = nil
    ) {
        self.watts = watts
        self.isCharging = isCharging
        self.source = source
        self.voltageMV = voltageMV
        self.currentMA = currentMA
        self.adapterDescription = adapterDescription
        self.powerTier = powerTier
        self.isWireless = isWireless
        self.hvcMenu = hvcMenu
        self.hvcActiveIndex = hvcActiveIndex
        self.familyCode = familyCode
        self.adapterID = adapterID
        self.pmuConfiguration = pmuConfiguration
        self.manufacturer = manufacturer
        self.name = name
        self.model = model
    }
}

/// One unified view of cable / port / power state at a point in time.
/// Backends produce these; CLI and GUI consume them.
// TODO: Sendable — requires AppleHPMInterface, PowerSource, USBPDSOP, USBDevice to conform first
public struct CableSnapshot: Equatable {
    public let ports: [AppleHPMInterface]
    public let powerSources: [PowerSource]
    public let identities: [USBPDSOP]
    public let usbDevices: [USBDevice]
    public let adapter: CableAdapterInfo?
    /// Top-level array of every Thunderbolt switch the host can see. Empty
    /// on machines without a Thunderbolt controller, or when IOKit returns
    /// nothing (the JSON shape adds the key but with an empty array, so
    /// downstream consumers can rely on the field always being present).
    public let thunderboltSwitches: [IOThunderboltSwitch]
    /// True on desktop Macs (Mac Studio, Mac Mini, Mac Pro) where the
    /// AppleSmartBattery node is absent or reports BatteryInstalled=false.
    /// Per-port PD diagnostics from the battery controller are unavailable.
    public let isDesktopMac: Bool
    /// Per-port federated PD identity from AppleSmartBattery's FedDetails.
    /// Empty on desktops or when nothing is connected.
    public let federatedIdentities: [FederatedIdentity]
    /// USB 3 SuperSpeed link state per port. Present only while a USB 3
    /// device is connected; the IOKit services appear and disappear
    /// dynamically with plug/unplug events.
    public let usb3Transports: [USB3Transport]
    /// Per-transport TRM (Trust and Restrict Management) state. Present
    /// only while an accessory is connected; the IOKit transport services
    /// appear and disappear dynamically with plug/unplug events.
    public let trmTransports: [TRMTransport]
    /// CIO cable capability data from the Thunderbolt transport controller.
    /// Independent of USB-PD e-marker data. Present only while a
    /// Thunderbolt link is active.
    public let cioCapabilities: [CIOCableCapability]
    /// Per-port physical layer state from the TypeC PHY controller. Shows
    /// per-lane transport mode (CIO/DisplayPort/idle), USB2 state, and DP
    /// pixel clock. One entry per physical USB-C port.
    public let typeCPhys: [AppleTypeCPhy]
    /// Per-port DisplayPort transport state (link rate, lane count, and the
    /// monitor's EDID). Present only while a display is connected; the IOKit
    /// services appear and disappear with plug/unplug. Correlated to a port
    /// via `IOPortTransportStateDisplayPort.portKey`.
    public let displayPorts: [IOPortTransportStateDisplayPort]
    /// AppleSmartBattery's FullyCharged flag. `nil` on desktop Macs / when
    /// no battery is present, so consumers never claim "battery full" on a
    /// machine that has no battery.
    public let batteryFullyCharged: Bool?
    /// AppleSmartBattery's IsCharging flag. `nil` on desktop Macs / when no
    /// battery is present. `false` while a charger is connected but macOS has
    /// paused charging (charge limit or Optimized Battery Charging), even
    /// though FullyCharged is still false.
    public let batteryIsCharging: Bool?

    public init(
        ports: [AppleHPMInterface],
        powerSources: [PowerSource],
        identities: [USBPDSOP],
        usbDevices: [USBDevice],
        adapter: CableAdapterInfo?,
        thunderboltSwitches: [IOThunderboltSwitch] = [],
        isDesktopMac: Bool = false,
        federatedIdentities: [FederatedIdentity] = [],
        usb3Transports: [USB3Transport] = [],
        trmTransports: [TRMTransport] = [],
        cioCapabilities: [CIOCableCapability] = [],
        typeCPhys: [AppleTypeCPhy] = [],
        displayPorts: [IOPortTransportStateDisplayPort] = [],
        batteryFullyCharged: Bool? = nil,
        batteryIsCharging: Bool? = nil
    ) {
        self.ports = ports
        self.powerSources = powerSources
        self.identities = identities
        self.usbDevices = usbDevices
        self.adapter = adapter
        self.thunderboltSwitches = thunderboltSwitches
        self.isDesktopMac = isDesktopMac
        self.federatedIdentities = federatedIdentities
        self.usb3Transports = usb3Transports
        self.trmTransports = trmTransports
        self.cioCapabilities = cioCapabilities
        self.typeCPhys = typeCPhys
        self.displayPorts = displayPorts
        self.batteryFullyCharged = batteryFullyCharged
        self.batteryIsCharging = batteryIsCharging
    }
}
