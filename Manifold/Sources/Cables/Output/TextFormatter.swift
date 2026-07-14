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

public enum TextFormatter {
    public static func render(
        ports: [AppleHPMInterface],
        sources: [PowerSource],
        identities: [USBPDSOP],
        showRaw: Bool,
        adapter: CableAdapterInfo? = nil,
        thunderboltSwitches: [IOThunderboltSwitch] = [],
        isDesktopMac: Bool = false,
        batteryFullyCharged: Bool? = nil,
        batteryIsCharging: Bool? = nil,
        federatedIdentities: [FederatedIdentity] = [],
        usb3Transports: [USB3Transport] = [],
        cioCapabilities: [CIOCableCapability] = [],
        usbDevices: [USBDevice] = [],
        displayPorts: [IOPortTransportStateDisplayPort] = [],
        builtInDisplayPorts: [BuiltInDisplayPort] = []
    ) -> String {
        if ports.isEmpty && builtInDisplayPorts.isEmpty {
            return String(localized: "No USB-C / MagSafe ports were found on this Mac.", bundle: _coreLocalizedBundle) + "\n"
        }

        var out = ""
        if isDesktopMac {
            out += ANSI.wrap(ANSI.dim, "Desktop Mac: charger identity (FedDetails) is not available (no battery controller).") + "\n\n"
        }
        let activePortCount = ports.filter { $0.connectionActive == true }.count
        // Port keys actually drawing charging power, so a connected-but-idle
        // second charger can tell another port is the active source (#264).
        let chargingPortKeys = Set(ports.compactMap { port -> String? in
            PowerSource.hasLiveChargingContract(in: filterSources(port, all: sources)) ? port.portKey : nil
        })
        // Devices behind a Thunderbolt dock or display match no physical port
        // (issue #274). Group them once: nest under the one connected
        // Thunderbolt port when unambiguous, else render flat at the end.
        let tunnelled = TunnelledDeviceGrouping.group(
            devices: usbDevices,
            ports: ports,
            thunderboltSwitches: thunderboltSwitches,
            isDesktopMac: isDesktopMac
        )
        for (i, port) in ports.enumerated() {
            if i > 0 { out += "\n" }
            let portSources = filterSources(port, all: sources)
            let wattageSource = ChargerWattageSource.resolve(
                portSources: portSources,
                activePortCount: activePortCount,
                adapter: adapter
            )
            out += renderPort(
                port,
                sources: portSources,
                identities: filterIdentities(port, all: identities),
                showRaw: showRaw,
                adapter: adapter,
                thunderboltSwitches: thunderboltSwitches,
                federatedIdentities: federatedIdentities,
                usb3Transports: usb3Transports.filter { $0.canonicallyMatches(port: port) },
                cioCapability: cioCapabilities.first { $0.canonicallyMatches(port: port) },
                chargerWattageSource: wattageSource,
                batteryFullyCharged: batteryFullyCharged,
                batteryIsCharging: batteryIsCharging,
                usbDevices: port.matchingDevices(from: usbDevices),
                displayPorts: displayPorts.filter { $0.canonicallyMatches(port: port) },
                anotherPortActivelyCharging: port.portKey.map { key in chargingPortKeys.contains { $0 != key } } ?? false
            )
            if port.serviceName == tunnelled.hostPortServiceName {
                out += renderTunnelledDevices(tunnelled.devices, nested: true)
            }
        }
        if tunnelled.hostPortServiceName == nil, !tunnelled.devices.isEmpty {
            out += renderTunnelledDevices(tunnelled.devices, nested: false)
        }
        // Front-port / internal-hub devices (issue #348). Rendered as a
        // separate block from the TB-tunnelled set above so each gets its own
        // explanatory footer. The set is already desktop-gated by group(), so
        // it is empty on a laptop and this block renders nothing there.
        if !tunnelled.internalHubDevices.isEmpty {
            out += renderInternalHubDevices(tunnelled.internalHubDevices)
        }
        // Native video sockets (today: the built-in HDMI port) come after the
        // USB-C / MagSafe group. They render only when something is plugged
        // in (the IOKit transport node has no idle representation), and they
        // carry only the display verdict: no PD, no transports, no e-marker.
        // Issue #352.
        for hdmiPort in builtInDisplayPorts {
            out += "\n" + renderBuiltInDisplayPort(hdmiPort)
        }
        return out
    }

    /// One section per native video port. Header mirrors the USB-C port header
    /// shape so terminal output stays scannable, then a Display block per
    /// attached monitor.
    private static func renderBuiltInDisplayPort(_ port: BuiltInDisplayPort) -> String {
        let label = port.serviceName
        let header = "=== \(label) (\(port.portType)) ==="
        var out = ANSI.wrap(ANSI.bold + ANSI.cyan, header) + "\n"
        // `BuiltInDisplayPort.group` filters inactive DP nodes, so the entity
        // here always carries at least one display; the empty case is
        // unreachable and intentionally absent.
        let headline = port.displays.count == 1
            ? String(localized: "Display connected", bundle: _coreLocalizedBundle)
            : String(localized: "\(port.displays.count) displays connected", bundle: _coreLocalizedBundle)
        out += ANSI.wrap(ANSI.bold, headline) + "\n"
        out += ANSI.wrap(ANSI.dim, String(localized: "Built-in \(port.portType) port \(port.portNumber)", bundle: _coreLocalizedBundle)) + "\n"
        for displayPort in port.displays {
            guard let diag = DisplayDiagnostic(dp: displayPort, cable: nil) else { continue }
            let displayColor = diag.isWarning ? ANSI.yellow : ANSI.green
            out += "\n" + ANSI.wrap(ANSI.bold, "Display: ") + ANSI.wrap(displayColor, diag.summary) + "\n"
            out += "  " + ANSI.wrap(ANSI.dim, diag.detail) + "\n"
        }
        return out
    }

    /// Render the Thunderbolt-tunnelled devices block (issue #274). When
    /// `nested`, the whole block hangs under the one connected Thunderbolt port;
    /// otherwise it is a top-level section. Either way the devices inside render
    /// as a hub tree (children indented under their hub). Empty when there are none.
    private static func renderTunnelledDevices(_ devices: [USBDevice], nested: Bool) -> String {
        guard !devices.isEmpty else { return "" }
        var out = "\n"
        let title = nested
            ? String(localized: "Connected over Thunderbolt", bundle: _coreLocalizedBundle)
            : String(localized: "Other USB devices", bundle: _coreLocalizedBundle)
        out += ANSI.wrap(ANSI.bold, title + ":") + "\n"
        let tree = USBDeviceNode.flatten(USBDeviceNode.buildTree(from: devices))
        for node in tree {
            let indent = String(repeating: "  ", count: node.depth + 1)
            let name = node.device.productName ?? String(localized: "Unknown", bundle: _coreLocalizedBundle)
            let prefix = node.depth > 0 ? "\u{21B3}" : ANSI.wrap(ANSI.gray, "\u{2022}")
            out += "\(indent)\(prefix) \(name) - \(node.device.speedLabel)\n"
        }
        out += "  " + ANSI.wrap(ANSI.dim, String(localized: "Reached through a Thunderbolt dock or display, so there's no cable, power, or Thunderbolt data for them.", bundle: _coreLocalizedBundle)) + "\n"
        return out
    }

    /// Render the internal-hub devices block (issue #348). These are devices
    /// on the front-panel ports of a Mac mini / Studio / Pro: plain USB ports
    /// hanging off the internal Apple hub, with no port-controller silicon.
    /// Always a top-level section (never nested under a port), but the devices
    /// inside render as a hub tree. Empty string when there are none.
    private static func renderInternalHubDevices(_ devices: [USBDevice]) -> String {
        guard !devices.isEmpty else { return "" }
        var out = "\n"
        let title = String(localized: "Built-in USB ports", bundle: _coreLocalizedBundle)
        out += ANSI.wrap(ANSI.bold, title + ":") + "\n"
        let tree = USBDeviceNode.flatten(USBDeviceNode.buildTree(from: devices))
        for node in tree {
            let indent = String(repeating: "  ", count: node.depth + 1)
            let name = node.device.productName ?? String(localized: "Unknown", bundle: _coreLocalizedBundle)
            let prefix = node.depth > 0 ? "\u{21B3}" : ANSI.wrap(ANSI.gray, "\u{2022}")
            out += "\(indent)\(prefix) \(name) - \(node.device.speedLabel)\n"
        }
        out += "  " + ANSI.wrap(ANSI.dim, String(localized: "Plain USB ports behind the Mac's internal hub, so there's no cable, power, or Thunderbolt data for them.", bundle: _coreLocalizedBundle)) + "\n"
        return out
    }

    private static func renderPort(
        _ port: AppleHPMInterface,
        sources: [PowerSource],
        identities: [USBPDSOP],
        showRaw: Bool,
        adapter: CableAdapterInfo?,
        thunderboltSwitches: [IOThunderboltSwitch],
        federatedIdentities: [FederatedIdentity] = [],
        usb3Transports: [USB3Transport] = [],
        cioCapability: CIOCableCapability? = nil,
        chargerWattageSource: ChargerWattageSource = .unknown,
        batteryFullyCharged: Bool? = nil,
        batteryIsCharging: Bool? = nil,
        usbDevices: [USBDevice] = [],
        displayPorts: [IOPortTransportStateDisplayPort] = [],
        anotherPortActivelyCharging: Bool = false
    ) -> String {
        let summary = PortSummary(
            port: port,
            sources: sources,
            identities: identities,
            devices: usbDevices,
            thunderboltSwitches: thunderboltSwitches,
            federatedIdentities: federatedIdentities,
            usb3Transports: usb3Transports,
            cioCapability: cioCapability,
            chargerWattageSource: chargerWattageSource,
            batteryFullyCharged: batteryFullyCharged,
            batteryIsCharging: batteryIsCharging,
            adapter: adapter
        )
        let label = port.portDescription ?? port.serviceName
        let typeSuffix = port.portTypeDescription.map { " (\($0))" } ?? ""

        let header = "=== \(label)\(typeSuffix) ==="
        var out = ANSI.wrap(ANSI.bold + ANSI.cyan, header) + "\n"

        let headlineColor = color(for: summary.status)
        out += ANSI.wrap(ANSI.bold + headlineColor, summary.headline) + "\n"
        if !summary.subtitle.isEmpty {
            out += ANSI.wrap(ANSI.dim, summary.subtitle) + "\n"
        }

        if !summary.bullets.isEmpty {
            out += "\n"
            for bullet in summary.bullets {
                out += "  " + ANSI.wrap(ANSI.gray, "•") + " \(bullet)\n"
            }
        }

        if let diag = ChargingDiagnostic(port: port, sources: sources, identities: identities, adapter: adapter, wattageSource: chargerWattageSource, batteryFullyCharged: batteryFullyCharged, batteryIsCharging: batteryIsCharging, anotherPortActivelyCharging: anotherPortActivelyCharging) {
            let diagColor = diag.isWarning ? ANSI.yellow : ANSI.green
            out += "\n" + ANSI.wrap(ANSI.bold, String(localized: "Charging: ", bundle: _coreLocalizedBundle)) + ANSI.wrap(diagColor, diag.summary) + "\n"
            out += "  " + ANSI.wrap(ANSI.dim, diag.detail) + "\n"
        }

        if let dataDiag = DataLinkDiagnostic(
            port: port,
            identities: identities,
            devices: usbDevices,
            usb3Transports: usb3Transports,
            cio: cioCapability,
            thunderboltSwitches: thunderboltSwitches
        ) {
            let dataColor = dataDiag.isWarning ? ANSI.yellow : ANSI.green
            out += "\n" + ANSI.wrap(ANSI.bold, "Data: ") + ANSI.wrap(dataColor, dataDiag.summary) + "\n"
            out += "  " + ANSI.wrap(ANSI.dim, dataDiag.detail) + "\n"
        }

        // Display verdict, one block per connected monitor (a dock can drive
        // several through one port, issue #271). The cable e-marker is passed
        // only so the verdict can exonerate (not convict) the cable on an
        // active-cable check.
        let displayCable = identities.first { $0.endpoint == .sopPrime || $0.endpoint == .sopDoublePrime }
        for displayPort in displayPorts {
            guard let displayDiag = DisplayDiagnostic(dp: displayPort, cable: displayCable) else { continue }
            let displayColor = displayDiag.isWarning ? ANSI.yellow : ANSI.green
            out += "\n" + ANSI.wrap(ANSI.bold, "Display: ") + ANSI.wrap(displayColor, displayDiag.summary) + "\n"
            out += "  " + ANSI.wrap(ANSI.dim, displayDiag.detail) + "\n"
        }

        // Name only, no diagnosis (a Billboard device is often benign). The
        // Alt-Mode inference is reserved for the Pro Display screen. Show the
        // device's own name when it adds information, else the generic phrase.
        if let billboard = port.billboardDevice(among: usbDevices) {
            let label = billboard.billboardPresenceLabel(bundle: _coreLocalizedBundle)
            out += "  " + ANSI.wrap(ANSI.gray, "\u{2022}") + " " + label + "\n"
        }

        // Thunderbolt fabric tree: every downstream switch reachable from
        // this port's host root, following all branches (issue #280). Mirrors
        // the "Connected devices" USB tree below it: depth indent + ↳ prefix,
        // each row showing the device name and the link by which it connects.
        if let socketID = ThunderboltTopology.socketID(for: port),
           let root = ThunderboltTopology.hostRoot(forSocketID: socketID, in: thunderboltSwitches) {
            let fabric = ThunderboltTopology.flatten(
                ThunderboltTopology.tree(from: root, in: thunderboltSwitches)
            )
            if !fabric.isEmpty {
                out += "\n" + ANSI.wrap(ANSI.bold, String(localized: "Thunderbolt fabric:", bundle: _coreLocalizedBundle)) + "\n"
                for node in fabric {
                    let indent = String(repeating: "  ", count: node.depth + 1)
                    let prefix = node.depth > 0 ? "\u{21B3}" : ANSI.wrap(ANSI.gray, "\u{2022}")
                    let name = ThunderboltLabels.deviceName(for: node.sw)
                    let link = ThunderboltTopology.connectionLanePort(node.sw)
                        .flatMap { ThunderboltLabels.linkLabel(for: $0) }
                    let suffix = link.map { " - \($0)" } ?? ""
                    out += "\(indent)\(prefix) \(name)\(suffix)\n"
                }
            }
        }

        if !usbDevices.isEmpty {
            let tree = USBDeviceNode.flatten(USBDeviceNode.buildTree(from: usbDevices))
            out += "\n" + ANSI.wrap(ANSI.bold, String(localized: "Connected devices:", bundle: _coreLocalizedBundle)) + "\n"
            for node in tree {
                let indent = String(repeating: "  ", count: node.depth + 1)
                let name = node.device.productName ?? String(localized: "Unknown", bundle: _coreLocalizedBundle)
                let prefix = node.depth > 0 ? "\u{21B3}" : ANSI.wrap(ANSI.gray, "\u{2022}")
                out += "\(indent)\(prefix) \(name) - \(node.device.speedLabel)\n"
            }
        }

        // Cable trust signals: hedged flags raised against the e-marker.
        // Match the popover's behaviour: only render when at least one flag
        // fires, and use the same titles + details so wording stays
        // consistent across surfaces.
        if let cable = identities.first(where: { $0.endpoint == .sopPrime || $0.endpoint == .sopDoublePrime }) {
            let partner = identities.first(where: { $0.endpoint == .sop })
            let trust = CableTrustReport(identity: cable, partner: partner)
            if !trust.isEmpty {
                // A block with any real warning reads as a warning (yellow
                // header). A notes-only block reads calm (gray header), so a
                // softened false-positive doesn't look like an alarm.
                let hasWarning = trust.flags.contains { $0.severity == .warning }
                let header = hasWarning
                    ? ANSI.wrap(ANSI.bold + ANSI.yellow, String(localized: "Cable trust signals:", bundle: _coreLocalizedBundle))
                    : ANSI.wrap(ANSI.bold + ANSI.gray, String(localized: "Cable note:", bundle: _coreLocalizedBundle))
                out += "\n" + header + "\n"
                for flag in trust.flags {
                    // Neutral notes read calmly (gray dot); warnings keep the
                    // yellow alarm marker.
                    let marker = flag.severity == .warning
                        ? ANSI.wrap(ANSI.yellow, "⚠")
                        : ANSI.wrap(ANSI.gray, "•")
                    out += "  " + marker + " " + ANSI.wrap(ANSI.bold, flag.title) + "\n"
                    out += "    " + ANSI.wrap(ANSI.dim, flag.detail) + "\n"
                }
            }
        }

        if showRaw {
            if let cable = identities.first(where: {
                $0.endpoint == .sopPrime || $0.endpoint == .sopDoublePrime
            }), let v2 = cable.activeCableVDO2 {
                out += "\n" + ANSI.wrap(ANSI.bold, String(localized: "Active cable (VDO 2):", bundle: _coreLocalizedBundle)) + "\n"
                out += rawRow("Physical connection", v2.physicalConnection.label)
                out += rawRow("Active element", v2.activeElement.label)
                out += rawRow("Optically isolated", yesNo(v2.opticallyIsolated))
                out += rawRow("USB lanes", v2.twoLanesSupported ? "Two" : "One")
                out += rawRow("USB Gen", v2.usbGen2OrHigher ? "Gen 2 or higher" : "Gen 1")
                out += rawRow("USB4 supported", yesNo(v2.usb4Supported))
                out += rawRow("USB 3.2 supported", yesNo(v2.usb32Supported))
                out += rawRow("USB 2.0 supported", yesNo(v2.usb2Supported))
                out += rawRow("USB 2.0 hub hops", String(v2.usb2HubHopsConsumed))
                out += rawRow("USB4 asymmetric", yesNo(v2.usb4AsymmetricMode))
                out += rawRow("U3 to U0 transition", v2.u3ToU0TransitionThroughU3S ? "Through U3S" : "Direct")
                out += rawRow("Idle power (U3/CLd)", v2.u3CLdPower.label)
                out += rawRow("Max operating temp", tempLabel(v2.maxOperatingTempC))
                out += rawRow("Shutdown temp", tempLabel(v2.shutdownTempC))
            }

            out += "\n" + ANSI.wrap(ANSI.bold, String(localized: "Raw IOKit properties:", bundle: _coreLocalizedBundle)) + "\n"
            for key in port.redactedRawProperties.keys.sorted() {
                let value = port.redactedRawProperties[key] ?? ""
                out += "  " + ANSI.wrap(ANSI.gray, key) + " = \(value)\n"
            }
        }

        return out
    }

    private static func rawRow(_ key: String, _ value: String) -> String {
        "  " + ANSI.wrap(ANSI.gray, key) + " = \(value)\n"
    }

    private static func yesNo(_ v: Bool) -> String { v ? "Yes" : "No" }

    /// 0 in the temperature fields means "not specified" per the spec.
    private static func tempLabel(_ v: Int) -> String {
        v == 0 ? "—" : "\(v)°C"
    }

    private static func color(for status: PortSummary.Status) -> String {
        switch status {
        case .empty: return ANSI.gray
        case .charging: return ANSI.yellow
        case .batteryFull: return ANSI.green
        case .dataDevice: return ANSI.blue
        case .thunderboltCable: return ANSI.magenta
        case .displayCable: return ANSI.cyan
        case .unknown: return ANSI.yellow
        }
    }

    private static func filterSources(_ port: AppleHPMInterface, all: [PowerSource]) -> [PowerSource] {
        return all.filter { $0.canonicallyMatches(port: port) }
    }

    private static func filterIdentities(_ port: AppleHPMInterface, all: [USBPDSOP]) -> [USBPDSOP] {
        all.filter { $0.canonicallyMatches(port: port) }
    }
}
