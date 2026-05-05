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
// PortRow.swift
//
// One row inside the popover's `OutlineGroup` over `Host.ports`. When
// the port has a connected device, render `DeviceRow`; otherwise show
// the empty-port affordance.
//
// Phase 4's ports are always host-rooted (Phase 7 introduces hub
// trees). The recursive `children` keypath PortRow exposes is what
// `OutlineGroup` walks to render hub descendants — the row layout is
// the same at every depth.

import SwiftUI
import ManifoldKit

struct PortRow: View {

    let port: ManifoldKit.Port

    /// Phase 5: per-port telemetry buffer threaded through to
    /// `DeviceRow`. nil for empty ports (no device → no telemetry).
    let history: TelemetryBuffer?

    /// Phase 8: diagnostics whose `target` matches this port. Empty
    /// when the port is clean. Threaded in by `PopoverRoot` from
    /// `graph.diagnostics(forPortID:)`.
    let diagnostics: [Diagnostic]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let device = port.connectedDevice {
                DeviceRow(port: port, device: device, history: history)
            } else {
                emptyPortRow
            }
            if !diagnostics.isEmpty {
                badgeStrip
            }
        }
        // Force the row to fill the available width so the inner
        // `Spacer()` in DeviceRow / emptyPortRow can actually push
        // the trailing power/info icon to the row's trailing edge.
        // Without this, PortRow sizes to intrinsic content and the
        // trailing icon's x ends up dependent on the device name's
        // length — visibly misaligned across rows.
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Horizontal flow of `DiagnosticBadge`s. `WrappingHStack` would be
    /// nicer for >2 badges but that's a Phase 15 polish item; the
    /// expected per-port count in Phase 8 is 0–2 so a plain HStack
    /// fits the popover width.
    private var badgeStrip: some View {
        HStack(spacing: 6) {
            ForEach(diagnostics) { diagnostic in
                DiagnosticBadge(diagnostic: diagnostic)
            }
            Spacer()
        }
        .padding(.leading, 26)  // align under the device-row text column
    }

    /// "Port N — Empty" for ports with no connected device. Renders
    /// at lower visual weight (secondary foreground) so populated
    /// rows stand out.
    private var emptyPortRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "circle.dashed")
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 18, alignment: .center)
            Text(emptyPortLabel)
                .font(.body)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(emptyPortAccessibilityLabel)
    }

    private var emptyPortLabel: String {
        String(
            format: NSLocalizedString(
                "popover.port.empty",
                comment: "Label for an empty port slot (no device connected)."
            ),
            port.position
        )
    }

    private var emptyPortAccessibilityLabel: String {
        let kindLabel: String
        switch port.kind {
        case .usbA:        kindLabel = NSLocalizedString("popover.port.kind.usbA",        comment: "")
        case .usbC:        kindLabel = NSLocalizedString("popover.port.kind.usbC",        comment: "")
        case .thunderbolt: kindLabel = NSLocalizedString("popover.port.kind.thunderbolt", comment: "")
        case .hdmi:        kindLabel = NSLocalizedString("popover.port.kind.hdmi",        comment: "")
        case .sd:          kindLabel = NSLocalizedString("popover.port.kind.sd",          comment: "")
        case .audio:       kindLabel = NSLocalizedString("popover.port.kind.audio",       comment: "")
        case .ethernet:    kindLabel = NSLocalizedString("popover.port.kind.ethernet",    comment: "")
        case .magsafe:     kindLabel = NSLocalizedString("popover.port.kind.magsafe",     comment: "")
        case .unknown:     kindLabel = NSLocalizedString("popover.port.kind.unknown",     comment: "")
        }
        return String(
            format: NSLocalizedString(
                "popover.port.empty.accessibility",
                comment: "VoiceOver label for an empty port."
            ),
            kindLabel,
            port.position
        )
    }
}

#Preview("PortRow — populated (Logitech) with sparkline") {
    var buffer = TelemetryBuffer()
    for i in 0..<60 {
        buffer.append(TelemetrySample(
            timestamp: Date(timeIntervalSince1970: TimeInterval(i)),
            watts: Watts(0.5 + sin(Double(i) / 5.0) * 0.2),
            bitrate: nil
        ))
    }
    return PortRow(port: PreviewData.logitechPort, history: buffer, diagnostics: [])
        .padding()
        .background(Color.manifoldSurface)
}

#Preview("PortRow — empty USB-C") {
    PortRow(port: PreviewData.emptyUSBCPort, history: nil, diagnostics: [])
        .padding()
        .background(Color.manifoldSurface)
}

#Preview("PortRow — populated with diagnostic badge") {
    PortRow(
        port: PreviewData.logitechPort,
        history: nil,
        diagnostics: [PreviewData.runningAtUSB2Warning]
    )
    .padding()
    .background(Color.manifoldSurface)
}
