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
// PowerWidget.swift
//
// Per SPEC §18 Phase 13 #4 + #5. macOS-targeted variant: SPEC #4
// originally listed `.accessoryCircular` (lock-screen circular)
// alongside the desktop small. macOS doesn't ship the
// `accessoryCircular` family — that's iOS-lock-screen-specific.
// The Mac analogue is StandBy (which uses the same accessory
// families), but the widget extension target deploys to macOS
// only per the project setup. Phase 13 ships `.systemSmall` only
// for this widget; the on-Mac equivalent of "always-on quick read"
// is the menu bar `NSStatusItem` + the Control Center widget
// (`ControlCenterWidget.swift`). Documented as a Phase 13
// deviation in BUILD_LOG.

import WidgetKit
import SwiftUI
import ManifoldKit

struct PowerWidget: Widget {

    let kind = "ManifoldPowerWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: SnapshotProvider()) { entry in
            PowerWidgetEntryView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Manifold Power")
        .description("Total USB + Thunderbolt power draw, plus connected device count.")
        .supportedFamilies([.systemSmall])
    }
}

struct PowerWidgetEntryView: View {

    @Environment(\.widgetFamily) private var widgetFamily

    let entry: SnapshotEntry

    var body: some View {
        // PowerWidget supports `.systemSmall` only on macOS. The
        // switch keeps the layout extensible for future families
        // (e.g., StandBy support on macOS 27+).
        small
    }

    // MARK: - Desktop small

    /// Bolt icon + "N devices" + total power. Three lines. Title
    /// at the top; the small format gives us enough room for the
    /// summary without a sparkline (sparkline lives in the medium
    /// widget).
    private var small: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: "bolt.fill")
                    .foregroundStyle(.tint)
                Text("Manifold")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Text(headlineText)
                .font(.title2.bold().monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(deviceCountSubtitle)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Strings

    private var headlineText: String {
        switch entry.kind {
        case .data(let payload):
            return payload.totalPowerDraw.formatted
        case .noData:
            return "—"
        case .unsupportedVersion:
            return "?"
        }
    }

    private var deviceCountSubtitle: String {
        switch entry.kind {
        case .data(let payload):
            return payload.connectedDeviceCount == 1
                ? "1 device"
                : "\(payload.connectedDeviceCount) devices"
        case .noData:
            return "no data yet"
        case .unsupportedVersion(let version):
            return "v\(version) unsupported"
        }
    }
}
