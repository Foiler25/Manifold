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
                // `.top` alignment so the chip rectangles always
                // share a top baseline. Without it the HStack's
                // default center alignment pushes the SD chip down
                // when its caption (a small SF Symbol) renders at a
                // different intrinsic height than the digit captions
                // on the numbered chips.
                HStack(alignment: .top, spacing: 8) {
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
                // Bolt overlay for power-only (charger) ports — same
                // glyph the battery menu-bar item uses for "charging".
                // Tinted dark so it reads against the green chip the
                // way the bolt reads against the white battery icon.
                .overlay {
                    if port.state == .powerOnly {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 9, weight: .heavy))
                            .foregroundStyle(Color.black.opacity(0.75))
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(Color.manifoldText.opacity(0.15), lineWidth: 0.5)
                )
            Text("\(port.position)")
                .font(.caption2.monospacedDigit().weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var fill: Color {
        switch port.state {
        case .empty:      return Color.manifoldText.opacity(0.08)
        case .dataDevice: return Color.manifoldAccent
        // `.powerOnly` is essentially "charger plugged in" on Mac
        // hardware — flip to the same accent green the data-device
        // case uses so the chip reads as "active" rather than
        // "warning". The bolt overlay differentiates from a data
        // device at a glance.
        case .powerOnly:  return Color.manifoldAccent
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

/// Phase 20: chip variant for the built-in SD card slot. Same chip
/// shape + dimensions + tinting as `PortChip` so the strip reads as
/// a uniform row. The caption beneath shows an SF Symbol `sdcard`
/// glyph instead of a position number — SD doesn't carry a meaningful
/// "port 4" label next to USB-C 1/2/3, but the glyph keeps the
/// caption row visually balanced with the numbered chips and tells
/// the user "this one is the SD slot."
private struct SDPortChip: View {

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
            // Glyph caption — sized to match the visual height of
            // the numbered chips' "1" / "2" / "3" digits. SF Symbols
            // draw to the full cap-height of the font box while
            // digits only fill cap-height-to-baseline, so a glyph at
            // the same point size as the digits looks visibly
            // larger. `.imageScale(.small)` shrinks the symbol's
            // drawn box to ~80%, which lands the glyph at about the
            // same visible height as the bold digits beside it.
            Image(systemName: glyphName)
                .font(.caption2.weight(.semibold))
                .imageScale(.small)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var fill: Color {
        switch port.state {
        case .empty:      return Color.manifoldText.opacity(0.08)
        case .dataDevice: return Color.manifoldAccent
        // Match the numbered PortChip's powerOnly treatment so an
        // SD-slot chip in the rare powerOnly case reads consistently.
        case .powerOnly:  return Color.manifoldAccent
        case .unknown:    return Color.manifoldText.opacity(0.15)
        }
    }

    /// Filled glyph when a card is inserted (matches the populated-
    /// chip "this one has stuff" cue), outlined otherwise.
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
