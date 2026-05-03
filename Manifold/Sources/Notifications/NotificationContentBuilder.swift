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
// NotificationContentBuilder.swift
//
// Pure mapping from `(PortEvent, [Host])` to `UNNotificationContent?`.
// Returns nil for events that should not produce a notification
// (`.telemetry`, `.fullRefresh`, or any event whose toggle is off).
// All UN-side concerns (delivery, identifiers, sound) live in
// `NotificationService`.
//
// Why split builder + service: the builder is trivially testable
// (input → output), while the service's UN delivery is not
// (UNUserNotificationCenter is a process-singleton with no
// dependency-injection hook). Pinning content shape via tests gives
// us confidence in the per-event-type behaviour without reaching
// for UI tests.
//
// `[Host]` is taken so the builder can resolve a `.detached` event's
// previously-connected device name (the event itself only carries
// `DeviceID`). When the host list doesn't contain the port, the
// builder falls back to a generic "Device disconnected" body — better
// than nothing.

import Foundation
import UserNotifications
import ManifoldKit

enum NotificationContentBuilder {

    /// Build content for one event. Returns nil when the event has
    /// no notifiable interpretation (telemetry / fullRefresh) or
    /// when the matching toggle is off.
    ///
    /// `hosts` is the graph state AT THE TIME of the event — for
    /// `.detached`, this should be the pre-apply graph so the device
    /// name is still resolvable. The service guarantees this ordering.
    static func makeContent(
        for event: PortEvent,
        hosts: [ManifoldKit.Host],
        preferences: NotificationPreferences
    ) -> UNNotificationContent? {
        switch event {
        case .attached(let device, at: let portID):
            guard preferences.connectEnabled else { return nil }
            return makeAttachedContent(device: device, portID: portID, hosts: hosts)

        case .detached(let deviceID, from: let portID):
            guard preferences.disconnectEnabled else { return nil }
            return makeDetachedContent(deviceID: deviceID, portID: portID, hosts: hosts)

        case .diagnostic(let diag):
            guard preferences.diagnosticEnabled else { return nil }
            return makeDiagnosticContent(diagnostic: diag, hosts: hosts)

        case .telemetry, .fullRefresh:
            return nil
        }
    }

    // MARK: - Per-case builders

    private static func makeAttachedContent(
        device: Device,
        portID: PortID,
        hosts: [ManifoldKit.Host]
    ) -> UNNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = NSLocalizedString(
            "notification.connected.title",
            comment: "Title for a device-connected notification."
        )
        content.subtitle = device.name
        content.body = portSummary(forPortID: portID, hosts: hosts)
        content.threadIdentifier = portID.rawValue  // groups consecutive events on the same port
        return content
    }

    private static func makeDetachedContent(
        deviceID: DeviceID,
        portID: PortID,
        hosts: [ManifoldKit.Host]
    ) -> UNNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = NSLocalizedString(
            "notification.disconnected.title",
            comment: "Title for a device-disconnected notification."
        )
        // Lookup by DeviceID — the device should still be in the
        // pre-apply graph at the moment .detached fires. If the
        // service is given a stale graph, fall back to the deviceID.
        content.subtitle = deviceName(forDeviceID: deviceID, in: hosts)
            ?? NSLocalizedString(
                "notification.disconnected.subtitle.unknown",
                comment: "Fallback subtitle when the disconnected device's name can't be resolved."
            )
        content.body = portSummary(forPortID: portID, hosts: hosts)
        content.threadIdentifier = portID.rawValue
        return content
    }

    private static func makeDiagnosticContent(
        diagnostic: Diagnostic,
        hosts: [ManifoldKit.Host]
    ) -> UNNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = diagnostic.title
        content.subtitle = portSummary(forPortID: diagnostic.target, hosts: hosts)
        content.body = diagnostic.detail
        content.threadIdentifier = diagnostic.target.rawValue
        return content
    }

    // MARK: - Helpers

    /// "USB-C Port 2" / "Thunderbolt Port 1" / etc. — the human
    /// summary the BRIEF "screenshot 2" layout calls "port summary".
    /// Walks the host trees to find the port; returns the localized
    /// kind label + position. Falls back to a generic "Port" when the
    /// portID is not in the graph.
    static func portSummary(forPortID portID: PortID, hosts: [ManifoldKit.Host]) -> String {
        guard let port = findPort(portID, in: hosts) else {
            return NSLocalizedString(
                "notification.port.fallback",
                comment: "Fallback when a notification's port can't be located in the graph."
            )
        }
        let kindLabel = portKindLabel(port.kind)
        return String(
            format: NSLocalizedString(
                "notification.port.summary",
                comment: "Body string. %1$@ kind label, %2$lld 1-indexed position."
            ),
            kindLabel,
            port.position
        )
    }

    /// DFS for a port matching `portID`. Returns nil when not found.
    /// Used by both the port-summary helper and the device-name
    /// resolver.
    private static func findPort(_ portID: PortID, in hosts: [ManifoldKit.Host]) -> ManifoldKit.Port? {
        for host in hosts {
            if let found = findPort(portID, in: host.ports) {
                return found
            }
        }
        return nil
    }

    private static func findPort(_ portID: PortID, in ports: [ManifoldKit.Port]) -> ManifoldKit.Port? {
        for port in ports {
            if port.id == portID { return port }
            if let inChild = findPort(portID, in: port.children) {
                return inChild
            }
        }
        return nil
    }

    /// Look up the device with `id` across every host's port tree.
    /// Returns the device's `name`; nil when the device isn't in the
    /// graph (typical for a stale `.detached` arriving after another
    /// rebuild). Phase 10's GRDB layer can extend this with a
    /// historical lookup once persistence lands.
    private static func deviceName(forDeviceID deviceID: DeviceID, in hosts: [ManifoldKit.Host]) -> String? {
        for host in hosts {
            if let name = deviceName(forDeviceID: deviceID, in: host.ports) {
                return name
            }
        }
        return nil
    }

    private static func deviceName(forDeviceID deviceID: DeviceID, in ports: [ManifoldKit.Port]) -> String? {
        for port in ports {
            if port.connectedDevice?.id == deviceID {
                return port.connectedDevice?.name
            }
            if let inChild = deviceName(forDeviceID: deviceID, in: port.children) {
                return inChild
            }
        }
        return nil
    }

    /// Localized port-kind label. Reuses the existing
    /// `popover.port.kind.*` keys (already shipped Phase 4) — no new
    /// kind strings needed; we only add notification-side titles +
    /// summaries.
    private static func portKindLabel(_ kind: PortKind) -> String {
        switch kind {
        case .usbA:        return NSLocalizedString("popover.port.kind.usbA",        comment: "")
        case .usbC:        return NSLocalizedString("popover.port.kind.usbC",        comment: "")
        case .thunderbolt: return NSLocalizedString("popover.port.kind.thunderbolt", comment: "")
        case .hdmi:        return NSLocalizedString("popover.port.kind.hdmi",        comment: "")
        case .sd:          return NSLocalizedString("popover.port.kind.sd",          comment: "")
        case .audio:       return NSLocalizedString("popover.port.kind.audio",       comment: "")
        case .ethernet:    return NSLocalizedString("popover.port.kind.ethernet",    comment: "")
        case .magsafe:     return NSLocalizedString("popover.port.kind.magsafe",     comment: "")
        case .unknown:     return NSLocalizedString("popover.port.kind.unknown",     comment: "")
        }
    }
}
