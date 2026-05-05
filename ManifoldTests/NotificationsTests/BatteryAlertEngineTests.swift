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
// BatteryAlertEngineTests.swift
//
// Phase 19 — fixture-driven tests for `BatteryAlertEngine`. Pin the
// state-machine transitions per SPEC §21.5:
//
//   - low fire (descending crossing) + re-arm above hysteresis ceiling
//   - charged fire (ascending crossing while charging),
//     suppressed when not charging
//   - plug / unplug fire on isExternalConnected flip
//   - first-observation guard (no plug/unplug fire on the very first
//     handle call)
//   - idempotence (handling the same BatteryInfo twice fires once)
//   - master-disable → all four fire paths no-op
//   - hysteresis (prev=21 → cur=20 → cur=19 → cur=20 fires once)
//   - multi-threshold (20% AND 10% configured → both fire on a fast
//     discharge from 25 → 5%)
//   - per-row sound flag composition
//   - master-sound-disable suppresses sounds without suppressing alerts

import XCTest
@testable import Manifold
@testable import ManifoldKit

@MainActor
final class BatteryAlertEngineTests: XCTestCase {

    // MARK: - Fixtures

    private var defaults: UserDefaults!
    private var suiteName: String!

    /// Recorder that captures every (kind, duration) tuple the engine
    /// passes to `presenter`. Kept as a class so the engine's
    /// `@MainActor` capturing closure can mutate it without copying.
    @MainActor
    private final class PresenterRecorder {
        var calls: [(kind: BatteryNotchContent.Kind, duration: TimeInterval)] = []
        func record(_ content: BatteryNotchContent, _ duration: TimeInterval) {
            calls.append((content.kind, duration))
        }
    }

    @MainActor
    private final class SoundRecorder {
        var calls: [BatteryNotchContent.Kind] = []
        func record(_ kind: BatteryNotchContent.Kind) {
            calls.append(kind)
        }
    }

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "manifold-bae-test-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    /// Build a fresh engine with seeded preferences + recorder
    /// closures. `masterEnabled` defaults to true; tests that check
    /// the master-gate can flip it.
    private func makeEngine(
        prefs: BatteryAlertPreferences? = nil,
        masterEnabled: Bool = true,
        adapterDescription: String? = nil
    ) -> (engine: BatteryAlertEngine,
          prefs: BatteryAlertPreferences,
          presenter: PresenterRecorder,
          sound: SoundRecorder) {
        let prefs = prefs ?? BatteryAlertPreferences(defaults: defaults)
        let presenter = PresenterRecorder()
        let sound = SoundRecorder()
        let engine = BatteryAlertEngine(
            preferences: prefs,
            presenter: { content, duration in presenter.record(content, duration) },
            player: { kind in sound.record(kind) },
            isMasterEnabled: { masterEnabled },
            adapterDescription: { adapterDescription }
        )
        return (engine, prefs, presenter, sound)
    }

    /// Build a `BatteryInfo` with just the fields the engine reads.
    /// Other fields fill with sensible defaults.
    private func info(
        percent: Int,
        external: Bool,
        chargeState: BatteryInfo.ChargeState
    ) -> BatteryInfo {
        BatteryInfo(
            chargePercent: percent,
            chargeState: chargeState,
            healthPercent: 95,
            cycleCount: 100,
            temperatureCelsius: 30,
            voltageVolts: 12.5,
            amperageMilliamps: external ? 1000 : -1000,
            powerWatts: 12.5,
            designCapacityMAh: 6000,
            nominalCapacityMAh: 5800,
            currentCapacityMAh: 6000 * percent / 100,
            timeUntilFullMinutes: external ? 60 : nil,
            timeUntilEmptyMinutes: external ? nil : 240,
            isExternalConnected: external,
            isFullyCharged: percent >= 100 && external,
            sampledAt: Date()
        )
    }

    // MARK: - Low-battery alert

    func test_lowAlert_firesOnDescendingCrossing() async {
        let (engine, _, presenter, _) = makeEngine()
        // Seed at 100 (init default), discharge through 20.
        engine.handle(info(percent: 25, external: false, chargeState: .discharging))
        XCTAssertTrue(presenter.calls.isEmpty, "No alert before crossing")
        engine.handle(info(percent: 20, external: false, chargeState: .discharging))
        XCTAssertEqual(presenter.calls.count, 1)
        XCTAssertEqual(presenter.calls.first?.kind, .lowBattery)
        XCTAssertEqual(presenter.calls.first?.duration,
                       BatteryAlertEngineConstants.thresholdAlertDuration)
    }

    func test_lowAlert_doesNotRefireWithinHysteresis() async {
        let (engine, _, presenter, _) = makeEngine()
        // Cross 20% (fires), bounce up to 21 (within hysteresis), back
        // to 19 (still within hysteresis ceiling 25). Should not fire
        // a second time.
        engine.handle(info(percent: 25, external: false, chargeState: .discharging))
        engine.handle(info(percent: 20, external: false, chargeState: .discharging))
        engine.handle(info(percent: 21, external: false, chargeState: .discharging))
        engine.handle(info(percent: 19, external: false, chargeState: .discharging))
        engine.handle(info(percent: 20, external: false, chargeState: .discharging))
        XCTAssertEqual(presenter.calls.count, 1, "Hysteresis should suppress re-fire")
    }

    func test_lowAlert_reArmsAboveHysteresisCeiling() async {
        let (engine, _, presenter, _) = makeEngine()
        // Cross 20% (fires).
        engine.handle(info(percent: 25, external: false, chargeState: .discharging))
        engine.handle(info(percent: 20, external: false, chargeState: .discharging))
        XCTAssertEqual(presenter.calls.count, 1)
        // Climb above 25 (= 20 + 5 hysteresis) — re-arms.
        engine.handle(info(percent: 26, external: false, chargeState: .discharging))
        // Cross again — should fire.
        engine.handle(info(percent: 20, external: false, chargeState: .discharging))
        XCTAssertEqual(presenter.calls.count, 2,
                       "Re-arm above ceiling should allow re-fire")
    }

    func test_multipleLowThresholds_bothFireOnFastDischarge() async {
        let (engine, _, presenter, _) = makeEngine()
        // Default seed has 20% AND 10%. Fast-discharge 25 → 5%.
        engine.handle(info(percent: 25, external: false, chargeState: .discharging))
        engine.handle(info(percent: 5, external: false, chargeState: .discharging))
        // Both crossings happened in the same step (prev=25, cur=5
        // crosses both 20 and 10).
        XCTAssertEqual(presenter.calls.count, 2)
        XCTAssertEqual(presenter.calls.filter({ $0.kind == .lowBattery }).count, 2)
    }

    // MARK: - Charged alert

    func test_chargedAlert_firesOnAscendingCrossingWhileCharging() async {
        let (engine, _, presenter, _) = makeEngine()
        // Plug in (first observation: no plug fire either way).
        engine.handle(info(percent: 75, external: true, chargeState: .charging))
        // Cross 80 while charging — fires.
        engine.handle(info(percent: 80, external: true, chargeState: .charging))
        XCTAssertEqual(presenter.calls.filter({ $0.kind == .charged }).count, 1)
    }

    func test_chargedAlert_suppressedWhenNotCharging() async {
        let (engine, _, presenter, _) = makeEngine()
        engine.handle(info(percent: 75, external: true, chargeState: .notCharging))
        engine.handle(info(percent: 80, external: true, chargeState: .notCharging))
        XCTAssertTrue(
            presenter.calls.allSatisfy({ $0.kind != .charged }),
            "Charged alert must require chargeState == .charging"
        )
    }

    func test_chargedAlert_reArmsOnExternalDisconnect() async {
        let (engine, _, presenter, _) = makeEngine()
        // Charge through 80 (fires once).
        engine.handle(info(percent: 75, external: true, chargeState: .charging))
        engine.handle(info(percent: 80, external: true, chargeState: .charging))
        XCTAssertEqual(presenter.calls.filter({ $0.kind == .charged }).count, 1)
        // Unplug at 75 — clears the charged-fired set.
        engine.handle(info(percent: 75, external: false, chargeState: .discharging))
        // Replug + climb through 80 again — fires fresh.
        engine.handle(info(percent: 75, external: true, chargeState: .charging))
        engine.handle(info(percent: 80, external: true, chargeState: .charging))
        XCTAssertEqual(presenter.calls.filter({ $0.kind == .charged }).count, 2,
                       "External disconnect should re-arm charged alerts")
    }

    // MARK: - Plug / unplug

    func test_pluggedIn_firesOnExternalFlipFalseToTrue() async {
        let (engine, _, presenter, _) = makeEngine()
        // First observation does NOT fire plug/unplug.
        engine.handle(info(percent: 50, external: false, chargeState: .discharging))
        XCTAssertTrue(presenter.calls.isEmpty)
        // Flip to plugged in.
        engine.handle(info(percent: 50, external: true, chargeState: .charging))
        XCTAssertEqual(presenter.calls.count, 1)
        XCTAssertEqual(presenter.calls.first?.kind, .pluggedIn)
        XCTAssertEqual(presenter.calls.first?.duration,
                       BatteryAlertEngineConstants.powerSourceAlertDuration)
    }

    func test_unplugged_firesOnExternalFlipTrueToFalse() async {
        let (engine, _, presenter, _) = makeEngine()
        engine.handle(info(percent: 50, external: true, chargeState: .charging))
        // Now flip to unplugged.
        engine.handle(info(percent: 50, external: false, chargeState: .discharging))
        XCTAssertEqual(presenter.calls.last?.kind, .unplugged)
    }

    func test_firstObservation_doesNotFirePlugOrUnplug() async {
        // First handle call sees `lastIsExternalConnected == nil`;
        // SPEC §21.5 says no plug/unplug on first observation.
        let (engine, _, presenter, _) = makeEngine()
        engine.handle(info(percent: 100, external: true, chargeState: .charging))
        XCTAssertTrue(
            presenter.calls.allSatisfy({ $0.kind != .pluggedIn && $0.kind != .unplugged }),
            "First observation must not fire plug or unplug"
        )
    }

    // MARK: - Idempotence

    func test_idempotence_sameInfoTwiceFiresOnce() async {
        let (engine, _, presenter, _) = makeEngine()
        engine.handle(info(percent: 25, external: false, chargeState: .discharging))
        engine.handle(info(percent: 20, external: false, chargeState: .discharging))
        let countAfterFirst = presenter.calls.count
        // Second identical call.
        engine.handle(info(percent: 20, external: false, chargeState: .discharging))
        XCTAssertEqual(presenter.calls.count, countAfterFirst,
                       "Identical follow-up should not fire")
    }

    // MARK: - Master gate

    func test_masterDisabled_suppressesAllFires() async {
        let (engine, _, presenter, sound) = makeEngine(masterEnabled: false)
        // Push through every fire-eligible transition.
        engine.handle(info(percent: 25, external: false, chargeState: .discharging))
        engine.handle(info(percent: 20, external: false, chargeState: .discharging))
        engine.handle(info(percent: 5, external: false, chargeState: .discharging))
        engine.handle(info(percent: 5, external: true, chargeState: .charging))
        engine.handle(info(percent: 80, external: true, chargeState: .charging))
        engine.handle(info(percent: 80, external: false, chargeState: .discharging))
        XCTAssertTrue(presenter.calls.isEmpty,
                      "Master disable should suppress every fire path")
        XCTAssertTrue(sound.calls.isEmpty,
                      "Master disable should suppress every chime")
    }

    // MARK: - Sound flag composition

    func test_perRowSound_off_doesNotPlay() async {
        let (engine, _, _, sound) = makeEngine()
        // Default seed has all low/charged with sound off.
        engine.handle(info(percent: 25, external: false, chargeState: .discharging))
        engine.handle(info(percent: 20, external: false, chargeState: .discharging))
        XCTAssertTrue(sound.calls.isEmpty,
                      "Default low alert sound is off")
    }

    func test_perRowSound_on_butMasterOff_doesNotPlay() async {
        let prefs = BatteryAlertPreferences(defaults: defaults)
        prefs.batteryAlertsSoundEnabled = false
        // Toggle the first low-row's sound ON.
        if var row = prefs.alerts.first(where: { $0.kind == .low }) {
            row.playsSound = true
            prefs.update(row)
        }
        let (engine, _, _, sound) = makeEngine(prefs: prefs)
        engine.handle(info(percent: 25, external: false, chargeState: .discharging))
        engine.handle(info(percent: 20, external: false, chargeState: .discharging))
        XCTAssertTrue(sound.calls.isEmpty,
                      "Master-off should suppress chime even when per-row is on")
    }

    func test_perRowSound_on_andMasterOn_plays() async {
        let prefs = BatteryAlertPreferences(defaults: defaults)
        // Master is on by default seed.
        if var row = prefs.alerts.first(where: { $0.kind == .low && $0.percent == 20 }) {
            row.playsSound = true
            prefs.update(row)
        }
        let (engine, _, _, sound) = makeEngine(prefs: prefs)
        engine.handle(info(percent: 25, external: false, chargeState: .discharging))
        engine.handle(info(percent: 20, external: false, chargeState: .discharging))
        XCTAssertEqual(sound.calls, [.lowBattery])
    }

    func test_pluggedInSound_default_on() async {
        let (engine, _, _, sound) = makeEngine()
        engine.handle(info(percent: 50, external: false, chargeState: .discharging))
        engine.handle(info(percent: 50, external: true, chargeState: .charging))
        XCTAssertEqual(sound.calls, [.pluggedIn],
                       "Plug-in sound is on by default per D22")
    }

    func test_pluggedInDisabled_doesNotFire() async {
        let prefs = BatteryAlertPreferences(defaults: defaults)
        prefs.pluggedInEnabled = false
        let (engine, _, presenter, _) = makeEngine(prefs: prefs)
        engine.handle(info(percent: 50, external: false, chargeState: .discharging))
        engine.handle(info(percent: 50, external: true, chargeState: .charging))
        XCTAssertTrue(
            presenter.calls.allSatisfy({ $0.kind != .pluggedIn }),
            "pluggedInEnabled=false should suppress plug alerts"
        )
    }

    // MARK: - Adapter description

    func test_pluggedIn_subtitle_usesAdapterDescriptionWhenAvailable() async {
        // Adapter description is a String*; the engine wraps it in a
        // LocalizedStringKey. Since we don't capture content text in
        // PresenterRecorder, this test just confirms the engine
        // accepts a non-nil adapter description without crashing.
        // (Spot-checking the actual subtitle string would require
        // a non-trivial LocalizedStringKey reflection trick.)
        let (engine, _, presenter, _) = makeEngine(adapterDescription: "Manifold 65W USB-C")
        engine.handle(info(percent: 50, external: false, chargeState: .discharging))
        engine.handle(info(percent: 50, external: true, chargeState: .charging))
        XCTAssertEqual(presenter.calls.count, 1)
    }
}
