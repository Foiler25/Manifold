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
// ControlCenterWidget.swift
//
// Per SPEC §18 Phase 13 #7. macOS Control Center widget. Renders a
// compact device-count + bolt icon; tap opens the menu bar
// popover via the Manifold app's URL scheme (or falls back to a
// plain `open -b com.Loofa.Manifold` if the URL scheme is
// unregistered).
//
// `ControlWidget` is the right primitive on macOS 26 — it gives us
// a tappable launcher in Control Center that the system manages.
// We don't need a `Provider` or `TimelineEntry`; the widget body
// reads the snapshot synchronously each render.

import WidgetKit
import SwiftUI
import ManifoldKit
import AppIntents

struct ControlCenterWidget: ControlWidget {

    let kind = "ManifoldControlCenterWidget"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: kind, provider: ControlCenterSnapshotProvider()) { snapshot in
            ControlWidgetButton(action: OpenManifoldIntent()) {
                Label {
                    Text("\(snapshot.deviceCount) devices")
                        .monospacedDigit()
                } icon: {
                    Image(systemName: snapshot.deviceCount == 0 ? "bolt.slash" : "bolt.fill")
                }
            }
        }
        .displayName("Manifold")
        .description("Tap to open the Manifold popover.")
    }
}

// MARK: - ControlValueProvider

/// Compact provider returning just the device count. Reads the
/// same `snapshot.json` the timeline-driven widgets use.
struct ControlCenterSnapshotProvider: ControlValueProvider {

    /// Default placeholder for the gallery preview.
    var previewValue: ControlSnapshot { ControlSnapshot(deviceCount: 4) }

    func currentValue() async throws -> ControlSnapshot {
        guard let containerURL = Snapshot.resolvedContainerURL(),
              let snapshot = try? Snapshot.load(from: containerURL),
              case .v1(let payload) = snapshot
        else {
            return ControlSnapshot(deviceCount: 0)
        }
        return ControlSnapshot(deviceCount: payload.connectedDeviceCount)
    }
}

struct ControlSnapshot {
    let deviceCount: Int
}

// MARK: - OpenManifoldIntent

/// Tap action: open the Manifold app. macOS routes this through
/// `LSOpenURLs` against the bundle ID; AppDelegate's
/// `applicationDidBecomeActive` opens the popover when no other
/// surface is visible.
///
/// Why an `AppIntent` and not a deep-link URL: ControlWidgetButton's
/// `action:` parameter accepts any `AppIntent`, and the AppIntent
/// shape gives us the right semantic — Shortcuts could in theory
/// trigger this same intent to open the app on a schedule.
struct OpenManifoldIntent: AppIntent {

    static let title: LocalizedStringResource = "Open Manifold"
    static let openAppWhenRun: Bool = true

    init() {}

    func perform() async throws -> some IntentResult {
        // Returning `.result()` while `openAppWhenRun = true` tells
        // macOS to bring the host app to the foreground. AppDelegate
        // sees the activation and (if no window is visible) opens
        // the popover.
        .result()
    }
}
