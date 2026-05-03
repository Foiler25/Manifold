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
// TopDevicesWidget.swift
//
// Per SPEC §18 Phase 13 #6. Desktop medium widget rendering the
// top 4 devices by power draw, each with a 30-sample sparkline.
//
// `Charts.framework` would give us prettier sparklines but it's
// heavyweight inside a widget extension (the WidgetKit memory
// budget on macOS is tight). A hand-drawn `Path` over the
// `recentSamples` array stays under the budget while looking
// distinctly Manifold (the popover sparkline uses Charts; the
// widget mimics the visual idiom).

import WidgetKit
import SwiftUI
import ManifoldKit

struct TopDevicesWidget: Widget {

    let kind = "ManifoldTopDevicesWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: SnapshotProvider()) { entry in
            TopDevicesEntryView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Top Devices")
        .description("The 4 devices currently drawing the most power, with sparklines.")
        .supportedFamilies([.systemMedium])
    }
}

struct TopDevicesEntryView: View {

    let entry: SnapshotEntry

    var body: some View {
        switch entry.kind {
        case .data(let payload):
            populated(payload)
        case .noData:
            empty(message: "Manifold has no snapshot yet — open the app once.")
        case .unsupportedVersion(let version):
            empty(message: "Snapshot version \(version) requires a newer widget.")
        }
    }

    // MARK: - Populated

    private func populated(_ payload: SnapshotV1) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: "bolt.fill")
                    .foregroundStyle(.tint)
                Text("Top Devices")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(payload.totalPowerDraw.formatted)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ForEach(payload.topDevicesByPower.prefix(4)) { device in
                row(for: device)
            }
            if payload.topDevicesByPower.isEmpty {
                Spacer()
                Text("No connected devices")
                    .font(.caption.italic())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                Spacer()
            }
        }
        .padding(.vertical, 2)
    }

    /// One row: device name (truncated), watts, sparkline.
    private func row(for device: SnapshotV1.TopDevice) -> some View {
        HStack(spacing: 6) {
            Text(device.name)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Sparkline(samples: device.recentSamples)
                .frame(width: 60, height: 14)
                .foregroundStyle(.tint)
            Text(device.powerDraw.formatted)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 50, alignment: .trailing)
        }
    }

    // MARK: - Empty

    private func empty(message: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "bolt.slash")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(8)
    }
}

/// Tiny hand-drawn sparkline. WidgetKit's memory budget makes
/// `Charts.framework` heavy here; a `Path` over the samples
/// array is what fits. Auto-scales to the max sample so the
/// curve always uses the full vertical range.
private struct Sparkline: View {

    let samples: [Double]

    var body: some View {
        GeometryReader { geo in
            Path { path in
                guard samples.count > 1 else { return }
                let maxValue = max(samples.max() ?? 1, 0.0001)
                let stepX = geo.size.width / CGFloat(samples.count - 1)
                for (index, sample) in samples.enumerated() {
                    let x = CGFloat(index) * stepX
                    let normalized = max(0, sample) / maxValue
                    let y = geo.size.height * (1 - CGFloat(normalized))
                    if index == 0 {
                        path.move(to: CGPoint(x: x, y: y))
                    } else {
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                }
            }
            .stroke(.tint, style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
        }
    }
}
