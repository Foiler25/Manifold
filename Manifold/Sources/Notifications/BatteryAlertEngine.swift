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
// BatteryAlertEngine.swift
//
// Phase 19 — stateful `@MainActor` consumer of `BatteryInfo`. Edge-
// triggered with 5-point hysteresis (SPEC §21.5 / D21). NOT a
// `DiagnosticRule` (D20 — those are pure functions; the alert engine
// needs history).
//
// The engine sits between the existing 50ms battery observer in
// `AppDelegate.startBatteryObserver` and the `NotchPanelController`.
// On every tick:
//
//   1. Master gate. If `@AppStorage(SettingsKeys.batteryAlertsEnabled)`
//      is false, the call is a no-op (no state mutation, no fire).
//   2. Plug / unplug edge — fires once on `isExternalConnected` flip.
//      First observation (lastIsExternalConnected == nil) does not
//      fire (avoids a bogus toast at app launch).
//   3. Low alerts — for each enabled `.low` config row, fire when
//      `prev > N && current <= N`. Re-arm when `current > N + 5`.
//   4. Charged alerts — for each enabled `.charged` row, fire when
//      `prev < N && current >= N && chargeState == .charging`.
//      Re-arm when `current < N - 5` OR on `lastIsExternalConnected →
//      false` (external disconnect).
//   5. Update `state` for the next tick.
//
// Idempotence: handling the same `BatteryInfo` twice in a row
// produces zero additional fires (the `prev` reference becomes
// `current` after the first call, so the edge condition fails on
// the second call). State persistence: in-memory only — re-arms
// naturally on app restart per D21.

import Foundation
import ManifoldKit
import SwiftUI

@MainActor
final class BatteryAlertEngine {

    // MARK: - State

    private struct State {
        /// Last percent we processed. Seeds at 100 so the first low
        /// crossing fires correctly — anything below 100 is "we
        /// observed a descent".
        var lastPercent: Int = 100
        /// Last charge state. Used by the charged-alert re-arm
        /// branch (re-arm on external disconnect).
        var lastChargeState: BatteryInfo.ChargeState = .unknown
        /// Last external-connected reading. `nil` = first
        /// observation; per SPEC §21.5 plug/unplug do NOT fire on
        /// the first observation (avoids the bogus "plugged in"
        /// toast at app launch on a charging Mac).
        var lastIsExternalConnected: Bool?
        /// Set of low-alert config IDs that have fired and have not
        /// yet re-armed. Cleared per row when `current > N + 5`.
        var firedLowAlertIDs: Set<UUID> = []
        /// Set of charged-alert config IDs that have fired and have
        /// not yet re-armed. Cleared per row when `current < N - 5`
        /// OR on external disconnect.
        var firedChargedAlertIDs: Set<UUID> = []
    }

    private var state = State()

    // MARK: - Dependencies

    /// Per-row preferences (alert list + power-source flags + master
    /// sound flag). Read-only inside `handle(_:)`.
    private let preferences: BatteryAlertPreferences

    /// Closure invoked when an alert should be presented. Production
    /// passes a closure that calls
    /// `notchPanelController.show(content:for:)`; tests inject a
    /// closure that records the calls so the state-machine
    /// assertions can verify the right alerts fired in the right
    /// order.
    ///
    /// Closure-based instead of holding `NotchPanelController?`
    /// directly so the engine has zero AppKit / NSPanel dependency
    /// at the type level — keeps the test target's compile graph
    /// minimal and matches the existing `NotificationService` shape
    /// (Phase 9).
    private let presenter: @MainActor (BatteryNotchContent, TimeInterval) -> Void

    /// Closure invoked to play a sound. Production wires the four
    /// `BatteryAlertSound.play*()` statics. Tests inject a recorder
    /// so the sound assertions can verify the right chime fires
    /// when the per-row + master sound flags compose correctly.
    private let player: @MainActor (BatteryNotchContent.Kind) -> Void

    /// Read of `@AppStorage(SettingsKeys.batteryAlertsEnabled)`.
    /// Closure-based for testability — the test target injects a
    /// closure that returns a programmable Bool. Production reads
    /// from `UserDefaults.standard`.
    private let isMasterEnabled: @MainActor () -> Bool

    /// Adapter description provider (e.g. "Manifold 65W USB-C") for
    /// the plug-in subtitle. Production reads from `PortGraph.hosts`
    /// `inputAdapter.description`; tests inject nil to exercise the
    /// fallback copy.
    private let adapterDescription: @MainActor () -> String?

    // MARK: - Init

    /// Production-flavor convenience init: the AppDelegate constructs
    /// the engine with the live preferences + the live notch panel
    /// controller, the live `BatteryAlertSound` statics, the live
    /// AppStorage read, and a live adapter-description lookup.
    convenience init(
        preferences: BatteryAlertPreferences,
        notchPanelController: NotchPanelController,
        adapterDescription: @MainActor @escaping () -> String?
    ) {
        self.init(
            preferences: preferences,
            presenter: { [weak notchPanelController] content, duration in
                notchPanelController?.show(content: content, for: duration)
            },
            player: { kind in
                switch kind {
                case .lowBattery: BatteryAlertSound.playLowBattery()
                case .charged:    BatteryAlertSound.playCharged()
                case .pluggedIn:  BatteryAlertSound.playPluggedIn()
                case .unplugged:  BatteryAlertSound.playUnplugged()
                }
            },
            isMasterEnabled: {
                // Default `true` mirrors `SettingsDefaults.batteryAlertsEnabled`.
                // `object(forKey:)` distinguishes "absent" from "stored
                // false", which `bool(forKey:)` collapses.
                if let stored = UserDefaults.standard.object(forKey: SettingsKeys.batteryAlertsEnabled) as? Bool {
                    return stored
                }
                return SettingsDefaults.batteryAlertsEnabled
            },
            adapterDescription: adapterDescription
        )
    }

    /// DI-friendly init for tests. Each closure is captured + invoked
    /// on MainActor — the engine itself is `@MainActor` so the
    /// captured closures all run on the main thread.
    init(
        preferences: BatteryAlertPreferences,
        presenter: @MainActor @escaping (BatteryNotchContent, TimeInterval) -> Void,
        player: @MainActor @escaping (BatteryNotchContent.Kind) -> Void,
        isMasterEnabled: @MainActor @escaping () -> Bool,
        adapterDescription: @MainActor @escaping () -> String?
    ) {
        self.preferences = preferences
        self.presenter = presenter
        self.player = player
        self.isMasterEnabled = isMasterEnabled
        self.adapterDescription = adapterDescription
    }

    // MARK: - Tick handler

    /// Called on every battery-observation tick. Idempotent on
    /// repeated identical inputs — the second identical call's `prev`
    /// matches `current`, so no edge condition fires.
    func handle(_ info: BatteryInfo) {
        guard isMasterEnabled() else { return }

        let prevPercent = state.lastPercent
        let currentPercent = info.chargePercent
        let prevExternal = state.lastIsExternalConnected
        let currentExternal = info.isExternalConnected

        // ---- 1. Plug / unplug -------------------------------------
        // First observation: do not fire (`prevExternal == nil`).
        if let prevExternal {
            if !prevExternal && currentExternal {
                firePluggedIn()
            } else if prevExternal && !currentExternal {
                fireUnplugged()
            }
        }

        // ---- 2. Re-arm on external disconnect ---------------------
        // SPEC §21.5: charged alerts re-arm on `lastIsExternalConnected
        // → false`. Cleared BEFORE the charged-fire pass so a single
        // tick with both an unplug AND a charged crossing (degenerate)
        // re-arms cleanly.
        if let prevExternal, prevExternal && !currentExternal {
            state.firedChargedAlertIDs.removeAll()
        }

        // ---- 3. Low alerts ----------------------------------------
        for row in preferences.enabledAlerts(of: .low) {
            // Re-arm when current > N + hysteresis.
            if currentPercent > row.percent + BatteryAlertEngineConstants.hysteresisPoints {
                state.firedLowAlertIDs.remove(row.id)
            }
            // Fire on descending crossing, but only if not already fired.
            let crossed = prevPercent > row.percent && currentPercent <= row.percent
            if crossed, !state.firedLowAlertIDs.contains(row.id) {
                state.firedLowAlertIDs.insert(row.id)
                fireLowBattery(percent: currentPercent, row: row)
            }
        }

        // ---- 4. Charged alerts ------------------------------------
        for row in preferences.enabledAlerts(of: .charged) {
            // Re-arm when current < N - hysteresis.
            if currentPercent < row.percent - BatteryAlertEngineConstants.hysteresisPoints {
                state.firedChargedAlertIDs.remove(row.id)
            }
            // Fire on ascending crossing while charging.
            let crossed = prevPercent < row.percent && currentPercent >= row.percent
            let charging = info.chargeState == .charging
            if crossed, charging, !state.firedChargedAlertIDs.contains(row.id) {
                state.firedChargedAlertIDs.insert(row.id)
                fireCharged(percent: currentPercent, row: row)
            }
        }

        // ---- 5. Update state for next tick ------------------------
        state.lastPercent = currentPercent
        state.lastChargeState = info.chargeState
        state.lastIsExternalConnected = currentExternal
    }

    // MARK: - Fire paths

    private func fireLowBattery(percent: Int, row: BatteryAlertConfig) {
        let content = BatteryNotchContent(
            kind: .lowBattery,
            title: "notch.battery.alert.low.title",
            subtitle: LocalizedStringKey(
                String(format: NSLocalizedString(
                    "notch.battery.alert.low.subtitle.format",
                    comment: "Phase 19 low-battery subtitle. %1$lld = current percent."
                ), percent)
            )
        )
        presenter(content, BatteryAlertEngineConstants.thresholdAlertDuration)
        if row.playsSound, preferences.batteryAlertsSoundEnabled {
            player(.lowBattery)
        }
    }

    private func fireCharged(percent: Int, row: BatteryAlertConfig) {
        let content = BatteryNotchContent(
            kind: .charged,
            title: LocalizedStringKey(
                String(format: NSLocalizedString(
                    "notch.battery.alert.charged.title.format",
                    comment: "Phase 19 charged-battery title. %1$lld = threshold percent."
                ), row.percent)
            ),
            subtitle: LocalizedStringKey(
                String(format: NSLocalizedString(
                    "notch.battery.alert.charged.subtitle.format",
                    comment: "Phase 19 charged-battery subtitle. %1$lld = current percent."
                ), percent)
            )
        )
        presenter(content, BatteryAlertEngineConstants.thresholdAlertDuration)
        if row.playsSound, preferences.batteryAlertsSoundEnabled {
            player(.charged)
        }
    }

    private func firePluggedIn() {
        guard preferences.pluggedInEnabled else { return }
        let subtitle: LocalizedStringKey = adapterDescription()
            .map { LocalizedStringKey($0) }
            ?? "notch.battery.alert.pluggedIn.subtitle"
        let content = BatteryNotchContent(
            kind: .pluggedIn,
            title: "notch.battery.alert.pluggedIn.title",
            subtitle: subtitle
        )
        presenter(content, BatteryAlertEngineConstants.powerSourceAlertDuration)
        if preferences.pluggedInPlaysSound, preferences.batteryAlertsSoundEnabled {
            player(.pluggedIn)
        }
    }

    private func fireUnplugged() {
        guard preferences.unpluggedEnabled else { return }
        let content = BatteryNotchContent(
            kind: .unplugged,
            title: "notch.battery.alert.unplugged.title",
            subtitle: "notch.battery.alert.unplugged.subtitle"
        )
        presenter(content, BatteryAlertEngineConstants.powerSourceAlertDuration)
        if preferences.unpluggedPlaysSound, preferences.batteryAlertsSoundEnabled {
            player(.unplugged)
        }
    }
}

// MARK: - Constants

enum BatteryAlertEngineConstants {
    /// Hysteresis buffer in percent points. Re-arm requires the
    /// percent to move N points beyond the threshold (high side for
    /// low alerts, low side for charged alerts) so single-step jitter
    /// doesn't re-fire alerts. Per D21 / SPEC §21.5.
    static let hysteresisPoints: Int = 5

    /// Auto-dismiss duration for low / charged alerts in seconds.
    /// 4s is brief enough not to nag, long enough to read. Per Q22.
    static let thresholdAlertDuration: TimeInterval = 4.0

    /// Auto-dismiss for plug / unplug alerts. 3s — slightly shorter
    /// because the user just took the physical action and doesn't
    /// need to study the alert. Per Q22.
    static let powerSourceAlertDuration: TimeInterval = 3.0
}

