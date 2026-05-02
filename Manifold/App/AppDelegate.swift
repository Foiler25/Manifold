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
// Owns the `NSStatusItem`, the popover, and the lifetime of the
// `EventService` + `DiscoveryService` pair. Phase 3 swap-out: drops
// the per-popover-open synchronous walk in favour of subscribing to
// `EventService.events()` once and letting hot-plug events drive the
// model. The popover-open path becomes a pure UI concern; live data
// already arrived via the event stream.

import AppKit
import SwiftUI
import os
import ManifoldKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - Status item & popover

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?

    // MARK: - Discovery + events + model

    /// Phase 2's discovery API. Phase 3 still uses it for the
    /// `.fullRefresh`-triggered re-walk and for the initial seed.
    private let discoveryService = DiscoveryService()

    /// Phase 3's event source. Lifetime owned by AppDelegate; torn
    /// down in `applicationWillTerminate`.
    private var eventService: EventService?

    /// Single source of truth for every UI surface.
    private let portGraph = PortGraph()

    /// Handle to the long-running task that consumes `eventService.events()`.
    /// Cancelled in `applicationWillTerminate` so the actor doesn't
    /// leak past app shutdown.
    private var eventConsumerTask: Task<Void, Never>?

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        installStatusItem()

        let service = EventService()
        self.eventService = service
        startEventConsumer(service: service)

        // Trigger the initial walk via .fullRefresh so the consumer
        // path (walk → replace) is the same as for any subsequent
        // refresh. The seed-attach events from EventService's initial
        // notification drain are coalesced into this replace because
        // they both update the same `portGraph` on MainActor in order.
        service.requestRefresh()

#if DEBUG
        runLeakBenchIfRequested()
#endif
    }

    func applicationWillTerminate(_ notification: Notification) {
        eventConsumerTask?.cancel()
        eventService?.shutdown()
    }

    // MARK: - Status item setup

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: AppConstants.statusItemLength)
        guard let button = item.button else { return }

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

    // MARK: - Event consumer

    /// Single MainActor `for await` loop. Each event hops to MainActor
    /// here (the closure body runs on AppDelegate's actor) before
    /// touching `PortGraph`. SPEC §18 Phase 3 acceptance "Notification
    /// callbacks correctly hop to @MainActor before mutating PortGraph"
    /// is satisfied by virtue of this consumer running on MainActor.
    private func startEventConsumer(service: EventService) {
        eventConsumerTask = Task { @MainActor [weak self] in
            for await event in service.events() {
                guard let self else { return }
                await self.handle(event: event)
            }
        }
    }

    /// Per-event dispatch. `.fullRefresh` (and the not-found-attach
    /// flag set by `PortGraph.apply(.attached)` per §4.6.1) trigger
    /// a discovery walk + `replace`. Other events go straight to
    /// `portGraph.apply` for the surgical mutation path.
    private func handle(event: PortEvent) async {
        switch event {
        case .fullRefresh:
            await rebuildGraph()
        default:
            portGraph.apply(event)
            // §4.6.1: a not-found .attached sets needsFullRefresh.
            // Acknowledge + re-walk so the next .attached for this
            // port hits the surgical path.
            if portGraph.needsFullRefresh {
                portGraph.acknowledgeRefreshRequest()
                await rebuildGraph()
            }
        }
    }

    /// Walk via `DiscoveryService` and atomic-swap into `PortGraph`.
    /// Errors logged and swallowed — a failed walk shouldn't crash the
    /// app; the popover stays at its previous state until the next
    /// successful walk.
    private func rebuildGraph() async {
        do {
            let hosts = try await discoveryService.walk()
            portGraph.replace(hosts: hosts)
        } catch {
            Log.discovery.error("rebuildGraph walk failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Click handling

    @objc
    private func statusItemClicked(_ sender: Any?) {
        togglePopover()
    }

    /// Open the popover if closed, close if open. No walk-on-open
    /// anymore — the event stream keeps `PortGraph` current.
    private func togglePopover() {
        let popover = popoverIfNeeded()
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        guard let button = statusItem?.button else { return }
        popover.show(
            relativeTo: button.bounds,
            of: button,
            preferredEdge: .minY
        )
    }

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
    /// positive integer. Phase 1's `leaks(1)` verification harness;
    /// kept alive through Phase 3 so each phase's pipeline can be
    /// re-leak-checked.
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

// MARK: - Phase-2/3 popover view

private struct PopoverContent: View {

    @Bindable var graph: PortGraph

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
                comment: "Phase 1/2/3 popover header: total connected devices."
            ),
            count
        )
    }
}

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

    private var fallbackName: String {
        String(format: "Device %04X:%04X", device.vendorID, device.productID)
    }

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
