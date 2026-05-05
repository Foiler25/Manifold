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
import os

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

    /// Latest snapshot captured at the start of `handle(_:)`. Read by
    /// the fire paths to populate the optional time-remaining
    /// caption ("1h 23m until full" / "4h 5m until empty"). Reset on
    /// every tick so the value is always live.
    private var currentInfo: BatteryInfo?

    /// Pending plug / unplug fire. Delayed so the firmware (IOPS API)
    /// has a moment to publish a fresh time-until-full or
    /// time-until-empty estimate — those values are nil for ~1s
    /// after a power-source change while the rolling average
    /// settles. Cancelled if a counter-event arrives within the
    /// delay window (rapid plug/unplug toggle).
    private var pendingPowerSourceTask: Task<Void, Never>?

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

        // Stash the live snapshot so the fire paths can read time-
        // remaining off it for the optional caption line.
        currentInfo = info

        let prevPercent = state.lastPercent
        let currentPercent = info.chargePercent
        let prevExternal = state.lastIsExternalConnected
        let currentExternal = info.isExternalConnected

        // First observation gets a one-line log so a Console.app /
        // `log show` reader can confirm the engine started ticking
        // and what initial state it locked in. Subsequent ticks stay
        // silent unless an alert actually fires (avoids spam at the
        // 50ms cadence).
        if prevExternal == nil {
            Log.app.info(
                "BatteryAlertEngine first tick — percent \(currentPercent, privacy: .public)%, external=\(currentExternal, privacy: .public), state=\(String(describing: info.chargeState), privacy: .public)"
            )
        }

        // ---- 1. Plug / unplug -------------------------------------
        // First observation: do not fire (`prevExternal == nil`).
        // Subsequent edges schedule the fire after waiting for the
        // firmware to publish a time-remaining estimate — adaptive,
        // not a fixed delay: minimum 300ms so it doesn't feel
        // instantaneous, then poll until time-remaining is available
        // for the matching direction, capped at 1.5s. A counter-
        // event within the window cancels the pending fire.
        if let prevExternal {
            if !prevExternal && currentExternal {
                Log.app.info("BatteryAlertEngine — plug edge, scheduling pluggedIn alert")
                schedulePowerSourceAlert(waitFor: .untilFull) { [weak self] in
                    self?.firePluggedIn()
                }
            } else if prevExternal && !currentExternal {
                Log.app.info("BatteryAlertEngine — unplug edge, scheduling unplugged alert")
                schedulePowerSourceAlert(waitFor: .untilEmpty) { [weak self] in
                    self?.fireUnplugged()
                }
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
            ),
            percent: percent
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
            ),
            percent: percent
        )
        presenter(content, BatteryAlertEngineConstants.thresholdAlertDuration)
        if row.playsSound, preferences.batteryAlertsSoundEnabled {
            player(.charged)
        }
    }

    /// Direction the schedule loop watches for in the IOPS-derived
    /// time-remaining fields. `untilFull` for plug-in (we want a
    /// time-until-full estimate), `untilEmpty` for unplug.
    private enum WaitTarget {
        case untilFull
        case untilEmpty
    }

    /// Schedule a power-source alert (plug or unplug) with adaptive
    /// timing. Polls until the firmware publishes a time-remaining
    /// estimate for the requested direction (so the alert's caption
    /// is populated when it appears), capped at a maximum so we
    /// still fire even if the estimate never comes.
    ///
    /// No minimum delay — the polling cadence + organic firmware
    /// settle time produce ~150–700 ms in the typical case, which
    /// is plenty of perceptible beat without a hardcoded floor.
    ///
    /// Cancels any previously-pending power-source alert — only the
    /// LATEST power-source event fires when the user rapidly toggles.
    private func schedulePowerSourceAlert(
        waitFor target: WaitTarget,
        fire: @escaping @MainActor () -> Void
    ) {
        pendingPowerSourceTask?.cancel()
        pendingPowerSourceTask = Task { @MainActor [weak self] in
            let pollMs = BatteryAlertEngineConstants.powerSourcePollMs
            let maxMs = BatteryAlertEngineConstants.powerSourceMaxDelayMs
            let polls = max(0, maxMs / pollMs)
            for _ in 0..<polls {
                guard let self else { return }
                if Task.isCancelled { return }
                if self.timeRemainingReady(for: target) { break }
                try? await Task.sleep(for: .milliseconds(pollMs))
            }
            guard !Task.isCancelled else { return }
            fire()
        }
    }

    /// `true` when `currentInfo` has a non-nil time-remaining value
    /// for the requested direction. Drives the schedule loop's
    /// early-exit check.
    private func timeRemainingReady(for target: WaitTarget) -> Bool {
        guard let info = currentInfo else { return false }
        switch target {
        case .untilFull:  return info.timeUntilFullMinutes != nil
        case .untilEmpty: return info.timeUntilEmptyMinutes != nil
        }
    }

    private func firePluggedIn() {
        guard preferences.pluggedInEnabled else {
            Log.app.info("BatteryAlertEngine — pluggedIn suppressed (preference disabled)")
            return
        }
        let subtitle: LocalizedStringKey = adapterDescription()
            .map { LocalizedStringKey($0) }
            ?? "notch.battery.alert.pluggedIn.subtitle"
        let content = BatteryNotchContent(
            kind: .pluggedIn,
            title: "notch.battery.alert.pluggedIn.title",
            subtitle: subtitle,
            timeRemaining: timeUntilFullCaption(),
            percent: currentInfo?.chargePercent
        )
        presenter(content, BatteryAlertEngineConstants.powerSourceAlertDuration)
        if preferences.pluggedInPlaysSound, preferences.batteryAlertsSoundEnabled {
            player(.pluggedIn)
        }
    }

    private func fireUnplugged() {
        guard preferences.unpluggedEnabled else {
            Log.app.info("BatteryAlertEngine — unplugged suppressed (preference disabled)")
            return
        }
        let content = BatteryNotchContent(
            kind: .unplugged,
            title: "notch.battery.alert.unplugged.title",
            subtitle: "notch.battery.alert.unplugged.subtitle",
            timeRemaining: timeUntilEmptyCaption(),
            percent: currentInfo?.chargePercent
        )
        presenter(content, BatteryAlertEngineConstants.powerSourceAlertDuration)
        if preferences.unpluggedPlaysSound, preferences.batteryAlertsSoundEnabled {
            player(.unplugged)
        }
    }

    // MARK: - Time-remaining captions

    /// "1h 23m until full" — for plug-in alerts. Returns nil when
    /// the battery is already fully charged or the firmware has not
    /// yet produced a time estimate (typical for the first second
    /// after plug-in).
    private func timeUntilFullCaption() -> String? {
        guard let info = currentInfo,
              let minutes = info.timeUntilFullMinutes,
              minutes > 0,
              !info.isFullyCharged
        else { return nil }
        guard let duration = Self.shortDurationFormatter.string(from: TimeInterval(minutes * 60)) else {
            return nil
        }
        return String.localizedStringWithFormat(
            NSLocalizedString(
                "notch.battery.alert.timeRemaining.untilFull",
                comment: "Plug-in alert caption. %1$@ = duration like '1h 23m'."
            ),
            duration
        )
    }

    /// "4h 5m until empty" — for unplug alerts. Returns nil when the
    /// firmware has not yet estimated a discharge rate (typical right
    /// after unplug while the rolling average settles).
    private func timeUntilEmptyCaption() -> String? {
        guard let info = currentInfo,
              let minutes = info.timeUntilEmptyMinutes,
              minutes > 0
        else { return nil }
        guard let duration = Self.shortDurationFormatter.string(from: TimeInterval(minutes * 60)) else {
            return nil
        }
        return String.localizedStringWithFormat(
            NSLocalizedString(
                "notch.battery.alert.timeRemaining.untilEmpty",
                comment: "Unplug alert caption. %1$@ = duration like '4h 5m'."
            ),
            duration
        )
    }

    /// Compact "1h 23m" formatter shared by both captions. Static
    /// because `DateComponentsFormatter` is non-Sendable but is fine
    /// to share on the main actor where the engine runs.
    private static let shortDurationFormatter: DateComponentsFormatter = {
        let f = DateComponentsFormatter()
        f.allowedUnits = [.hour, .minute]
        f.unitsStyle = .abbreviated
        return f
    }()
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

    /// Hard cap on the schedule loop. After this much time we fire
    /// whether or not the firmware has published a time-remaining
    /// estimate (the caption is then nil — better than no
    /// notification at all). 1.5s is comfortably past the typical
    /// IOPS settle time.
    static let powerSourceMaxDelayMs: Int = 1500

    /// Poll interval for the time-remaining-available check. Small
    /// enough that we fire within ~one poll of the firmware
    /// publishing. Also the minimum effective delay before any fire
    /// — we sleep for one tick before the first re-check.
    static let powerSourcePollMs: Int = 100
}

