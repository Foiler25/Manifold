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
// PortOccupancyView.swift
//
// Compact horizontal indicator strip for `Host.physicalPorts`. Shows
// every chassis USB-C port as a labelled square color-coded by
// occupancy state. Surfaces the power-only sink case (a charging
// USB-C device with no data lines) that the main port tree can't
// represent — a CC-only contract never enters IOUSB so there's
// nothing for `PortRow` to render.
//
// Hidden when `physicalPorts` is empty (Intel Macs, Apple Silicon
// variants where `AppleTCControllerType10` doesn't exist, or the
// walker soft-failed). The host header sits directly above where the
// section would be, so eliding the section costs no layout shift.

import SwiftUI
import ManifoldKit

struct PortOccupancyView: View {

    let ports: [PhysicalPort]

    /// Numbered chips first (USB-C / MagSafe / unknown), then the SD
    /// chip(s) on the right. Phase 20: split so the SD chip can use
    /// a custom glyph instead of a position number, keeping the row
    /// readable as "the USB-C ports, plus the SD slot."
    private var numberedPorts: [PhysicalPort] {
        ports.filter { $0.kind != .sd }
    }
    private var sdPorts: [PhysicalPort] {
        ports.filter { $0.kind == .sd }
    }

    var body: some View {
        if ports.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("popover.physicalPorts.title")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    ForEach(numberedPorts) { port in
                        PortChip(port: port)
                    }
                    ForEach(sdPorts) { port in
                        SDPortChip(port: port)
                    }
                    Spacer()
                }
            }
            .accessibilityElement(children: .contain)
        }
    }
}

private struct PortChip: View {

    let port: PhysicalPort

    var body: some View {
        VStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(fill)
                .frame(width: 28, height: 14)
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(Color.manifoldText.opacity(0.15), lineWidth: 0.5)
                )
            Text("\(port.position)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var fill: Color {
        switch port.state {
        case .empty:      return Color.manifoldText.opacity(0.08)
        case .dataDevice: return Color.manifoldAccent
        case .powerOnly:  return Color.manifoldWarning
        case .unknown:    return Color.manifoldText.opacity(0.15)
        }
    }

    private var accessibilityLabel: String {
        let stateKey: String
        switch port.state {
        case .empty:      stateKey = "popover.physicalPorts.state.empty"
        case .dataDevice: stateKey = "popover.physicalPorts.state.dataDevice"
        case .powerOnly:  stateKey = "popover.physicalPorts.state.powerOnly"
        case .unknown:    stateKey = "popover.physicalPorts.state.unknown"
        }
        return String(
            format: NSLocalizedString(
                "popover.physicalPorts.accessibility",
                comment: "VoiceOver label for one chassis port chip."
            ),
            port.position,
            NSLocalizedString(stateKey, comment: "")
        )
    }
}

// MARK: - SD chip

/// Phase 20: chip variant for the built-in SD card slot. Same shape
/// + dimensions as `PortChip` (so the row reads as a uniform strip),
/// but renders an SF Symbol `sdcard` glyph inside instead of a
/// position number — SD doesn't carry a meaningful "port 4" label
/// next to USB-C 1/2/3, and the glyph distinguishes it at a glance.
/// State tinting matches `PortChip.fill`.
private struct SDPortChip: View {

    let port: PhysicalPort

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(fill)
                    .frame(width: 28, height: 14)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .stroke(Color.manifoldText.opacity(0.15), lineWidth: 0.5)
                    )
                Image(systemName: glyphName)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.95))
            }
            // Empty caption matching the height of the numbered chip's
            // position label so the strip stays vertically aligned.
            // No text content — the glyph carries the meaning.
            Text(" ")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.clear)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var fill: Color {
        switch port.state {
        case .empty:      return Color.manifoldText.opacity(0.08)
        case .dataDevice: return Color.manifoldAccent
        case .powerOnly:  return Color.manifoldWarning
        case .unknown:    return Color.manifoldText.opacity(0.15)
        }
    }

    private var glyphName: String {
        switch port.state {
        case .dataDevice: return "sdcard.fill"
        default:          return "sdcard"
        }
    }

    private var accessibilityLabel: String {
        let key: String
        switch port.state {
        case .dataDevice: key = "popover.physicalPorts.sd.accessibility.populated"
        default:          key = "popover.physicalPorts.sd.accessibility.empty"
        }
        return NSLocalizedString(key, comment: "VoiceOver label for the SD card slot chip.")
    }
}

#Preview("PortOccupancyView — mixed states") {
    PortOccupancyView(ports: [
        PhysicalPort(position: 1, kind: .usbC, state: .powerOnly),
        PhysicalPort(position: 2, kind: .usbC, state: .dataDevice),
        PhysicalPort(position: 3, kind: .usbC, state: .empty),
        PhysicalPort(position: 4, kind: .usbC, state: .empty),
    ])
    .padding()
    .background(Color.manifoldSurface)
}

#Preview("PortOccupancyView — empty (hidden)") {
    PortOccupancyView(ports: [])
        .padding()
        .background(Color.manifoldSurface)
}
