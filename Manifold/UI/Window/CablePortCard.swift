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
// CablePortCard.swift
//
// Phase 21 — one card per USB-C port. Builds a `PortSummary` from the
// port + the snapshot's other arrays (power sources, identities, USB
// devices, Thunderbolt switches), then lays out the headline,
// subtitle, and bullets in Manifold's design language.
//
// Status icon + tint comes from `PortSummary.Status`. Connected ports
// use `manifoldAccent`; charging is the same accent (charging is a
// connected state); unknown / unsupported ports drop to `secondary`.

import SwiftUI
import ManifoldKit

struct CablePortCard: View {

    let port: AppleHPMInterface
    let snapshot: CableSnapshot

    /// Manifold's existing graph. Used for two joins the absorbed
    /// cables engine can't provide on its own:
    ///   1. Resolved volume names — `PortGraphBuilder` already runs
    ///      DiskArbitration to map "Creator SSD" → "PlanckSSD"; we
    ///      reuse that resolution here instead of walking DA twice.
    ///   2. Host-level adapter presence — the absorbed
    ///      `PowerSourceWatcher` only sees per-port USB-PD
    ///      negotiations on the CC channel; cheap charge cables that
    ///      pass 5V on VBUS without doing PD discovery don't show up
    ///      there. `Host.inputAdapter` is system-wide and survives
    ///      that gap.
    let graph: PortGraph

    /// Per-port slice of the snapshot. Computed once and reused by the
    /// PortSummary builder + the device-name bullet builder so we
    /// don't re-filter in two places.
    private struct PortSlice {
        let identities: [USBPDSOP]
        let sources: [PowerSource]
        let devices: [USBDevice]
        let usb3Transports: [USB3Transport]
        let cioCapability: CIOCableCapability?
    }

    private var slice: PortSlice {
        // PortSummary expects identities, power sources, and USB
        // devices ALREADY scoped to this port — passing the unfiltered
        // snapshot arrays bleeds Port-USB-C@1's connected-device
        // bullet onto every other port's card. The upstream watcher
        // helpers (`PDIdentityWatcher.identities(for:)` etc.) do this
        // filter; we replicate it inline here since CablePortCard
        // sees the snapshot, not the watchers.
        let identities = snapshot.identities.filter { $0.canonicallyMatches(port: port) }
        let sources = snapshot.powerSources.filter { $0.canonicallyMatches(port: port) }
        let devices = port.matchingDevices(from: snapshot.usbDevices)
        let usb3Transports = snapshot.usb3Transports.filter { $0.canonicallyMatches(port: port) }
        let cioCapability = snapshot.cioCapabilities.first { $0.canonicallyMatches(port: port) }
        return PortSlice(
            identities: identities,
            sources: sources,
            devices: devices,
            usb3Transports: usb3Transports,
            cioCapability: cioCapability
        )
    }

    private var summary: PortSummary {
        let s = slice
        let activePortCount = snapshot.ports.count { $0.connectionActive == true }
        let chargerWattage = ChargerWattageSource.resolve(
            portSources: s.sources,
            activePortCount: activePortCount,
            adapter: snapshot.adapter
        )
        return PortSummary(
            port: port,
            sources: s.sources,
            identities: s.identities,
            devices: s.devices,
            thunderboltSwitches: snapshot.thunderboltSwitches,
            federatedIdentities: snapshot.federatedIdentities,
            usb3Transports: s.usb3Transports,
            cioCapability: s.cioCapability,
            chargerWattageSource: chargerWattage,
            batteryFullyCharged: snapshot.batteryFullyCharged,
            batteryIsCharging: snapshot.batteryIsCharging,
            adapter: snapshot.adapter
        )
    }

    /// Manifold-side bullets that supplement `summary.bullets` with the
    /// names of USB devices matched to this port. PortSummary's only
    /// "Connected device" line comes from a SOP PD identity, which most
    /// plain USB devices (SSDs, dongles, receivers) don't issue — so
    /// without this, a port with a Logitech receiver plugged in would
    /// say "USB device" / "SuperSpeed" and never name the receiver.
    private var deviceBullets: [String] {
        slice.devices.compactMap { device in
            // Prefer the volume name resolved by Manifold's graph
            // ("PlanckSSD") over the raw USB product string ("Creator
            // SSD"); fall back to the product string, then the vendor
            // string, then drop the bullet.
            let preferred = friendlyName(for: device)
            let trimmedProduct = device.productName?
                .trimmingCharacters(in: .whitespaces) ?? ""
            let trimmedVendor = device.vendorName?
                .trimmingCharacters(in: .whitespaces) ?? ""
            let name: String
            if let preferred {
                name = preferred
            } else if !trimmedProduct.isEmpty {
                name = trimmedProduct
            } else if !trimmedVendor.isEmpty {
                name = trimmedVendor
            } else {
                return nil
            }
            // Append the speed label so a USB-3-capable device sitting
            // on a slow link reads obviously wrong, even before the
            // user clicks into Topology.
            return "\(name) — \(device.speedLabel)"
        }
    }

    /// Look up a friendlier name for a USB device by joining the
    /// cables-snapshot device against Manifold's existing PortGraph.
    /// The graph's `Device.displayName` already prefers the
    /// volume-label "PlanckSSD" over the SCSI-inquiry model "Creator
    /// SSD" (PortGraphBuilder applied the resolution at walk time).
    /// Match on (vendorID, productID, serial) when serial is present;
    /// fall back to (vendorID, productID) — rare ambiguity case for
    /// two identical devices is acceptable here since the bullet is
    /// a hint, not a primary identifier.
    private func friendlyName(for device: USBDevice) -> String? {
        let candidates = Self.allDevices(in: graph)
        let byTriple = { (d: ManifoldKit.Device) -> Bool in
            guard let serial = device.serialNumber, !serial.isEmpty else { return false }
            return d.vendorID == device.vendorID
                && d.productID == device.productID
                && d.serial == serial
        }
        let byVidPid = { (d: ManifoldKit.Device) -> Bool in
            d.vendorID == device.vendorID && d.productID == device.productID
        }
        let match = candidates.first(where: byTriple)
            ?? candidates.first(where: byVidPid)
        guard let match else { return nil }
        let resolved = match.displayName.trimmingCharacters(in: .whitespaces)
        return resolved.isEmpty ? nil : resolved
    }

    /// Flatten every Device the graph knows about, walking `Port.children`
    /// recursively. The cables-side join doesn't care about hierarchy —
    /// we only need a flat lookup table keyed by VID:PID:serial.
    private static func allDevices(in graph: PortGraph) -> [ManifoldKit.Device] {
        var result: [ManifoldKit.Device] = []
        func visit(_ port: ManifoldKit.Port) {
            if let device = port.connectedDevice {
                result.append(device)
            }
            for child in port.children { visit(child) }
        }
        for host in graph.hosts {
            for port in host.ports { visit(port) }
        }
        return result
    }

    /// Headline + subtitle override applied when PortSummary's
    /// classification falls through to `.unknown` ("Couldn't determine
    /// cable type from this port"). Two cases we can do better on:
    ///
    ///   1. **Charge cable plugged in.** The cable is connected, the
    ///      Mac is charging (`graph.hosts.first?.inputAdapter` is
    ///      non-nil), but no transports are active and PD isn't
    ///      negotiated on the CC channel. PortSummary doesn't see
    ///      it because it only inspects per-port PD profiles.
    ///   2. **Cable identified but idle.** A SOP partner identity
    ///      exists (the cable's connector chip responded to Discover
    ///      Identity), so we know the cable's vendor + type.
    ///
    /// Returns `nil` when no override applies — the card falls back
    /// to PortSummary's headline.
    private var headlineOverride: (headline: String, subtitle: String, status: PortSummary.Status)? {
        guard summary.status == .unknown else { return nil }
        guard port.connectionActive == true else { return nil }

        let partner = slice.identities.first(where: { $0.endpoint == .sop })
        let adapter = graph.hosts.first?.inputAdapter

        if let adapter {
            // Most likely scenario: this port has the charge cable.
            // We can't be 100% sure (the host adapter signal is
            // system-wide — macOS publishes one active adapter, not
            // a per-port mapping), but if a port has a cable and
            // there's a charger, that port is overwhelmingly likely
            // the charge port.
            //
            // Wattage comes from `AppleSmartBattery.AdapterDetails`
            // (the same source that drives the Battery tab), NOT
            // from the cable's PD profile. We surface that
            // distinction in the subtitle so a user reading "45W"
            // doesn't think the cable is somehow advertising it.
            let watts = Int(adapter.watts.value.rounded())
            let headline = watts > 0 ? "Charging at \(watts)W" : "Charging"
            let chargerName = Self.adapterFriendlyName(adapter)
            let subtitle: String
            if let chargerName {
                subtitle = "Reported by macOS for \(chargerName). The cable itself doesn't expose a Power Delivery profile from this port."
            } else {
                subtitle = "Reported by macOS's charger detection. The cable itself doesn't expose a Power Delivery profile from this port."
            }
            return (
                headline: headline,
                subtitle: subtitle,
                status: .charging
            )
        }
        if let partner, let header = partner.idHeader {
            let kind = header.ufpProductType != .undefined
                ? header.ufpProductType.label
                : header.dfpProductType.label
            return (
                headline: "\(kind) detected",
                subtitle: "Cable is plugged in but idle — no data link, charging, or display signal active.",
                status: .unknown
            )
        }
        return nil
    }

    /// Build a short-form charger name from `AdapterInfo` for the
    /// charging subtitle. Prefers `description` (e.g. "USB-C 96W"),
    /// falls back to manufacturer + model, then nil. Trimmed and
    /// nil-if-empty so the formatter never has to handle blank
    /// strings.
    private static func adapterFriendlyName(_ adapter: AdapterInfo) -> String? {
        if let desc = adapter.description?.trimmingCharacters(in: .whitespaces),
           !desc.isEmpty {
            return desc
        }
        let mfg = adapter.manufacturer?.trimmingCharacters(in: .whitespaces) ?? ""
        let model = adapter.model?.trimmingCharacters(in: .whitespaces) ?? ""
        if !mfg.isEmpty, !model.isEmpty { return "\(mfg) \(model)" }
        if !mfg.isEmpty { return mfg }
        if !model.isEmpty { return model }
        return nil
    }

    /// What the card actually renders for headline + subtitle. Falls
    /// back to PortSummary's content when no override applies.
    private var displayedHeadline: String {
        headlineOverride?.headline ?? summary.headline
    }

    private var displayedSubtitle: String {
        headlineOverride?.subtitle ?? summary.subtitle
    }

    private var displayedStatus: PortSummary.Status {
        headlineOverride?.status ?? summary.status
    }

    /// Combined bullet stream: PortSummary's content first (cable /
    /// transport / power info), then the per-port USB device names.
    private var allBullets: [String] {
        summary.bullets + deviceBullets
    }

    private var pinMap: USBCPinMap? {
        USBCPinMap.from(
            pinConfiguration: port.pinConfiguration,
            plugOrientation: port.plugOrientation
        )
    }

    private var liquidStatus: LiquidDetectionStatus? {
        guard let key = port.portKey else { return nil }
        return snapshot.liquidDetection[key]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: iconName)
                    .font(.title)
                    .foregroundStyle(iconTint)
                    .frame(width: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text(port.portDescription ?? port.serviceName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("cables.port.label")
                    Text(displayedHeadline)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Color.manifoldText)
                }
                Spacer()
            }
            .accessibilityElement(children: .combine)

            Text(displayedSubtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !allBullets.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(allBullets, id: \.self) { bullet in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "circle.fill")
                                .font(.system(size: 4))
                                .foregroundStyle(.tertiary)
                                .padding(.top, 6)
                            Text(bullet)
                                .font(.callout)
                                .foregroundStyle(Color.manifoldText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            if let liquidStatus, liquidStatus.liquidDetected {
                Divider()
                LiquidDetectionCallout(status: liquidStatus)
            }

            if let pinMap {
                Divider()
                DisclosureGroup {
                    USBCPinDiagram(map: pinMap)
                        .padding(.top, 8)
                } label: {
                    Label("Pin detail", systemImage: "cable.connector.horizontal")
                        .font(.callout.weight(.medium))
                }
                .accessibilityIdentifier("cables.port.pinDetail")
            }
        }
        .padding(CablesViewConstants.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: CablesViewConstants.cardCornerRadius)
                .fill(Color.manifoldCard)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("cables.port.card")
    }

    // MARK: - Icon mapping

    private var iconName: String {
        switch displayedStatus {
        case .empty:            return "cable.connector"
        case .charging:         return "bolt.fill"
        case .batteryFull:      return "battery.100percent"
        case .dataDevice:       return "externaldrive.connected.to.line.below"
        case .thunderboltCable: return "bolt.horizontal.fill"
        case .displayCable:     return "display"
        case .unknown:          return "questionmark.circle"
        }
    }

    private var iconTint: Color {
        switch displayedStatus {
        case .empty:            return .secondary
        case .charging,
             .batteryFull,
             .dataDevice,
             .thunderboltCable,
             .displayCable:     return Color.manifoldAccent
        case .unknown:          return .secondary
        }
    }
}

#if DEBUG
// Body references `CableSnapshot.previewEmptyPort`, defined behind
// `#if DEBUG` in `CablesPreviewData.swift`. Manual gate so Release
// doesn't try to resolve the seed.
#Preview("CablePortCard — empty port") {
    let snap = CableSnapshot.previewEmptyPort
    return CablePortCard(port: snap.ports[0], snapshot: snap, graph: PortGraph())
        .padding()
        .frame(width: 520)
        .background(Color.manifoldSurface)
}
#endif
