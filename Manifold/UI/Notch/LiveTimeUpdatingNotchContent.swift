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
// LiveTimeUpdatingNotchContent.swift
//
// Wraps a static `BatteryNotchContent` with a live observation of
// `PortGraph.battery`. While the notch panel is displayed (typically
// 3 s for plug/unplug alerts), the time-remaining caption and the
// trailing percent re-render as the underlying battery snapshot
// updates — so the notification's figure tracks the popover instead
// of being frozen at the value sampled at fire time.
//
// Cost is bounded by the panel's lifespan: SwiftUI tears down the
// view tree on auto-dismiss, dropping the `PortGraph` observation.
// While no panel is on screen, this view doesn't exist and observes
// nothing.

import SwiftUI
import ManifoldKit

@MainActor
struct LiveTimeUpdatingNotchContent: View {

    /// Live `PortGraph` reference. `@Bindable` so the view re-renders
    /// each time `graph.battery` mutates (which the IOPS / interest
    /// observers do every kernel publication).
    @Bindable var graph: PortGraph

    /// Static fallback content sampled by `BatteryAlertEngine` at the
    /// moment the alert fired. Used as the initial render and as a
    /// fallback when the live `BatteryInfo` is unavailable
    /// (transients, post-panel-construction nil window).
    let base: BatteryNotchContent

    var body: some View {
        BatteryNotchContent(
            kind: base.kind,
            title: base.title,
            subtitle: base.subtitle,
            timeRemaining: liveTimeRemainingCaption() ?? base.timeRemaining,
            percent: graph.battery?.chargePercent ?? base.percent
        )
    }

    /// Re-formats the time-remaining caption against `graph.battery`,
    /// using the same direction the static caption represents (plug
    /// alerts → time-until-full, unplug alerts → time-until-empty).
    /// Other alert kinds keep their static caption verbatim.
    private func liveTimeRemainingCaption() -> String? {
        guard let battery = graph.battery else { return nil }
        let minutes: Int?
        switch base.kind {
        case .pluggedIn:
            // Don't override with a stale "until full" once the cell
            // is topped off — the static "fully charged" subtitle path
            // in BatteryAlertEngine is still the right thing to show.
            if battery.isFullyCharged { return nil }
            minutes = battery.timeUntilFullMinutes
        case .unplugged:
            minutes = battery.timeUntilEmptyMinutes
        case .lowBattery, .charged:
            // Threshold alerts don't carry a live time caption — the
            // event-tied data (the threshold itself) is the value.
            return nil
        }
        guard let minutes, minutes > 0 else { return nil }
        guard let duration = Self.formatter.string(from: TimeInterval(minutes * 60)) else {
            return nil
        }
        let formatKey: String
        switch base.kind {
        case .pluggedIn:
            formatKey = "notch.battery.alert.timeRemaining.untilFull"
        case .unplugged:
            formatKey = "notch.battery.alert.timeRemaining.untilEmpty"
        case .lowBattery, .charged:
            return nil
        }
        return String.localizedStringWithFormat(
            NSLocalizedString(
                formatKey,
                comment: "Live notch alert time-remaining caption — duration."
            ),
            duration
        )
    }

    /// Same formatter shape `BatteryAlertEngine` uses for its
    /// initial caption — abbreviated, hour+minute, max two units —
    /// so the live re-render visually matches the value the engine
    /// captured at fire time.
    private nonisolated static let formatter: DateComponentsFormatter = {
        let f = DateComponentsFormatter()
        f.unitsStyle = .abbreviated
        f.allowedUnits = [.hour, .minute]
        f.maximumUnitCount = 2
        f.zeroFormattingBehavior = .dropAll
        return f
    }()
}
