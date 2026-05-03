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
// WatchForDeviceConnectIntent.swift
//
// Per SPEC §11.2. Returns the most-recently-attached device that
// matches the supplied filters (name substring / vendor / product).
// Returns nil when no matching attached event is in the recent
// event log.
//
// On the SPEC's `PredictableIntent` conformance: the modern macOS
// AppIntents framework expresses "fires automatically when a
// matching event happens" via system donations + the App Shortcuts
// system, not via PredictableIntent. Phase 12 ships the intent as a
// query-style `AppIntent`: the user invokes it from Shortcuts (or
// a Shortcut runs it on a schedule) and gets the most-recent
// matching attached device since the persistence horizon. The
// "automatic trigger when device connects" semantics fall out of
// pairing this with an Automation in Shortcuts.app that polls the
// intent on a Timer or runs it from a Notification action.
// Documented as a SPEC §11 deviation; revisit in Phase 12+ once
// IntentDonationManager + Predictions are wired (Phase 15 polish).

import AppIntents
import ManifoldKit

struct WatchForDeviceConnectIntent: AppIntent {

    static let title: LocalizedStringResource = "intent.watchForDeviceConnect.title"
    static let description = IntentDescription(
        "intent.watchForDeviceConnect.description"
    )

    @Parameter(title: "intent.parameter.matchByName")
    var nameContains: String?

    @Parameter(title: "intent.parameter.matchByVendor")
    var vendorID: Int?

    @Parameter(title: "intent.parameter.matchByProduct")
    var productID: Int?

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<DeviceEntity?> {
        guard let source = IntentEnvironment.dataSource else {
            return .result(value: nil)
        }

        // Look at the persistent event log first — that's the most
        // recent attached events even after a relaunch. Fall back
        // to the live graph for the cold-launch case where no
        // events have persisted yet.
        let recent = (try? await source.recentEvents(limit: 200)) ?? []
        for event in recent where event.kind == .attached {
            if let entity = matchInLiveGraph(eventDeviceID: event.deviceID) {
                return .result(value: entity)
            }
        }
        // Fallback: any live device that matches the filters.
        let liveMatches = IntentDevices.collect(filteringByHost: nil).first(where: matches)
        return .result(value: liveMatches)
    }

    /// Look up the event's device in the LIVE graph (so the entity
    /// has current power-draw). Returns nil if the device isn't
    /// currently connected (it was attached at some past point but
    /// has since been unplugged) — caller continues to the next
    /// recent event.
    @MainActor
    private func matchInLiveGraph(eventDeviceID: DeviceID?) -> DeviceEntity? {
        guard let eventDeviceID,
              let entity = IntentDevices.collect(filteringByHost: nil).first(where: { $0.deviceID == eventDeviceID }),
              matches(entity)
        else { return nil }
        return entity
    }

    /// Predicate combining the three optional filters via AND. nil
    /// filters are wildcards (match any value).
    private func matches(_ entity: DeviceEntity) -> Bool {
        if let nameContains, !entity.name.localizedCaseInsensitiveContains(nameContains) {
            return false
        }
        if let vendorID, Int(entity.vendorID) != vendorID {
            return false
        }
        if let productID, Int(entity.productID) != productID {
            return false
        }
        return true
    }
}
