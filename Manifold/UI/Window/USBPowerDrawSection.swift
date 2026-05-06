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
// ─────────────────────────────────────────────────────────────────────
// USBPowerDrawSection.swift
//
// "USB Power Draw" card extracted from the (now-removed) Power tab.
// Rendered at the top of the merged Battery tab so users see input
// (battery panel) and output (USB draw) on the same surface.
//
// Pure presentation — host-driven. The "is over budget" cue surfaces
// when total USB draw exceeds the active charger's input, matching
// the prior behaviour of the standalone tab.

import SwiftUI
import ManifoldKit

struct USBPowerDrawSection: View {

    let host: ManifoldKit.Host

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("window.power.section.draw")
                .font(.caption.smallCaps())
                .foregroundStyle(.secondary)

            HStack(alignment: .firstTextBaseline) {
                Text("window.power.field.totalDraw")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(host.totalPowerDraw.formatted)
                    .font(.subheadline.monospacedDigit().weight(isOverBudget ? .semibold : .regular))
                    .foregroundStyle(isOverBudget ? Color.manifoldCritical : Color.manifoldText)
                if isOverBudget {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(Color.manifoldCritical)
                        .help("window.power.overbudget.help")
                }
            }

            HStack(alignment: .firstTextBaseline) {
                Text("window.power.field.connectedDevices")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(host.ports.compactMap(\.connectedDevice).count)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(Color.manifoldText)
            }

            // Per-device breakdown — every connected device with a
            // known draw, sorted high → low so the biggest consumers
            // are at the top of the list.
            let drawingDevices = devicesByDraw
            if !drawingDevices.isEmpty {
                Divider().padding(.vertical, 4)
                ForEach(drawingDevices, id: \.id) { entry in
                    HStack(alignment: .firstTextBaseline) {
                        Image(systemName: "cable.connector")
                            .foregroundStyle(Color.manifoldAccent.opacity(0.7))
                            .frame(width: 16)
                        Text(entry.name)
                            .font(.subheadline)
                            .foregroundStyle(Color.manifoldText)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer()
                        Text(entry.watts.formatted)
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    /// Flatten every connected device with a known per-port draw.
    /// Sorted descending so the row reads "biggest consumer first."
    private var devicesByDraw: [DrawEntry] {
        var entries: [DrawEntry] = []
        func walk(_ ports: [ManifoldKit.Port]) {
            for port in ports {
                if let device = port.connectedDevice, let watts = port.powerDraw {
                    entries.append(DrawEntry(
                        id: device.id.rawValue,
                        name: device.displayName.isEmpty
                            ? "\(device.vendorID):\(device.productID)"
                            : device.displayName,
                        watts: watts
                    ))
                }
                walk(port.children)
            }
        }
        walk(host.ports)
        return entries.sorted { $0.watts.value > $1.watts.value }
    }

    /// True when total USB draw exceeds the active charger's input.
    /// "Soft" overdraw signal — macOS pulls the difference from the
    /// battery, but the row turns red so the user notices their
    /// headroom has gone negative.
    private var isOverBudget: Bool {
        guard let input = host.inputAdapter?.watts.value else { return false }
        return host.totalPowerDraw.value > input
    }

    private struct DrawEntry: Hashable {
        let id: String
        let name: String
        let watts: Watts
    }
}

#Preview("USBPowerDrawSection — populated") {
    USBPowerDrawSection(host: PreviewData.macBook)
        .padding()
        .frame(width: 540)
        .background(Color.manifoldSurface)
}
