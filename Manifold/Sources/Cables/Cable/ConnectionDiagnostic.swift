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

/// A snapshot of one port's lifetime fault counters at a single instant. The
/// port controller keeps these counts for the whole life of the port, so the
/// absolute values mean nothing to a user (a port that has had cables plugged
/// into it for a year shows large numbers that are not a fault). The signal is
/// how far they climb during one continuous connection.
public struct ConnectionCounters: Equatable, Sendable {
    /// Times the port logged a plug event. A clean connection holds this
    /// steady; a count that climbs while the cable stays put is a
    /// hardware-logged drop the user did not cause.
    public let plugEvents: Int?
    /// Times the port tripped overcurrent protection.
    public let overcurrents: Int?

    public init(plugEvents: Int?, overcurrents: Int?) {
        self.plugEvents = plugEvents
        self.overcurrents = overcurrents
    }

    public init(port: AppleHPMInterface) {
        self.init(
            plugEvents: port.plugEventCount,
            overcurrents: port.overcurrentCount
        )
    }
}

/// How far each fault counter has climbed since a connection began. A reset of
/// the underlying controller can make a counter go backwards; those negative
/// deltas are clamped to zero so a controller reset never reads as a fault.
public struct SessionDelta: Equatable, Sendable {
    public let plugEvents: Int
    public let overcurrents: Int

    /// The delta between the baseline captured when the connection began and
    /// the current reading.
    public init(baseline: ConnectionCounters, current: ConnectionCounters) {
        self.plugEvents = Self.rise(baseline.plugEvents, current.plugEvents)
        self.overcurrents = Self.rise(baseline.overcurrents, current.overcurrents)
    }

    /// Direct init for callers/tests that already hold the deltas.
    public init(plugEvents: Int, overcurrents: Int) {
        self.plugEvents = plugEvents
        self.overcurrents = overcurrents
    }

    /// The rise in a counter from baseline to now.
    ///
    /// A `nil` baseline means we never had a reading to anchor this
    /// connection to, so we report zero rather than a delta. This is
    /// deliberate and conservative: these are *lifetime* counts, so a counter
    /// that reads `nil` at connect and a value later could be carrying history
    /// from a previous cable on this port. Manufacturing a fault from an
    /// unparented count would falsely accuse an innocent cable, which is worse
    /// than missing one edge case. The live `SessionMonitor` engine anchors
    /// overcurrent the same way (first non-nil reading is the baseline, never
    /// an event). Counters also only ever climb, so a smaller "current" means
    /// the controller reset underneath us; that is clamped to zero too.
    private static func rise(_ base: Int?, _ now: Int?) -> Int {
        guard let base, let now else { return 0 }
        return max(0, now - base)
    }

    public var isClean: Bool {
        plugEvents == 0 && overcurrents == 0
    }
}

/// Turns a connection's in-session counter deltas into a plain-English fault
/// banner. The empirical sibling of `ChargingDiagnostic` / `DataLinkDiagnostic`:
/// where those judge a single snapshot ("is the cable the bottleneck right
/// now?"), this judges change over the life of one connection ("has this
/// connection misbehaved since you plugged it in?"). Same shape on purpose: a
/// failable init that returns `nil` when there is nothing to report, a `Fault`
/// enum carrying the numbers, and plain-English `summary` / `detail`.
///
/// Pure (no clock, no IOKit): the caller owns the per-port baseline and the
/// clock and passes in the resolved delta plus how long the connection has been
/// up. Living in `WhatCableCore` means any surface (the menu bar `PortCard`
/// today, a future live CLI view) generates identical copy.
///
/// Phase 1 wording is intentionally English-literal, matching how
/// `DataLinkDiagnostic` shipped: the strings move to `String(localized:)`
/// against `_coreLocalizedBundle` once the verdict wording is approved on a
/// live build.
public struct ConnectionDiagnostic: Equatable {
    public enum Fault: Equatable {
        /// The port tripped overcurrent protection during this connection.
        /// One is conclusive: a hard hardware fault, the most serious tier.
        case overcurrent(count: Int)
        /// The connection logged repeated plug events while the cable stayed
        /// put: hardware-logged drops the user did not cause.
        case repeatedDrops(count: Int)
    }

    /// Visual severity, mapped to a callout colour by the UI. Kept here (not as
    /// a UI type) so the CLI and app agree on which faults are the loud ones.
    /// `warning` is the orange "act now" tier; `caution` is the amber "worth a
    /// look" tier.
    public enum Severity: Equatable {
        case warning
        case caution
    }

    /// A plug-event count at or above this during one connection is reportable
    /// instability. Spec threshold: 2+.
    public static let dropThreshold = 2

    public let fault: Fault
    public let severity: Severity
    public let summary: String
    public let detail: String

    /// Returns `nil` when the session is clean. Overcurrent outranks drops: a
    /// hardware protection trip is the more serious signal, so when both fire
    /// the overcurrent banner is the one shown.
    ///
    /// - Parameters:
    ///   - delta: the rise in each counter since the connection began.
    ///   - elapsedSeconds: how long the connection has been up, for the "in the
    ///     last X minutes" window on the drops banner.
    public init?(delta: SessionDelta, elapsedSeconds: TimeInterval) {
        if delta.overcurrents >= 1 {
            self.fault = .overcurrent(count: delta.overcurrents)
            self.severity = .warning
            self.summary = "Cable triggered overcurrent protection"
            self.detail = "The port cut power to protect itself during this connection. Disconnect the cable and inspect both the cable and the port for damage or debris before reusing them."
        } else if delta.plugEvents >= Self.dropThreshold {
            self.fault = .repeatedDrops(count: delta.plugEvents)
            self.severity = .caution
            let window = Self.window(elapsedSeconds)
            self.summary = "Connection dropped \(delta.plugEvents) times"
            self.detail = "This connection dropped \(delta.plugEvents) times \(window), without you touching the cable. That usually means a damaged plug, debris in the port, or a marginal cable. Try reseating it, or a different port or cable."
        } else {
            // Clean session, or a single plug event (below the 2+ bar, which
            // is just as likely a normal reconnect). Nothing to surface.
            return nil
        }
    }

    /// "in the last minute" / "in the last N minutes" for the elapsed window.
    /// At least one minute so a fresh session never reads "0 minutes".
    static func window(_ elapsedSeconds: TimeInterval) -> String {
        let minutes = max(1, Int((elapsedSeconds / 60).rounded()))
        if minutes == 1 {
            return "in the last minute"
        }
        return "in the last \(minutes) minutes"
    }
}
