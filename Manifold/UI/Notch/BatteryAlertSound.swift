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
// BatteryAlertSound.swift
//
// Phase 19 — chimes for the four battery-alert event types. Picks are
// **system NSSound names** (no bundled assets per D22 / SPEC §21.8).
// Reviewer enforces the no-bundled-audio invariant via
// `find Manifold/Resources -name "*.caf" -o -name "*.aiff" -o -name
// "*.wav" -o -name "*.mp3"` returning zero hits.
//
// The four picks are deliberately differentiated by length + mood:
//   - Glass     — short, positive, transient (matches a successful
//                 physical action: plug)
//   - Submarine — softer, slightly longer (matches an informational
//                 state change: unplug)
//   - Funk      — most attention-grabbing (matches a warning: low)
//   - Tink      — lightest (matches a quiet milestone: charged)
//
// Per SPEC §21.5 "Sound emission": the engine calls one of these
// methods only when the matched alert config has `playsSound == true`
// AND the master `BatteryAlertPreferences.batteryAlertsSoundEnabled`
// is `true`. Both flags must be true.

import AppKit

/// System-sound chimes for battery alerts. Sound names locked per
/// D22; the user toggles whether each event chimes, not which sound
/// it uses.
enum BatteryAlertSound {

    /// Plug-in chime — `Glass`. Optional chain falls through silently
    /// if the system sound is missing on a future macOS (defensive;
    /// these have shipped since 10.x and we don't expect removal).
    static func playPluggedIn() {
        NSSound(named: NSSound.Name(BatteryAlertSoundConstants.pluggedInName))?.play()
    }

    /// Unplug chime — `Submarine`.
    static func playUnplugged() {
        NSSound(named: NSSound.Name(BatteryAlertSoundConstants.unpluggedName))?.play()
    }

    /// Low-battery chime — `Funk`.
    static func playLowBattery() {
        NSSound(named: NSSound.Name(BatteryAlertSoundConstants.lowBatteryName))?.play()
    }

    /// Charged chime — `Tink`.
    static func playCharged() {
        NSSound(named: NSSound.Name(BatteryAlertSoundConstants.chargedName))?.play()
    }
}

// MARK: - Constants

enum BatteryAlertSoundConstants {
    /// `NSSound(named:)` lookup names. Single source of truth so
    /// the test target can spot-check the picks against D22 without
    /// having to invoke the playback path.
    static let pluggedInName: String = "Glass"
    static let unpluggedName: String = "Submarine"
    static let lowBatteryName: String = "Funk"
    static let chargedName: String = "Tink"
}
