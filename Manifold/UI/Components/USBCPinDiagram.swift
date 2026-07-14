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
// USBCPinDiagram.swift
//
// Compact, live USB-C receptacle diagram used by CablePortCard. The
// decoding remains in the synced USBCPinMap model; this view only maps
// signal categories onto Manifold's visual language.

import SwiftUI

struct USBCPinDiagram: View {
    let map: USBCPinMap

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(map.orientationLabel, systemImage: orientationIcon)
                Spacer()
                Text(map.signalSummary)
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            pinRow(map.topRow)
            pinRow(map.bottomRow)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("cables.port.pinDiagram")
    }

    private func pinRow(_ pins: [USBCPinMap.Pin]) -> some View {
        HStack(spacing: 3) {
            ForEach(pins) { pin in
                VStack(spacing: 2) {
                    Text(pin.id)
                        .font(.system(size: 7, weight: .semibold, design: .monospaced))
                    Text(shortLabel(for: pin.signal))
                        .font(.system(size: 6, weight: .medium, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                }
                .foregroundStyle(foreground(for: pin.signal))
                .frame(maxWidth: .infinity, minHeight: 30)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(background(for: pin.signal))
                )
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(pin.id), \(pin.signal.label)")
            }
        }
    }

    private var orientationIcon: String {
        switch map.orientation {
        case 1: return "arrow.up"
        case 2: return "arrow.down"
        default: return "arrow.up.arrow.down"
        }
    }

    private func shortLabel(for signal: USBCPinMap.Signal) -> String {
        switch signal {
        case .inactive: return "—"
        case .ground: return "G"
        case .vbus: return "V+"
        case .cc: return "CC"
        case .usb2: return "U2"
        case .usb3PairA: return "U3A"
        case .usb3PairB: return "U3B"
        case .dpLane(let lane): return "DP\(lane)"
        case .dpAux: return "AUX"
        case .unknown: return "?"
        }
    }

    private func background(for signal: USBCPinMap.Signal) -> Color {
        switch signal {
        case .usb3PairA, .usb3PairB:
            return Color.manifoldAccent.opacity(0.22)
        case .dpLane, .dpAux:
            return Color.blue.opacity(0.20)
        case .vbus:
            return Color.manifoldWarning.opacity(0.18)
        case .inactive:
            return Color.secondary.opacity(0.06)
        default:
            return Color.secondary.opacity(0.12)
        }
    }

    private func foreground(for signal: USBCPinMap.Signal) -> Color {
        signal.isDynamic ? Color.manifoldAccent : Color.manifoldText
    }
}

struct LiquidDetectionCallout: View {
    let status: LiquidDetectionStatus

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "drop.triangle.fill")
                .foregroundStyle(Color.manifoldWarning)
            VStack(alignment: .leading, spacing: 2) {
                Text("Liquid detected")
                    .font(.callout.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.manifoldWarning.opacity(0.12))
        )
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("cables.port.liquidWarning")
    }

    private var detail: String {
        if status.mitigationsEnabled {
            return "\(status.state). Protective mitigations are active. Disconnect the cable and allow the port to dry."
        }
        return "\(status.state). Disconnect the cable and allow the port to dry."
    }
}

#if DEBUG
#Preview("USB-C pin diagram") {
    if let map = USBCPinMap.from(
        pinConfiguration: ["tx1": "1", "rx1": "2", "tx2": "6", "rx2": "7", "sbu1": "1", "sbu2": "2"],
        plugOrientation: 2
    ) {
        USBCPinDiagram(map: map)
            .padding()
            .frame(width: 520)
            .background(Color.manifoldCard)
    }
}
#endif
