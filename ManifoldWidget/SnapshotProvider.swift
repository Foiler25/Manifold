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
// SnapshotProvider.swift
//
// Per SPEC §18 Phase 13. Single TimelineProvider shared by every
// Phase-13 widget — they all render off the same `SnapshotV1`, so
// reading + decoding once per timeline refresh is the right
// shape.
//
// `getTimeline` returns a single entry that "expires" 15 minutes
// in the future; the host app's `WidgetCenter.shared.reloadAllTimelines()`
// call from `SnapshotCoordinator` is what drives real refreshes.
// The 15-minute expiry is the system's fallback so a widget that
// somehow misses every reload trigger doesn't sit stale forever.
//
// **No IOKit, ever.** This file imports WidgetKit + SwiftUI +
// ManifoldKit. ManifoldKit is IOKit-free by design.

import WidgetKit
import Foundation
import ManifoldKit

/// One timeline entry per snapshot read. Carries the resolved
/// `SnapshotV1` payload so widget bodies just read fields.
/// `kind` distinguishes "data is fresh" from "no snapshot found
/// yet" — the placeholder body uses the second.
struct SnapshotEntry: TimelineEntry {

    enum Kind {
        case data(SnapshotV1)
        case noData       // host app hasn't written yet (cold launch / persistence disabled)
        case unsupportedVersion(Int)
    }

    let date: Date
    let kind: Kind
}

struct SnapshotProvider: TimelineProvider {

    /// Placeholder is the redacted "what does this widget look like
    /// while macOS is rendering its preview" view. Returns a
    /// hand-built sample so the gallery preview is informative
    /// without touching disk.
    func placeholder(in context: Context) -> SnapshotEntry {
        SnapshotEntry(date: .now, kind: .data(SnapshotProvider.previewSnapshot))
    }

    /// Snapshot is the entry rendered when the widget appears. We
    /// read the live snapshot if available; fall back to the
    /// preview placeholder for the gallery (`context.isPreview`).
    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        if context.isPreview {
            completion(placeholder(in: context))
            return
        }
        completion(SnapshotEntry(date: .now, kind: readKind()))
    }

    /// Single entry, valid for 15 minutes. The host app's
    /// `WidgetCenter.shared.reloadAllTimelines()` overrides this
    /// timeline whenever the snapshot file changes; the 15-minute
    /// expiry is a fallback so a missed reload doesn't strand the
    /// widget.
    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        let entry = SnapshotEntry(date: .now, kind: readKind())
        let next = Date().addingTimeInterval(15 * 60)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }

    // MARK: - Disk read

    /// Resolve the App Support container, load `snapshot.json`,
    /// dispatch by schema version. Any failure surfaces as
    /// `.noData` (a cold-launch widget with no on-disk snapshot
    /// yet) or `.unsupportedVersion` (a future-snapshot file
    /// landed by a newer Manifold against this widget binary).
    private func readKind() -> SnapshotEntry.Kind {
        guard let containerURL = Snapshot.resolvedContainerURL() else {
            return .noData
        }
        do {
            let snapshot = try Snapshot.load(from: containerURL)
            switch snapshot {
            case .v1(let payload):
                return .data(payload)
            }
        } catch Snapshot.LoadError.unknownSchemaVersion(let version) {
            return .unsupportedVersion(version)
        } catch {
            // Most common cause: file doesn't exist yet (cold
            // launch). Treat as `.noData`; the next host-app
            // snapshot write will populate it.
            return .noData
        }
    }

    // MARK: - Preview fixture

    /// Placeholder snapshot for the WidgetKit gallery. Single fake
    /// device, 1.5 W draw, no diagnostics. Hand-coded so the
    /// gallery preview is meaningful without coupling to live
    /// PreviewData.
    static let previewSnapshot = SnapshotV1(
        schemaVersion: 1,
        writtenAt: Date(timeIntervalSince1970: 1_700_000_000),
        totalPowerDraw: Watts(1.5),
        connectedDeviceCount: 4,
        topDevicesByPower: [
            SnapshotV1.TopDevice(
                id: DeviceID("preview:01"),
                name: "Studio Display",
                powerDraw: Watts(0.9),
                kind: .display,
                recentSamples: [0.7, 0.8, 0.9, 0.85, 0.9]
            ),
            SnapshotV1.TopDevice(
                id: DeviceID("preview:02"),
                name: "SanDisk Extreme",
                powerDraw: Watts(0.45),
                kind: .storage,
                recentSamples: [0.4, 0.42, 0.45, 0.44, 0.45]
            ),
            SnapshotV1.TopDevice(
                id: DeviceID("preview:03"),
                name: "Logitech MX Master",
                powerDraw: Watts(0.1),
                kind: .input,
                recentSamples: [0.08, 0.1, 0.1, 0.09, 0.1]
            ),
            SnapshotV1.TopDevice(
                id: DeviceID("preview:04"),
                name: "USB-C Hub",
                powerDraw: Watts(0.05),
                kind: .hub,
                recentSamples: [0.05, 0.05, 0.05, 0.05, 0.05]
            )
        ],
        activeDiagnosticCount: 0,
        lastEventAt: Date(timeIntervalSince1970: 1_699_999_500)
    )
}

/// Compile-time IOKit guard: this file MUST NOT import IOKit. The
/// widget extension target's `nm` output should show zero IOKit
/// symbols. Reviewer enforces.
///
/// (No actual code here — this comment exists as a Reviewer
/// hot-spot anchor. The build verification is done by greping
/// the binary, not by Swift; see BUILD_LOG Phase 13 static checks.)
