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
// DeviceRow.swift
//
// One connected device's row inside a `PortRow`. Per SPEC.md §13.1
// (popover) and §18 Phase 4's VoiceOver criterion: the accessibility
// label reads "USB Port N, <device name>, <protocol>, <watts>".
//
// Phase 4 has no charts — Phase 5's sparkline lands inside this row
// as a sibling subview.

import SwiftUI
import ManifoldKit

struct DeviceRow: View {

    let port: ManifoldKit.Port
    let device: Device

    /// Per-port telemetry buffer. nil → no samples yet (placeholder
    /// line); `.samples` feeds the inline TelemetryChart. The
    /// `@Observable` PortGraph re-renders the row on every append.
    let history: TelemetryBuffer?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: iconName(for: device.kind))
                    .font(.body)
                    .foregroundStyle(Color.manifoldAccent)
                    .frame(width: 18, alignment: .center)

                VStack(alignment: .leading, spacing: 2) {
                    Text(displayName)
                        .font(.body)
                        .foregroundStyle(Color.manifoldText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let subtitle = productSubtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Text(detailLine)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer()

                if let watts = port.powerDraw {
                    Text(watts.formatted)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            // Inline telemetry chart — same component as the inspector,
            // sized for the popover. Shows the "Awaiting samples"
            // placeholder until the first 1 Hz sample arrives so the
            // row's height stays stable on hot-plug.
            TelemetryChart(samples: history?.samples ?? [], style: .inline)
                .padding(.leading, 26)  // align with the name text, past the icon column
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    /// Friendly volume name when present, else the USB product string,
    /// else "Device VVVV:PPPP" as a last-resort fallback.
    /// Per Phase 6 Reviewer F14 the catalog literal lives in
    /// `popover.device.fallback.name`.
    private var displayName: String {
        if let friendly = device.friendlyName, !friendly.isEmpty {
            return friendly
        }
        if !device.name.isEmpty { return device.name }
        let vid = String(format: "%04X", device.vendorID)
        let pid = String(format: "%04X", device.productID)
        return String(
            format: NSLocalizedString(
                "popover.device.fallback.name",
                comment: "Fallback display name."
            ),
            vid, pid
        )
    }

    /// Secondary line under the device name when a friendly name has
    /// shadowed the USB product string — surfaces the manufacturer's
    /// model so the row still answers "what is this thing?" at a glance.
    /// Returns nil when there's nothing extra to show.
    private var productSubtitle: String? {
        guard let friendly = device.friendlyName,
              !friendly.isEmpty,
              !device.name.isEmpty,
              friendly != device.name else { return nil }
        return device.name
    }

    /// "VID:PID · Protocol". Power lives in the trailing column above
    /// so it doesn't appear here.
    private var detailLine: String {
        let proto = port.negotiated?.protocolName
            ?? NSLocalizedString("popover.device.unknown.protocol", comment: "Fallback protocol label.")
        return String(format: "%04X:%04X · %@", device.vendorID, device.productID, proto)
    }

    /// Map `DeviceKind` to an SF Symbol. Phase 15's polish pass may
    /// replace these with custom symbols; the SF Symbol fallbacks
    /// here read sensibly at the popover's font size.
    private func iconName(for kind: DeviceKind) -> String {
        switch kind {
        case .audio:      return "headphones"
        case .display:    return "display"
        case .input:      return "computermouse"
        case .storage:    return "externaldrive"
        case .hub:        return "powerplug"
        case .video:      return "camera"
        case .networking: return "network"
        case .other:      return "cable.connector"
        }
    }

    /// VoiceOver label per SPEC.md §18 Phase 4 example:
    ///   "USB Port 1, Logitech MX Master 3, USB 2.0, 0.5 watts"
    /// Uses the catalog format string `popover.device.accessibility`.
    /// Position + kind come from the parent port; PortRow renders the
    /// "USB Port N" label, but DeviceRow includes it in its own VO so
    /// the row reads as a single, complete sentence to VO users.
    private var accessibilityLabel: String {
        let portKindLabel = portKindAccessibilityName(port.kind)
        let proto = port.negotiated?.protocolName
            ?? NSLocalizedString("popover.device.unknown.protocol", comment: "")
        let powerStr = port.powerDraw?.formatted
            ?? NSLocalizedString("popover.device.unknown.power", comment: "Fallback when no power reading is available.")
        return String(
            format: NSLocalizedString(
                "popover.device.accessibility",
                comment: "VoiceOver label for one device row inside a port."
            ),
            portKindLabel,
            port.position,
            displayName,
            proto,
            powerStr
        )
    }

    /// Spoken kind label — "USB Port", "USB-C Port", "Thunderbolt
    /// Port" etc. Localised so VO reads the appropriate language.
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

// MARK: - Previews

private func previewBuffer(seed: Double) -> TelemetryBuffer {
    var b = TelemetryBuffer()
    for i in 0..<60 {
        b.append(TelemetrySample(
            timestamp: Date(timeIntervalSince1970: TimeInterval(i)),
            watts: Watts(seed + sin(Double(i) / 5.0) * 0.3 + Double(i) * 0.005),
            bitrate: nil
        ))
    }
    return b
}

#Preview("DeviceRow — Logitech mouse with sparkline") {
    DeviceRow(
        port: PreviewData.logitechPort,
        device: PreviewData.logitechMouse,
        history: previewBuffer(seed: 0.5)
    )
    .padding()
    .background(Color.manifoldSurface)
}

#Preview("DeviceRow — SanDisk SSD (high power) with sparkline") {
    DeviceRow(
        port: PreviewData.sandiskPort,
        device: PreviewData.sandiskSSD,
        history: previewBuffer(seed: 4.5)
    )
    .padding()
    .background(Color.manifoldSurface)
}

#Preview("DeviceRow — Studio Display, no history yet") {
    DeviceRow(
        port: PreviewData.studioDisplayPort,
        device: PreviewData.studioDisplay,
        history: nil
    )
    .padding()
    .background(Color.manifoldSurface)
}
