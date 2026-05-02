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
// DeviceInspector.swift
//
// Detail (right) column of the main window's `NavigationSplitView`
// per SPEC §13.2: "selected device's full info, telemetry charts
// (Swift Charts), event history."
//
// Phase 6 ships full info + telemetry sparkline (re-using the Phase
// 5 component). Event history wires up Phase 10 when GRDB lands.
// nil selection → empty-state placeholder.

import SwiftUI
import ManifoldKit

struct DeviceInspector: View {

    @Bindable var graph: PortGraph

    /// Selection from TopologyCanvas. nil → empty-state.
    let selectedDeviceID: DeviceID?

    var body: some View {
        if let (host, port, device) = locate(deviceID: selectedDeviceID) {
            populated(host: host, port: port, device: device)
        } else {
            emptyState
        }
    }

    // MARK: - Populated detail

    private func populated(
        host: ManifoldKit.Host,
        port: ManifoldKit.Port,
        device: Device
    ) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header(device: device)
                Divider()
                section(titleKey: "window.inspector.section.identity") {
                    keyValue("window.inspector.field.vendor", device.vendorID, formatHex)
                    keyValue("window.inspector.field.product", device.productID, formatHex)
                    if let serial = device.serial {
                        keyValueText("window.inspector.field.serial", serial)
                    }
                    if let usbVersion = device.usbVersion {
                        keyValueText("window.inspector.field.usbVersion", usbVersion.rawValue)
                    }
                }
                Divider()
                section(titleKey: "window.inspector.section.connection") {
                    keyValueText(
                        "window.inspector.field.host",
                        "\(host.name) (\(host.model))"
                    )
                    keyValueText(
                        "window.inspector.field.portPosition",
                        String(
                            format: NSLocalizedString("window.inspector.value.portPosition", comment: ""),
                            port.position
                        )
                    )
                    if let speed = port.negotiated {
                        keyValueText("window.inspector.field.protocol", speed.protocolName)
                        keyValueText("window.inspector.field.bitrate", speed.bitrate.formatted)
                    }
                    if let watts = port.powerDraw {
                        keyValueText("window.inspector.field.power", watts.formatted)
                    }
                }
                Divider()
                section(titleKey: "window.inspector.section.telemetry") {
                    Sparkline(samples: graph.history(forPortID: port.id)?.samples ?? [])
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("window.inspector.telemetry.caption")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let displayInfo = device.displayInfo {
                    Divider()
                    section(titleKey: "window.inspector.section.display") {
                        keyValueText(
                            "window.inspector.field.resolution",
                            String(
                                format: NSLocalizedString("window.inspector.value.resolution", comment: ""),
                                Int(displayInfo.resolution.width),
                                Int(displayInfo.resolution.height)
                            )
                        )
                        keyValueText(
                            "window.inspector.field.refreshRate",
                            String(
                                format: NSLocalizedString("window.inspector.value.refreshRate", comment: ""),
                                displayInfo.refreshHz
                            )
                        )
                        keyValueText("window.inspector.field.panelType", displayInfo.panelType)
                    }
                }
            }
            .padding(16)
        }
    }

    private func header(device: Device) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(device.name.isEmpty ? fallbackName(for: device) : device.name)
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color.manifoldText)
            Text(deviceKindLabel(device.kind))
                .font(.caption.smallCaps())
                .foregroundStyle(Color.manifoldAccent)
        }
    }

    /// Reusable section frame: small-caps title + content vstack.
    private func section<Content: View>(
        titleKey: LocalizedStringKey,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(titleKey)
                .font(.caption.smallCaps())
                .foregroundStyle(.secondary)
            content()
        }
    }

    /// Convenience for hex-formatted UInt16 fields (vendor/product
    /// IDs).
    private func keyValue<T>(
        _ labelKey: LocalizedStringKey,
        _ value: T,
        _ format: (T) -> String
    ) -> some View {
        keyValueText(labelKey, format(value))
    }

    /// Convenience for plain string fields.
    private func keyValueText(
        _ labelKey: LocalizedStringKey,
        _ value: String
    ) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(labelKey)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(Color.manifoldText)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "rectangle.dashed.and.paperclip")
                .font(.title)
                .foregroundStyle(.secondary)
            Text("window.inspector.empty.title")
                .font(.headline)
                .foregroundStyle(Color.manifoldText)
            Text("window.inspector.empty.subtitle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Helpers

    /// Locate the host + port + device for a given DeviceID. Returns
    /// nil if the device isn't in the graph (selection from a
    /// previous launch that's no longer connected).
    private func locate(deviceID: DeviceID?) -> (
        host: ManifoldKit.Host,
        port: ManifoldKit.Port,
        device: Device
    )? {
        guard let deviceID else { return nil }
        for host in graph.hosts {
            for port in host.ports {
                if let device = port.connectedDevice, device.id == deviceID {
                    return (host, port, device)
                }
                // Recurse into children (Phase 7 hub trees).
                if let result = findInChildren(deviceID: deviceID, host: host, ports: port.children) {
                    return result
                }
            }
        }
        return nil
    }

    private func findInChildren(
        deviceID: DeviceID,
        host: ManifoldKit.Host,
        ports: [ManifoldKit.Port]
    ) -> (host: ManifoldKit.Host, port: ManifoldKit.Port, device: Device)? {
        for port in ports {
            if let device = port.connectedDevice, device.id == deviceID {
                return (host, port, device)
            }
            if let result = findInChildren(deviceID: deviceID, host: host, ports: port.children) {
                return result
            }
        }
        return nil
    }

    private func formatHex(_ value: UInt16) -> String {
        String(format: "0x%04X", value)
    }

    private func fallbackName(for device: Device) -> String {
        let vid = String(format: "%04X", device.vendorID)
        let pid = String(format: "%04X", device.productID)
        return String(
            format: NSLocalizedString("popover.device.fallback.name", comment: ""),
            vid, pid
        )
    }

    private func deviceKindLabel(_ kind: DeviceKind) -> String {
        switch kind {
        case .audio:      return NSLocalizedString("window.inspector.kind.audio",      comment: "")
        case .display:    return NSLocalizedString("window.inspector.kind.display",    comment: "")
        case .input:      return NSLocalizedString("window.inspector.kind.input",      comment: "")
        case .storage:    return NSLocalizedString("window.inspector.kind.storage",    comment: "")
        case .hub:        return NSLocalizedString("window.inspector.kind.hub",        comment: "")
        case .video:      return NSLocalizedString("window.inspector.kind.video",      comment: "")
        case .networking: return NSLocalizedString("window.inspector.kind.networking", comment: "")
        case .other:      return NSLocalizedString("window.inspector.kind.other",      comment: "")
        }
    }
}

#Preview("DeviceInspector — SanDisk SSD") {
    let graph = PortGraph()
    graph.replace(hosts: [PreviewData.macBook])
    return DeviceInspector(graph: graph, selectedDeviceID: PreviewData.sandiskSSD.id)
        .frame(width: 320, height: 600)
        .background(Color.manifoldSurface)
}

#Preview("DeviceInspector — Studio Display (with display info)") {
    let graph = PortGraph()
    graph.replace(hosts: [PreviewData.macBook])
    return DeviceInspector(graph: graph, selectedDeviceID: PreviewData.studioDisplay.id)
        .frame(width: 320, height: 600)
        .background(Color.manifoldSurface)
}

#Preview("DeviceInspector — empty") {
    DeviceInspector(graph: PortGraph(), selectedDeviceID: nil)
        .frame(width: 320, height: 600)
        .background(Color.manifoldSurface)
}
