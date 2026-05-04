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
// TopologyCanvas.swift
//
// Content column for the **Topology** tab per SPEC §13.2. Renders
// the selected host's port tree as an `OutlineGroup`-backed list,
// like the popover does, but with more breathing room and per-row
// affordances (selecting a row sets the detail-column device).
//
// Phase 6 keeps the rendering as a vertical list of rows; SPEC's
// "canvas" wording allows for a true graphical layout (Phase 15
// Polish may revisit). For Phase 6 a styled list IS the topology
// canvas — it's the structure that matters, the visual polish lands
// later.

import SwiftUI
import ManifoldKit

struct TopologyCanvas: View {

    @Bindable var graph: PortGraph

    /// Currently-displayed host. nil → empty state.
    let host: ManifoldKit.Host?

    /// Two-way binding into the parent's `@SceneStorage`-backed
    /// selected device. Selecting a row sets this; the detail column
    /// reads it.
    @Binding var selectedDeviceID: DeviceID?

    var body: some View {
        if let host {
            populated(host: host)
        } else {
            emptyState
        }
    }

    private func populated(host: ManifoldKit.Host) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                topologyHeader(host: host)
                ForEach(host.ports, id: \.id) { port in
                    OutlineGroup(port, children: \.childrenForOutline) { node in
                        topologyRow(port: node)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if let device = node.connectedDevice {
                                    selectedDeviceID = device.id
                                }
                            }
                            .background(
                                isSelected(node)
                                    ? Color.manifoldAccent.opacity(0.18)
                                    : Color.clear
                            )
                    }
                }
            }
            .padding(.vertical, 12)
        }
        .navigationTitle(host.displayName)
    }

    private func topologyHeader(host: ManifoldKit.Host) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(host.model)
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("window.topology.header.model")
            HStack {
                summaryItem(
                    label: "window.topology.summary.devices",
                    value: "\(host.ports.compactMap(\.connectedDevice).count)"
                )
                summaryItem(
                    label: "window.topology.summary.ports",
                    value: "\(host.ports.count)"
                )
                summaryItem(
                    label: "window.topology.summary.totalDraw",
                    value: host.totalPowerDraw.formatted,
                    valueColor: drawColor(for: host)
                )
                summaryItem(
                    label: "window.topology.summary.input",
                    value: inputSummaryValue(for: host),
                    valueColor: host.inputAdapter == nil ? Color.manifoldText : Color.manifoldAccent
                )
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    /// "65 W (MagSafe)" / "45 W (USB-C)" / "—". Wattage and source
    /// fold into one summary value so the header still reads as four
    /// equal columns; the source label tucks under the wattage if
    /// needed.
    private func inputSummaryValue(for host: ManifoldKit.Host) -> String {
        guard let adapter = host.inputAdapter else { return "—" }
        let watts = adapter.watts.formatted
        let source = sourceLabel(for: adapter.source)
        if source.isEmpty {
            return watts
        }
        return "\(watts) (\(source))"
    }

    private func sourceLabel(for source: AdapterInfo.Source) -> String {
        switch source {
        case .magsafe:  return NSLocalizedString("host.adapter.source.magsafe",  comment: "")
        case .usbC:     return NSLocalizedString("host.adapter.source.usbC",     comment: "")
        case .wireless: return NSLocalizedString("host.adapter.source.wireless", comment: "")
        case .unknown:  return ""
        }
    }

    /// True when total USB draw exceeds the active charger's input —
    /// flips the summary's draw figure to critical red.
    private func drawColor(for host: ManifoldKit.Host) -> Color {
        guard let input = host.inputAdapter?.watts.value,
              host.totalPowerDraw.value > input else {
            return Color.manifoldText
        }
        return Color.manifoldCritical
    }

    private func summaryItem(
        label: LocalizedStringKey,
        value: String,
        valueColor: Color = Color.manifoldText
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2.smallCaps())
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline.monospacedDigit())
                .foregroundStyle(valueColor)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func topologyRow(port: ManifoldKit.Port) -> some View {
        HStack(spacing: 10) {
            Image(systemName: port.connectedDevice == nil ? "circle.dashed" : "cable.connector")
                .foregroundStyle(port.connectedDevice == nil ? .secondary : Color.manifoldAccent)
                .frame(width: 20, alignment: .center)

            VStack(alignment: .leading, spacing: 2) {
                if let device = port.connectedDevice {
                    Text(displayName(for: device))
                        .font(.body)
                        .foregroundStyle(Color.manifoldText)
                    Text(deviceCaption(port: port, device: device))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    Text(emptyPortLabel(for: port))
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if let watts = port.powerDraw {
                Text(watts.formatted)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel(for: port))
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "rectangle.dashed")
                .font(.title)
                .foregroundStyle(.secondary)
            Text("window.topology.emptyState.title")
                .font(.headline)
                .foregroundStyle(Color.manifoldText)
            Text("window.topology.emptyState.subtitle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func isSelected(_ port: ManifoldKit.Port) -> Bool {
        guard let id = port.connectedDevice?.id else { return false }
        return id == selectedDeviceID
    }

    // MARK: - Localised helpers (mirrors DeviceRow patterns)

    private func fallbackName(for device: Device) -> String {
        let vid = String(format: "%04X", device.vendorID)
        let pid = String(format: "%04X", device.productID)
        return String(
            format: NSLocalizedString(
                "popover.device.fallback.name",
                comment: "Fallback display name reused from the popover."
            ),
            vid, pid
        )
    }

    /// User-facing primary name: friendly volume name if set, else the
    /// USB product string, else "Device VVVV:PPPP".
    private func displayName(for device: Device) -> String {
        if let friendly = device.friendlyName, !friendly.isEmpty {
            return friendly
        }
        return device.name.isEmpty ? fallbackName(for: device) : device.name
    }

    private func deviceCaption(port: ManifoldKit.Port, device: Device) -> String {
        let proto = port.negotiated?.protocolName
            ?? NSLocalizedString("popover.device.unknown.protocol", comment: "")
        return String(format: "%04X:%04X · %@", device.vendorID, device.productID, proto)
    }

    private func emptyPortLabel(for port: ManifoldKit.Port) -> String {
        String(
            format: NSLocalizedString(
                "popover.port.empty",
                comment: "Inline label for an empty port slot."
            ),
            port.position
        )
    }

    private func accessibilityLabel(for port: ManifoldKit.Port) -> String {
        if port.connectedDevice == nil {
            return String(
                format: NSLocalizedString("popover.port.empty.accessibility", comment: ""),
                portKindAccessibilityName(port.kind),
                port.position
            )
        }
        guard let device = port.connectedDevice else { return "" }
        let proto = port.negotiated?.protocolName
            ?? NSLocalizedString("popover.device.unknown.protocol", comment: "")
        let powerStr = port.powerDraw?.formatted
            ?? NSLocalizedString("popover.device.unknown.power", comment: "")
        return String(
            format: NSLocalizedString(
                "popover.device.accessibility",
                comment: "Reused popover VoiceOver template."
            ),
            portKindAccessibilityName(port.kind),
            port.position,
            displayName(for: device),
            proto,
            powerStr
        )
    }

    /// Same lookup as DeviceRow / PortRow. Centralising in a future
    /// helper file is a Phase 7+ refactor; for Phase 6 the duplication
    /// is small enough to ignore.
    private func portKindAccessibilityName(_ kind: PortKind) -> String {
        switch kind {
        case .usbA:        return NSLocalizedString("popover.port.kind.usbA",        comment: "")
        case .usbC:        return NSLocalizedString("popover.port.kind.usbC",        comment: "")
        case .thunderbolt: return NSLocalizedString("popover.port.kind.thunderbolt", comment: "")
        case .hdmi:        return NSLocalizedString("popover.port.kind.hdmi",        comment: "")
        case .sd:          return NSLocalizedString("popover.port.kind.sd",          comment: "")
        case .audio:       return NSLocalizedString("popover.port.kind.audio",       comment: "")
        case .ethernet:    return NSLocalizedString("popover.port.kind.ethernet",    comment: "")
        case .magsafe:     return NSLocalizedString("popover.port.kind.magsafe",     comment: "")
        case .unknown:     return NSLocalizedString("popover.port.kind.unknown",     comment: "")
        }
    }
}

// MARK: - OutlineGroup helper (re-declared private here so this file compiles standalone)

private extension ManifoldKit.Port {
    var childrenForOutline: [ManifoldKit.Port]? {
        children.isEmpty ? nil : children
    }
}

#Preview("TopologyCanvas — populated") {
    let graph = PortGraph()
    graph.replace(hosts: [PreviewData.macBook])
    return TopologyCanvas(
        graph: graph,
        host: PreviewData.macBook,
        selectedDeviceID: .constant(PreviewData.sandiskSSD.id)
    )
    .frame(width: 480, height: 400)
    .background(Color.manifoldSurface)
}

#Preview("TopologyCanvas — empty") {
    TopologyCanvas(
        graph: PortGraph(),
        host: nil,
        selectedDeviceID: .constant(nil)
    )
    .frame(width: 480, height: 400)
    .background(Color.manifoldSurface)
}
