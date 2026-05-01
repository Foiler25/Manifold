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
// ManifoldWidgetBundle.swift
//
// `@main` entry for the widget extension target. The bundle aggregates
// every widget the extension publishes to the system. Phase 13 fills it
// with the four real widgets (PowerDraw, DeviceCount, TopDevices,
// ControlCenter) per SPEC.md §3 and §18; Phase 0 ships a single
// placeholder so the extension target builds cleanly.
//
// Why a placeholder widget rather than an empty bundle: `WidgetBundle`'s
// `@WidgetBundleBuilder` body must produce at least one `Widget`. Phase 0
// just needs the target to compile and link.

import WidgetKit
import SwiftUI

@main
struct ManifoldWidgetBundle: WidgetBundle {
    var body: some Widget {
        PlaceholderWidget()
    }
}

/// Single Phase-0 placeholder. Removed in Phase 13 when the real widgets
/// land. Renders a static label and never refreshes — `policy: .never`.
struct PlaceholderWidget: Widget {
    let kind = "ManifoldPlaceholderWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: PlaceholderProvider()) { _ in
            PlaceholderEntryView()
                // Required from iOS 17 / macOS 14: every widget body must
                // declare a `containerBackground`. Using `.fill.tertiary`
                // gives the system a sensible default to render the widget
                // chrome around.
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Manifold")
        .description("Phase-0 placeholder. Real widgets arrive in Phase 13.")
        .supportedFamilies([.systemSmall])
    }
}

/// Minimal `TimelineEntry` carrying nothing but a timestamp. Replaced in
/// Phase 13 by an entry type that decodes `ManifoldKit.Snapshot` from the
/// shared App Group container.
struct PlaceholderEntry: TimelineEntry {
    let date: Date
}

/// Static `TimelineProvider`. Returns one entry that never expires —
/// because Phase 0 has no live data to drive timeline refreshes yet.
struct PlaceholderProvider: TimelineProvider {

    func placeholder(in context: Context) -> PlaceholderEntry {
        PlaceholderEntry(date: .now)
    }

    func getSnapshot(in context: Context, completion: @escaping (PlaceholderEntry) -> Void) {
        completion(PlaceholderEntry(date: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PlaceholderEntry>) -> Void) {
        completion(Timeline(entries: [PlaceholderEntry(date: .now)], policy: .never))
    }
}

/// Phase-0 view body for the placeholder widget. Pure SwiftUI, no IOKit
/// references — the widget extension cannot link IOKit per SPEC.md §2.
struct PlaceholderEntryView: View {
    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: "bolt.horizontal.circle.fill")
                .font(.system(size: 28, weight: .regular))
            Text("Manifold")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
