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
// BatteryAlertPreferences.swift
//
// Phase 19 — `@Observable` source of truth for the per-row threshold
// list + the four power-source flags + the master sound toggle. Owns
// the JSON encode/decode for `[BatteryAlertConfig]` (which `@AppStorage`
// can't bind directly) and the first-read seed per SPEC §21.7 / §21.10.
//
// Two consumers share one instance:
//   1. `MenuBarPane` (the SwiftUI Settings UI) reads + writes via
//      `@Bindable preferences`.
//   2. `BatteryAlertEngine` reads on every `handle(_:)` call to look
//      up the configured rows, sound flags, etc.
//
// AppDelegate constructs the single shared instance only when the
// Phase 18 `batteryHardwarePresent` probe returns true (per SPEC §21.11
// — desktop Macs never get an instance, so the engine + notch panel
// are never instantiated either).
//
// Persistence shape:
//   - `[BatteryAlertConfig]` → JSON-encoded String → UserDefaults under
//     `SettingsKeys.batteryAlertConfigs`. Encoded once on every
//     mutation (same `JSONEncoder` instance, deterministic output).
//   - Power-source + master sound flags → individual `Bool`
//     UserDefaults entries.
//
// First-read seed (SPEC §21.7): if the configs key is **absent** at
// init time (fresh install OR upgrade from pre-Phase-19), a 3-row
// seed is written to UserDefaults so the next observation sees it.
// Empty array (user manually deleted everything) is a respected user
// state and is NOT re-seeded — that's the Architect's deviation #3.

import Foundation
import Observation

@MainActor
@Observable
final class BatteryAlertPreferences {

    // MARK: - Persisted state

    /// User-managed list of low + charged threshold rows. Mutating
    /// this property triggers a JSON encode + write to UserDefaults
    /// via the property's `didSet`. The initial value is seeded on
    /// first read per SPEC §21.7.
    var alerts: [BatteryAlertConfig] {
        didSet { writeAlerts() }
    }

    /// Plug-in main toggle. Default `true`.
    var pluggedInEnabled: Bool {
        didSet { write(pluggedInEnabled, forKey: SettingsKeys.pluggedInAlertEnabled) }
    }

    /// Plug-in per-row sound flag. Default `true` — audio confirms
    /// a physical action the user just took (D22).
    var pluggedInPlaysSound: Bool {
        didSet { write(pluggedInPlaysSound, forKey: SettingsKeys.pluggedInAlertPlaysSound) }
    }

    /// Unplug main toggle. Default `true`.
    var unpluggedEnabled: Bool {
        didSet { write(unpluggedEnabled, forKey: SettingsKeys.unpluggedAlertEnabled) }
    }

    /// Unplug per-row sound flag. Default `true` (D22 — same
    /// reasoning as plug-in).
    var unpluggedPlaysSound: Bool {
        didSet { write(unpluggedPlaysSound, forKey: SettingsKeys.unpluggedAlertPlaysSound) }
    }

    /// Master sound mute. AND-composed with each per-row sound flag
    /// before any `BatteryAlertSound.play*()` call.
    var batteryAlertsSoundEnabled: Bool {
        didSet { write(batteryAlertsSoundEnabled, forKey: SettingsKeys.batteryAlertsSoundEnabled) }
    }

    // MARK: - Backing store

    /// Injectable for tests. Production wires `.standard`.
    private let defaults: UserDefaults

    /// Single encoder/decoder per instance — they're inexpensive but
    /// re-creating per mutation is a wasted alloc. `JSONEncoder` is
    /// not `Sendable` so they live as instance state on the
    /// `@MainActor` class (no cross-thread escape).
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    // MARK: - Init

    /// First-read seed: if `SettingsKeys.batteryAlertConfigs` is
    /// **absent**, write the 3-row default array (SPEC §21.7 table)
    /// + each absent power-source flag's default before any consumer
    /// reads them. The seed runs exactly once per install.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()

        // Configs — seed only if absent. Empty array (user deleted
        // every row) is a respected user state per SPEC §21.10.
        if let raw = defaults.string(forKey: SettingsKeys.batteryAlertConfigs),
           let data = raw.data(using: .utf8),
           let decoded = try? decoder.decode([BatteryAlertConfig].self, from: data) {
            self.alerts = decoded
        } else {
            self.alerts = BatteryAlertPreferencesSeed.defaultAlerts
            // Persist the seed immediately so the next observation
            // (the MenuBarPane render, the engine's first handle call)
            // sees the seeded state in UserDefaults even before the
            // first user-driven write.
            BatteryAlertPreferences.writeRaw(
                BatteryAlertPreferencesSeed.defaultAlerts,
                using: encoder,
                to: defaults
            )
        }

        // Power-source flags — each seeded independently. `object(forKey:)`
        // returns nil for absent keys (Bool's `bool(forKey:)` collapses
        // absent and false into a single `false`, which we can't tell
        // apart). The didSet observers are not yet wired, so the
        // assignments below DO NOT recurse.
        self.pluggedInEnabled = BatteryAlertPreferences.readOrSeedBool(
            forKey: SettingsKeys.pluggedInAlertEnabled,
            default: SettingsDefaults.pluggedInAlertEnabled,
            in: defaults
        )
        self.pluggedInPlaysSound = BatteryAlertPreferences.readOrSeedBool(
            forKey: SettingsKeys.pluggedInAlertPlaysSound,
            default: SettingsDefaults.pluggedInAlertPlaysSound,
            in: defaults
        )
        self.unpluggedEnabled = BatteryAlertPreferences.readOrSeedBool(
            forKey: SettingsKeys.unpluggedAlertEnabled,
            default: SettingsDefaults.unpluggedAlertEnabled,
            in: defaults
        )
        self.unpluggedPlaysSound = BatteryAlertPreferences.readOrSeedBool(
            forKey: SettingsKeys.unpluggedAlertPlaysSound,
            default: SettingsDefaults.unpluggedAlertPlaysSound,
            in: defaults
        )
        self.batteryAlertsSoundEnabled = BatteryAlertPreferences.readOrSeedBool(
            forKey: SettingsKeys.batteryAlertsSoundEnabled,
            default: SettingsDefaults.batteryAlertsSoundEnabled,
            in: defaults
        )
    }

    // MARK: - Mutators

    /// Append a new config row. The MenuBarPane "Add low alert" /
    /// "Add charged alert" inline editors funnel here. Returns the
    /// stored row (with its server-generated id) so the caller can
    /// flash a selection / focus on the new row if desired.
    @discardableResult
    func add(kind: BatteryAlertConfig.Kind, percent: Int) -> BatteryAlertConfig {
        let row = BatteryAlertConfig(
            kind: kind,
            percent: percent,
            enabled: true,
            playsSound: false
        )
        alerts.append(row)
        return row
    }

    /// Remove a row by id. The MenuBarPane row trash button lives
    /// here. Mutating `alerts` triggers the JSON write via `didSet`.
    func remove(id: UUID) {
        alerts.removeAll(where: { $0.id == id })
    }

    /// Replace a row in place — the inline editor's Save button +
    /// the per-row toggle interactions both flow through this. We
    /// route via `firstIndex` so the array's order doesn't shift on
    /// edit (preserves SwiftUI list animation continuity).
    func update(_ row: BatteryAlertConfig) {
        guard let idx = alerts.firstIndex(where: { $0.id == row.id }) else { return }
        alerts[idx] = row
    }

    // MARK: - Read filters

    /// Configured rows of a specific kind, enabled-only. Used by the
    /// engine on every `handle(_:)` call to evaluate edge crossings —
    /// disabled rows are skipped at the source so the engine doesn't
    /// have to re-check the flag for every threshold.
    func enabledAlerts(of kind: BatteryAlertConfig.Kind) -> [BatteryAlertConfig] {
        alerts.filter { $0.kind == kind && $0.enabled }
    }

    // MARK: - Persistence

    private func writeAlerts() {
        BatteryAlertPreferences.writeRaw(alerts, using: encoder, to: defaults)
    }

    private func write(_ value: Bool, forKey key: String) {
        defaults.set(value, forKey: key)
    }

    private static func writeRaw(
        _ alerts: [BatteryAlertConfig],
        using encoder: JSONEncoder,
        to defaults: UserDefaults
    ) {
        guard
            let data = try? encoder.encode(alerts),
            let raw = String(data: data, encoding: .utf8)
        else { return }
        defaults.set(raw, forKey: SettingsKeys.batteryAlertConfigs)
    }

    /// Read a Bool from defaults, seeding the default value back to
    /// the store if the key is absent. The `object(forKey:)` cast is
    /// the only way to distinguish "absent" from "stored false" for
    /// a Bool — `bool(forKey:)` collapses both to false.
    private static func readOrSeedBool(
        forKey key: String,
        default fallback: Bool,
        in defaults: UserDefaults
    ) -> Bool {
        if let stored = defaults.object(forKey: key) as? Bool {
            return stored
        }
        defaults.set(fallback, forKey: key)
        return fallback
    }
}

// MARK: - Seed

/// First-install seed per SPEC §21.7 table. Single source of truth;
/// the init reads from here, the BatteryAlertEngineTests assert
/// against here, the MenuBarPane preview seeds the same shape.
enum BatteryAlertPreferencesSeed {
    /// 3-row default: low at 20% silent, low at 10% silent, charged
    /// at 80% silent. Plug + unplug live separately as power-source
    /// flag defaults (see `SettingsDefaults`).
    static let defaultAlerts: [BatteryAlertConfig] = [
        BatteryAlertConfig(kind: .low, percent: 20, enabled: true, playsSound: false),
        BatteryAlertConfig(kind: .low, percent: 10, enabled: true, playsSound: false),
        BatteryAlertConfig(kind: .charged, percent: 80, enabled: true, playsSound: false)
    ]
}
