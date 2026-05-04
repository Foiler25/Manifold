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
// PortGraph.swift
//
// `@MainActor @Observable` source of truth for every UI surface
// (popover, window, settings). SPEC.md §4.6 — rev 4 made this
// location permanent (`Manifold/UI/PortGraph.swift`).
//
// Phase 3 implements the full §4.6.1 mutation pattern: a private
// `mutatePort(id:_:)` helper walks the host tree COW-style and
// applies a closure to the matching port. All four surgical /
// surgical-structural cases call through it; `.fullRefresh` and
// `.diagnostic` are top-level rebuild + dedupe respectively.

import Foundation
import ManifoldKit
import os

@MainActor
@Observable
final class PortGraph {

    /// Every host we've discovered. Phase 2/3 always emit exactly one;
    /// the array shape is preserved for future remote-host support.
    private(set) var hosts: [ManifoldKit.Host] = []

    /// Active diagnostics (Phase 8 populates). Phase 3 supports
    /// `.diagnostic` event delivery + dedupe so Phase 8 doesn't have
    /// to relitigate the apply pattern.
    private(set) var diagnostics: [Diagnostic] = []

    /// Per-port telemetry history. Phase 5: keyed by `PortID`,
    /// `TelemetryBuffer` is the fixed-cap-60 ring buffer per SPEC §8.
    /// Phase-3-deferred-to-Phase-5 work landed: `.telemetry` events
    /// now append to the buffer for the matching `PortID`. Lives on
    /// PortGraph (not on `Port`) because `TelemetryBuffer` is a
    /// Manifold-target type, not ManifoldKit — see Phase 5 BUILD_LOG
    /// design note #1.
    private(set) var telemetryHistory: [PortID: TelemetryBuffer] = [:]

    /// Wall-clock time of the last mutation. Bumped on every successful
    /// `replace`/`apply` call — used by the popover's "last updated"
    /// affordance and as a monotonic test signal.
    private(set) var lastUpdated: Date = .now

    /// Pending `.fullRefresh` request flag. Set by `apply(.attached)`
    /// when the target port isn't in the current graph (per §4.6.1).
    /// The consumer (`AppDelegate`) reads this after each `apply` call
    /// and calls `requestRefresh()` on EventService if true; the flag
    /// is cleared by `acknowledgeRefreshRequest()`. Avoids re-entrant
    /// emission from inside `apply`.
    private(set) var needsFullRefresh: Bool = false

    /// Phase 18 / D16: battery snapshot, host-level state. Nil on
    /// hardware with no `AppleSmartBattery` service (desktop Macs) and
    /// before the first `BatterySampler` tick on portable Macs. Source
    /// of truth for `BatteryView` and `BatteryStatusItemController`.
    ///
    /// NOT routed through `PortEvent` / `apply(_:)` per D16 — battery
    /// is host-level, not port-keyed. Mutated only via `applyBattery(_:)`.
    private(set) var battery: BatteryInfo?

    init() {}

    // MARK: - Mutation

    /// Replace the entire graph atomically. Called on initial walk,
    /// on `.fullRefresh` consumer-side rebuilds, and Phase 14 settings
    /// changes that affect discovery filtering. Bumps `lastUpdated`
    /// even when the new content is identical to the old.
    func replace(hosts: [ManifoldKit.Host], diagnostics: [Diagnostic] = []) {
        self.hosts = hosts
        self.diagnostics = diagnostics
        // Prune telemetry history to ports that still exist in the
        // new graph. Avoids unbounded growth across replug churn —
        // a port that's gone for good has no business keeping its
        // sparkline data alive in memory.
        let livePortIDs = Self.allPortIDs(in: hosts)
        self.telemetryHistory = self.telemetryHistory.filter { livePortIDs.contains($0.key) }
        self.lastUpdated = .now
        self.needsFullRefresh = false
    }

    /// Recursively collect every PortID in the host tree. Used by
    /// `replace` to prune telemetry history for vanished ports.
    private static func allPortIDs(in hosts: [ManifoldKit.Host]) -> Set<PortID> {
        var ids: Set<PortID> = []
        func walk(_ ports: [ManifoldKit.Port]) {
            for port in ports {
                ids.insert(port.id)
                walk(port.children)
            }
        }
        for host in hosts { walk(host.ports) }
        return ids
    }

    /// Apply one `PortEvent` per the SPEC §4.6.1 hybrid surgical /
    /// structural strategy. Switch on the event case and dispatch to
    /// the per-case handler; each handler is documented with its
    /// §4.6.1 contract.
    func apply(_ event: PortEvent) {
        switch event {
        case .telemetry(let portID, let sample):
            applyTelemetry(portID: portID, sample: sample)

        case .attached(let device, at: let portID):
            applyAttached(device: device, at: portID)

        case .detached(let deviceID, from: let portID):
            applyDetached(deviceID: deviceID, from: portID)

        case .diagnostic(let diag):
            applyDiagnostic(diag)

        case .fullRefresh:
            // §4.6.1: ".fullRefresh enum case is the *signal* to
            // rebuild; replace(_:diagnostics:) is what actually swaps
            // the graph." The consumer (AppDelegate) does the swap on
            // its own; here we just bump lastUpdated so anything
            // observing "I tried to refresh" sees a tick.
            lastUpdated = .now
        }
    }

    /// Consumer (AppDelegate) calls this after observing
    /// `needsFullRefresh == true` and triggering a re-walk. Resets the
    /// flag so the next `.attached` not-found can set it again.
    func acknowledgeRefreshRequest() {
        needsFullRefresh = false
    }

    /// Phase 18 / D16: direct setter for the battery snapshot. Called
    /// by `BatterySampler`'s `onSample` callback once per tick.
    /// Bypasses `PortEvent`/`apply(_:)` because battery state is
    /// host-level, not port-keyed; routing it through events would
    /// force every consumer (NotificationService, EventRepository,
    /// SnapshotCoordinator, IntentDonor) to handle a case they don't
    /// care about.
    ///
    /// Bumps `lastUpdated` on every call so `@Observable` consumers
    /// re-read — the menubar status item observer in particular
    /// depends on this so its glyph and percentage refresh on each
    /// tick (and so any test that asserts a tick happened can read
    /// the bumped timestamp).
    func applyBattery(_ info: BatteryInfo?) {
        self.battery = info
        self.lastUpdated = .now
    }

    // MARK: - Per-case handlers (§4.6.1)

    /// `.telemetry` — surgical, hot path, no structural change.
    /// Phase 5 closes the Phase-3 partial implementation: the sample
    /// is appended to `telemetryHistory[portID]`, and the port's
    /// `powerDraw`/`negotiated.bitrate` are refreshed from the
    /// sample's non-nil fields.
    private func applyTelemetry(portID: PortID, sample: TelemetrySample) {
        let found = mutatePort(id: portID) { port in
            // Update non-nil sample fields onto the port. Nil-from-sample
            // means "not measured this tick" — leave the prior value
            // in place rather than wiping it.
            if let watts = sample.watts {
                port = ManifoldKit.Port(
                    id: port.id,
                    position: port.position,
                    kind: port.kind,
                    parentID: port.parentID,
                    connectedDevice: port.connectedDevice,
                    negotiated: port.negotiated,
                    powerDraw: watts,
                    availablePower: port.availablePower,
                    children: port.children
                )
            }
            if let bitrate = sample.bitrate, let proto = port.negotiated?.protocolName {
                port = ManifoldKit.Port(
                    id: port.id,
                    position: port.position,
                    kind: port.kind,
                    parentID: port.parentID,
                    connectedDevice: port.connectedDevice,
                    negotiated: LinkSpeed(protocolName: proto, bitrate: bitrate),
                    powerDraw: port.powerDraw,
                    availablePower: port.availablePower,
                    children: port.children
                )
            }
        }

        if found {
            // Append the sample to the per-port ring buffer. Phase 3's
            // §4.6.1 contract: "Append sample to that port's history
            // ring buffer (capacity 60, oldest dropped)."
            var buffer = telemetryHistory[portID] ?? TelemetryBuffer()
            buffer.append(sample)
            telemetryHistory[portID] = buffer
            lastUpdated = .now
        } else {
            // §4.6.1: "drop the sample silently and emit Log.events.debug —
            // DO NOT trigger a full refresh on a missing port from a stale
            // telemetry tick."
            Log.events.debug("telemetry for unknown port \(portID.rawValue, privacy: .public) — dropped")
        }
    }

    // MARK: - Telemetry accessor

    /// History buffer for `portID`, or nil if no samples have been
    /// recorded yet for that port. Used by the popover's `DeviceRow`
    /// to drive its sparkline.
    func history(forPortID portID: PortID) -> TelemetryBuffer? {
        telemetryHistory[portID]
    }

    // MARK: - Diagnostics accessor

    /// Active diagnostics whose `target` matches `portID`. Drives the
    /// popover's inline `DiagnosticBadge` rows — empty result means
    /// the port is clean. Phase 8.
    func diagnostics(forPortID portID: PortID) -> [Diagnostic] {
        diagnostics.filter { $0.target == portID }
    }

    /// `.attached` — surgical structural. Found: replace
    /// `connectedDevice`, clear `negotiated` + `powerDraw` (next
    /// telemetry tick fills them), leave `children` (a hub announces
    /// its own downstream ports via separate `.attached` events).
    /// Not-found: set `needsFullRefresh = true` per §4.6.1.
    private func applyAttached(device: Device, at portID: PortID) {
        let found = mutatePort(id: portID) { port in
            port = ManifoldKit.Port(
                id: port.id,
                position: port.position,
                kind: port.kind,
                parentID: port.parentID,
                connectedDevice: device,
                negotiated: nil,
                powerDraw: nil,
                availablePower: port.availablePower,
                children: port.children
            )
        }

        if found {
            lastUpdated = .now
        } else {
            // §4.6.1: "the event references a port that wasn't in the
            // last walk — emit .fullRefresh instead of inventing a port."
            // We surface via the `needsFullRefresh` flag rather than a
            // re-entrant `apply(.fullRefresh)` so the consumer owns the
            // walk-then-replace sequencing.
            Log.events.notice("attached to unknown port \(portID.rawValue, privacy: .public); requesting full refresh")
            needsFullRefresh = true
            lastUpdated = .now
        }
    }

    /// `.detached` — surgical structural. Found: clear device + all
    /// link/power state, drop downstream children (a hub being removed
    /// kills its tree), clear history (§4.6.1's "clear history").
    /// Not-found: drop + debug log per §4.6.1.
    private func applyDetached(deviceID: DeviceID, from portID: PortID) {
        let found = mutatePort(id: portID) { port in
            port = ManifoldKit.Port(
                id: port.id,
                position: port.position,
                kind: port.kind,
                parentID: port.parentID,
                connectedDevice: nil,
                negotiated: nil,
                powerDraw: nil,
                availablePower: port.availablePower,
                children: []
            )
        }

        if found {
            // §4.6.1: ".detached → clear history". The buffer for this
            // port is gone; the next .attached on this PortID will
            // start a fresh sparkline.
            telemetryHistory.removeValue(forKey: portID)
            lastUpdated = .now
        } else {
            Log.events.debug("detached from unknown port \(portID.rawValue, privacy: .public) — dropped")
        }
    }

    /// `.diagnostic` — append + dedupe by (target, ruleIdentifier).
    /// Latest wins: same key replaces existing entry, otherwise
    /// append. Phase 8 produces these.
    private func applyDiagnostic(_ diag: Diagnostic) {
        let key = (diag.target, diag.ruleIdentifier)
        diagnostics.removeAll { $0.target == key.0 && $0.ruleIdentifier == key.1 }
        diagnostics.append(diag)
        lastUpdated = .now
    }

    // MARK: - mutatePort traversal helper (§4.6.1)

    /// Walk the host tree, locate the port matching `id`, apply the
    /// closure to it. Returns `true` if the port was found and the
    /// closure ran, `false` otherwise.
    ///
    /// Implements §4.6.1's COW traversal: rebuilds the path from the
    /// matching port up to the host root, leaving sibling subtrees
    /// untouched (so SwiftUI's diff doesn't invalidate them).
    @discardableResult
    private func mutatePort(id: PortID, _ mutation: (inout ManifoldKit.Port) -> Void) -> Bool {
        for hostIndex in hosts.indices {
            var host = hosts[hostIndex]
            var newPorts = host.ports
            if Self.mutatePortInArray(&newPorts, id: id, mutation: mutation) {
                host = ManifoldKit.Host(
                    id: host.id,
                    name: host.name,
                    friendlyName: host.friendlyName,
                    model: host.model,
                    inputAdapter: host.inputAdapter,
                    ports: newPorts,
                    physicalPorts: host.physicalPorts
                )
                hosts[hostIndex] = host
                return true
            }
        }
        return false
    }

    /// Recursive helper: search a `[Port]` for the matching ID. If
    /// found, apply mutation in place. Recurses into `children`. Static
    /// so it doesn't carry MainActor isolation through the recursion.
    private static func mutatePortInArray(
        _ ports: inout [ManifoldKit.Port],
        id: PortID,
        mutation: (inout ManifoldKit.Port) -> Void
    ) -> Bool {
        for index in ports.indices {
            if ports[index].id == id {
                var port = ports[index]
                mutation(&port)
                ports[index] = port
                return true
            }
            // Recurse into children. Rebuild the parent port if a
            // descendant mutation succeeded.
            var children = ports[index].children
            if mutatePortInArray(&children, id: id, mutation: mutation) {
                let parent = ports[index]
                ports[index] = ManifoldKit.Port(
                    id: parent.id,
                    position: parent.position,
                    kind: parent.kind,
                    parentID: parent.parentID,
                    connectedDevice: parent.connectedDevice,
                    negotiated: parent.negotiated,
                    powerDraw: parent.powerDraw,
                    availablePower: parent.availablePower,
                    children: children
                )
                return true
            }
        }
        return false
    }

    // MARK: - Convenience derivations

    /// Total connected device count across every host. Used by the
    /// popover header and the Shortcut intent (Phase 12).
    var totalDeviceCount: Int {
        hosts.reduce(0) { acc, host in
            acc + host.ports.reduce(0) { portAcc, port in
                portAcc + (port.connectedDevice == nil ? 0 : 1) + Self.descendantDeviceCount(of: port)
            }
        }
    }

    private static func descendantDeviceCount(of port: ManifoldKit.Port) -> Int {
        port.children.reduce(0) { acc, child in
            acc + (child.connectedDevice == nil ? 0 : 1) + descendantDeviceCount(of: child)
        }
    }
}
