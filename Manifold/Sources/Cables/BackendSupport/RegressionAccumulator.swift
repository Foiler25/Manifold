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
// Portions of this file derive from WhatCable
// (https://github.com/darrylmorley/whatcable) by Darryl Morley,
// originally distributed under the MIT licence. See
// `Manifold/Sources/Cables/ATTRIBUTION.md` for the full original
// copyright + permission notice.
//
// ─────────────────────────────────────────────────────────────────────
public import Foundation

/// Accumulates (voltage-drop, current) sample pairs for cable resistance
/// regression, with per-cable reset and transient rejection.
///
/// This is a pure value type (no IOKit, no @MainActor) so it is
/// unit-testable with synthetic sample sequences.
///
/// ## Per-cable reset
/// On each call to `append(portSamples:)` we pick the "primary" port (highest
/// negotiated current) and form a ContractFingerprint from its
/// configuredVoltage + configuredCurrent. When the fingerprint changes, we
/// clear the sample buffer and start a settle countdown. This fires on cable
/// swap, charger swap, or any PD renegotiation.
///
/// ## Transient rejection
/// The first `settleSkipCount` ticks after a contract change are discarded.
/// At a 1s poll rate this gives a ~5s settle window, covering the PD
/// renegotiation handshake (typically 3-5s). The countdown ticks on every
/// call regardless of whether a usable sample is found, so the window is
/// wall-clock based rather than sample-count based.
struct RegressionAccumulator {

    // MARK: - Types

    struct Sample {
        let voltageDrop: Double
        let current: Double
    }

    /// The (configuredVoltage, configuredCurrent) pair of the active charger
    /// contract. Changes on cable swap or PD renegotiation.
    struct ContractFingerprint: Equatable {
        let configuredVoltage: Int
        let configuredCurrent: Int
    }

    // MARK: - Configuration

    /// Number of ticks to discard after a contract change.
    let settleSkipCount: Int

    /// Maximum sample buffer size. Oldest entries are dropped when exceeded.
    let maxSamples: Int

    // MARK: - State

    private(set) var samples: [Sample] = []
    private(set) var lastFingerprint: ContractFingerprint?
    private(set) var settleCountdown: Int = 0

    // MARK: - Lifecycle

    init(settleSkipCount: Int = 5, maxSamples: Int = 120) {
        self.settleSkipCount = settleSkipCount
        self.maxSamples = maxSamples
    }

    mutating func reset() {
        samples.removeAll()
        lastFingerprint = nil
        settleCountdown = 0
    }

    // MARK: - Core logic

    /// Process one tick of port samples.
    ///
    /// Returns `true` when at least one new sample was accepted (useful for
    /// testing). Returns `false` when in the settle window or no usable
    /// sample was found.
    @discardableResult
    mutating func append(portSamples: [PortPowerSample]) -> Bool {
        // Pick the primary port: highest negotiated current among ports that
        // have a live contract (configuredVoltage > 0, configuredCurrent > 0).
        guard let primary = portSamples
            .filter({ $0.configuredVoltage > 0 && $0.configuredCurrent > 0 })
            .max(by: { $0.configuredCurrent < $1.configuredCurrent }) else {
            // No metered contract visible. Tick down any outstanding settle
            // window so we don't freeze indefinitely, but accept no samples.
            if settleCountdown > 0 { settleCountdown -= 1 }
            return false
        }

        let fingerprint = ContractFingerprint(
            configuredVoltage: primary.configuredVoltage,
            configuredCurrent: primary.configuredCurrent
        )

        // Detect a contract change (or first-ever call where lastFingerprint
        // is nil). Clear stale samples and start the settle window.
        if fingerprint != lastFingerprint {
            samples.removeAll()
            lastFingerprint = fingerprint
            settleCountdown = settleSkipCount
        }

        // Settle window: discard this tick's samples.
        if settleCountdown > 0 {
            settleCountdown -= 1
            return false
        }

        let usable = portSamples.compactMap { sample -> Sample? in
            guard sample.current > 0,
                  sample.configuredVoltage > 0,
                  sample.adapterVoltage > 0,
                  sample.configuredVoltage >= sample.adapterVoltage else {
                return nil
            }
            return Sample(
                voltageDrop: Double(sample.configuredVoltage - sample.adapterVoltage),
                current: Double(sample.current)
            )
        }

        guard !usable.isEmpty else { return false }

        samples.append(contentsOf: usable)
        if samples.count > maxSamples {
            samples.removeFirst(samples.count - maxSamples)
        }
        return true
    }
}
