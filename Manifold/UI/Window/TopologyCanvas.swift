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
        let rootPorts = PortGraph.displayableRootPorts(for: host)
        let anyExpandable = TopologyOutline<EmptyView>.anyExpandable(in: rootPorts)
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                topologyHeader(host: host)
                ForEach(rootPorts, id: \.id) { port in
                    TopologyOutline(
                        port: port,
                        depth: 0,
                        anyExpandable: anyExpandable,
                        selectedDeviceID: $selectedDeviceID,
                        rowContent: { node in topologyRow(port: node) },
                        isSelected: isSelected(_:)
                    )
                }
            }
            // Leading inset so the disclosure chevron has breathing
            // room from the topology pane's left edge. Skipped when
            // no hubs exist anywhere — the rows flush left without
            // the chevron gutter.
            .padding(
                .leading,
                anyExpandable ? TopologyCanvasConstants.outlineLeadingInset : 0
            )
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
            } else if let capacity = capacityCaption(for: port) {
                // Phase 20: SD card capacity in the same column USB
                // shows watts in. Mirrors DeviceRow.
                Text(capacity)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else if port.connectedDevice != nil, portCarriesUSB(port) {
                // Mirrors DeviceRow's behaviour: macOS sometimes omits
                // the power property on small HID dongles. Surface an
                // info icon so the row doesn't read as "0 W" by silence.
                Image(systemName: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("popover.device.power.unavailable.tooltip")
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel(for: port))
    }

    /// Phase 20: capacity caption ("32 GB") for storage devices that
    /// advertise it. Returns nil for everything that doesn't fill
    /// `Device.storageCapacityBytes` (every non-SD device today).
    private func capacityCaption(for port: ManifoldKit.Port) -> String? {
        guard let bytes = port.connectedDevice?.storageCapacityBytes,
              bytes > 0 else { return nil }
        return Self.byteCountFormatter.string(fromByteCount: Int64(bytes))
    }

    /// Decimal style so a 32 GB card reads "32 GB" — matches the
    /// number printed on the sticker. Binary would render "29.7 GB"
    /// for the same card.
    private static let byteCountFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .decimal
        f.allowsNonnumericFormatting = false
        return f
    }()

    /// True for ports that carry USB protocol — USB-A, USB-C,
    /// Thunderbolt. Matches the DeviceRow scoping rule: silence is
    /// only meaningful (and thus worth flagging) on USB-bearing ports.
    private func portCarriesUSB(_ port: ManifoldKit.Port) -> Bool {
        switch port.kind {
        case .usbA, .usbC, .thunderbolt: return true
        case .hdmi, .sd, .audio, .ethernet, .magsafe, .unknown: return false
        }
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
        // SD slots aren't numbered like USB-C ports — render as
        // "SD — Empty" so the row matches the chip-strip glyph
        // and the user's mental model of "the slot." Phase 20.
        if port.kind == .sd {
            return NSLocalizedString(
                "popover.port.empty.sd",
                comment: "Topology row label for the empty built-in SD card slot."
            )
        }
        return String(
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

// MARK: - Constants

enum TopologyCanvasConstants {
    /// Width of the dedicated chevron column. Always reserved on
    /// every row — `chevron.right`/`down` on expandable rows, empty
    /// `Color.clear` on leaves — so the plug icon and the trailing
    /// power/info icon both land at consistent x's regardless of
    /// depth or expandability.
    static let chevronColumnWidth: CGFloat = 18.0

    /// Per-depth indent for nested children. Each level shifts the
    /// row's content this many points to the right.
    static let outlineIndentPerLevel: CGFloat = 16.0

    /// Leading inset on the outline container so the disclosure
    /// chevron has breathing room from the topology pane's left
    /// edge instead of being jammed against it.
    static let outlineLeadingInset: CGFloat = 10.0
}

// MARK: - TopologyOutline

/// Custom recursive replacement for `OutlineGroup`, mirroring the
/// `PortOutline` view used by the popover. SwiftUI's `OutlineGroup`
/// produced rows whose intrinsic width fought every
/// `.frame(maxWidth: .infinity)` we added — leaf rows ended up
/// narrower than expandable rows and the trailing power / info
/// icons sat at different x's across the list.
///
/// `TopologyOutline` controls every column directly: a fixed-width
/// chevron gutter (filled with `chevron.down/right` for hubs,
/// `Color.clear` for leaves) plus the caller-supplied row content
/// (a `topologyRow(port:)`) that fills the remaining width.
/// Nested children are rendered recursively at `depth + 1`.
///
/// Disclosure state is `@State` (per-instance, in-memory). The
/// stand-alone window can graduate to `@SceneStorage` later if a
/// user wants the tree state to persist across reopens.
struct TopologyOutline<Row: View>: View {
    let port: ManifoldKit.Port
    let depth: Int
    /// `true` when any port in the host tree has children. When
    /// `false` (host with zero hubs anywhere), the chevron column
    /// AND the per-depth indent collapse to zero width — there's
    /// no disclosure to surface, so the rows flush left instead of
    /// carrying an always-empty gutter. Computed once at the root
    /// scope.
    let anyExpandable: Bool
    @Binding var selectedDeviceID: DeviceID?
    let rowContent: (ManifoldKit.Port) -> Row
    let isSelected: (ManifoldKit.Port) -> Bool
    @State private var isExpanded: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 0) {
                if anyExpandable, depth > 0 {
                    Color.clear
                        .frame(
                            width: CGFloat(depth) * TopologyCanvasConstants.outlineIndentPerLevel
                        )
                }
                chevronColumn
                rowContent(port)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .onTapGesture {
                if let device = port.connectedDevice {
                    selectedDeviceID = device.id
                }
            }
            .background(
                isSelected(port)
                    ? Color.manifoldAccent.opacity(0.18)
                    : Color.clear
            )

            if isExpanded, !port.children.isEmpty {
                ForEach(port.children, id: \.id) { child in
                    TopologyOutline(
                        port: child,
                        depth: depth + 1,
                        anyExpandable: anyExpandable,
                        selectedDeviceID: $selectedDeviceID,
                        rowContent: rowContent,
                        isSelected: isSelected
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var chevronColumn: some View {
        if !anyExpandable {
            EmptyView()
        } else if !port.children.isEmpty {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    isExpanded.toggle()
                }
            } label: {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(
                        width: TopologyCanvasConstants.chevronColumnWidth,
                        alignment: .center
                    )
            }
            .buttonStyle(.plain)
        } else {
            Color.clear
                .frame(width: TopologyCanvasConstants.chevronColumnWidth)
        }
    }

    /// Recursive check — `true` when this port or any of its
    /// descendants has children. Used at the root scope to compute
    /// the `anyExpandable` flag once for the whole tree.
    static func anyExpandable(in ports: [ManifoldKit.Port]) -> Bool {
        ports.contains { port in
            !port.children.isEmpty || TopologyOutline.anyExpandable(in: port.children)
        }
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
