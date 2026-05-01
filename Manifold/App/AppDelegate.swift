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
// AppDelegate.swift
//
// Owns the `NSStatusItem` and the popover that appears on click.
// Phase 2 swap-out: replaces Phase 1's `USBWalker` + `Phase1PopoverModel`
// pair with the SPEC §6 `DiscoveryService.walk() async throws -> [Host]`
// API and the `@Observable PortGraph` that the popover SwiftUI body
// reads through. Phase 4 splits this file into
// `StatusItemController` + `PopoverHostingView` + `PopoverRoot`.

import AppKit
import SwiftUI
import os
import ManifoldKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - Status item & popover

    /// The system-vended menu bar slot. Held strongly because
    /// `NSStatusBar` releases it the moment we drop the reference.
    private var statusItem: NSStatusItem?

    /// The popover shown on status-item click. Created lazily on
    /// first open so launch is fast even if the user never clicks.
    private var popover: NSPopover?

    // MARK: - Discovery + model

    /// SPEC §6 discovery API. Replaces Phase 1's direct `USBWalker`
    /// reference; AppDelegate no longer talks to IOKit directly.
    private let discoveryService = DiscoveryService()

    /// Single source of truth for every UI surface. The popover
    /// reads `portGraph.hosts` through SwiftUI's `@Observable`
    /// machinery; updates re-render automatically.
    private let portGraph = PortGraph()

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        installStatusItem()
        Task { await performInitialWalk() }
#if DEBUG
        runLeakBenchIfRequested()
#endif
    }

    // MARK: - Status item setup

    /// Builds the `NSStatusItem`, sets a templated SF Symbol as its
    /// icon, and wires the click handler to `togglePopover`.
    ///
    /// Template image (`isTemplate = true`) tells AppKit to invert
    /// and tint the icon to match the menu bar's appearance — required
    /// for the icon to stay legible across light/dark menu bars.
    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: AppConstants.statusItemLength)

        guard let button = item.button else {
            // `NSStatusItem.button` is nil only when the status bar
            // is unavailable (headless test runs). Safe no-op.
            return
        }

        let image = NSImage(
            systemSymbolName: AppConstants.menuBarIconSymbolName,
            accessibilityDescription: NSLocalizedString(
                "menubar.icon.accessibility",
                comment: "Spoken description of the Manifold menu bar icon."
            )
        )
        image?.isTemplate = true
        button.image = image

        button.target = self
        button.action = #selector(statusItemClicked(_:))

        statusItem = item
        Log.app.info("NSStatusItem installed.")
    }

    // MARK: - Discovery

    /// One-shot walk at launch so the popover already has data on
    /// first open. Phase 3 replaces this with event-driven updates
    /// from `EventService`; until then we do an additional walk on
    /// every popover open (`togglePopover`) so reopening reflects
    /// hot-plug changes the user made while the popover was closed.
    ///
    /// `discoveryService.walk()` internally invokes
    /// `usbWalker.walkAndLog()`, so the SPEC §16.1 logging discipline
    /// (os.Logger always, DEBUG-only stderr) fires from this single
    /// call — no separate Phase-1-style emit needed.
    private func performInitialWalk() async {
        do {
            let hosts = try await discoveryService.walk()
            portGraph.replace(hosts: hosts)
        } catch {
            Log.discovery.error("Initial walk failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Click handling

    @objc
    private func statusItemClicked(_ sender: Any?) {
        togglePopover()
    }

    /// Open the popover if it is closed, close it if open.
    /// Triggers a fresh walk on open so changes since the last open
    /// are reflected. Phase 3 retires the per-open walk in favour of
    /// event-driven updates.
    private func togglePopover() {
        let popover = popoverIfNeeded()
        if popover.isShown {
            popover.performClose(nil)
            return
        }

        Task {
            do {
                let hosts = try await discoveryService.walk()
                portGraph.replace(hosts: hosts)
            } catch {
                Log.discovery.error("Popover-open walk failed: \(String(describing: error), privacy: .public)")
            }
        }

        guard let button = statusItem?.button else { return }
        popover.show(
            relativeTo: button.bounds,
            of: button,
            preferredEdge: .minY
        )
    }

    /// Lazy popover construction. `NSHostingController` wraps the
    /// SwiftUI body so the entire popover content is SwiftUI from
    /// Phase 1 onward — matches DECISIONS.md D1 ("AppKit shim only").
    private func popoverIfNeeded() -> NSPopover {
        if let existing = popover { return existing }

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = AppConstants.popoverContentSize
        popover.contentViewController = NSHostingController(
            rootView: PopoverContent(graph: portGraph)
        )
        self.popover = popover
        return popover
    }

#if DEBUG
    /// DEBUG-only stress harness. Runs `discoveryService.walk()` N
    /// times in a tight loop when `MANIFOLD_LEAK_BENCH` is set to a
    /// positive integer. Used to verify the SPEC §18 Phase 1
    /// "Instruments Leaks pass — zero leaks after 100 walks" criterion
    /// from `leaks(1)` without an interactive Instruments session.
    ///
    /// Goes through `discoveryService.walk()` rather than the bare
    /// `USBWalker.walk()` so the bench exercises the full Phase-2
    /// transformation path (snapshot → builder → Host array). If the
    /// IOKit retain discipline holds end-to-end, leak count stays 0.
    private func runLeakBenchIfRequested() {
        guard
            let raw = ProcessInfo.processInfo.environment["MANIFOLD_LEAK_BENCH"],
            let count = Int(raw),
            count > 0
        else { return }

        Task { [discoveryService] in
            let start = Date()
            for _ in 0..<count {
                _ = try? await discoveryService.walk()
            }
            let elapsed = Date().timeIntervalSince(start)
            let line = String(
                format: "[Manifold leak-bench] %d walks completed in %.3f s — process held open for leaks(1) attach\n",
                count,
                elapsed
            )
            if let data = line.data(using: .utf8) {
                FileHandle.standardError.write(data)
            }
            Log.app.notice("Leak bench: \(count, privacy: .public) walks in \(elapsed, privacy: .public)s")
        }
    }
#endif
}

// MARK: - Phase-1/2 popover view

/// Phase-1/2 popover body. Header ("N devices connected") plus a list
/// of detected devices with VID/PID/speed/power. Replaced by
/// `PopoverRoot` in Phase 4. Reads through `@Bindable` so SwiftUI
/// observes `PortGraph`'s `@Observable` properties.
private struct PopoverContent: View {

    /// `@Bindable` exposes the `PortGraph` to SwiftUI's observation
    /// system; reads of `graph.hosts` etc. inside `body` re-render
    /// automatically when the graph mutates.
    @Bindable var graph: PortGraph

    /// Devices flattened across hosts (Phase 2 has only one host but
    /// the API is shaped for the general case). Pulled into a
    /// computed property so the body stays readable.
    private var devices: [(host: ManifoldKit.Host, port: ManifoldKit.Port, device: Device)] {
        graph.hosts.flatMap { host in
            host.ports.compactMap { port in
                port.connectedDevice.map { (host, port, $0) }
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(headerString(for: graph.totalDeviceCount))
                .font(.headline)

            Divider()

            if devices.isEmpty {
                Text("popover.devices.empty")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(devices, id: \.port.id) { entry in
                            DeviceListRow(port: entry.port, device: entry.device)
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(
            width: AppConstants.popoverContentSize.width,
            height: AppConstants.popoverContentSize.height,
            alignment: .topLeading
        )
    }

    private func headerString(for count: Int) -> String {
        String(
            format: NSLocalizedString(
                "popover.devices.count",
                comment: "Phase 1/2 popover header: total connected devices."
            ),
            count
        )
    }
}

/// Row representing one Phase-2 device. Pure presentation; no app
/// behaviour. Replaced by `DeviceRow` in Phase 4.
private struct DeviceListRow: View {

    let port: ManifoldKit.Port
    let device: Device

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(device.name.isEmpty ? fallbackName : device.name)
                .font(.body)
            Text(detailLine)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// "VID:PID" placeholder when the resolved device name is empty.
    private var fallbackName: String {
        String(format: "Device %04X:%04X", device.vendorID, device.productID)
    }

    /// "VID:PID · Protocol · Power". Power suppressed when nil so the
    /// row doesn't end in a dangling separator.
    private var detailLine: String {
        var segments: [String] = [
            String(format: "%04X:%04X", device.vendorID, device.productID),
            port.negotiated?.protocolName ?? "Unknown"
        ]
        if let watts = port.powerDraw {
            segments.append(watts.formatted)
        }
        return segments.joined(separator: " · ")
    }
}
