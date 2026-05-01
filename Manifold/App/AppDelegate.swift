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
// Owns the single `NSStatusItem` and (Phase 1+) the placeholder
// `NSPopover` that appears when the user clicks it. Phase 4 splits this
// out into `StatusItemController` + `PopoverHostingView` + `PopoverRoot`
// per SPEC.md §3; for Phase 1 the popover lives at the bottom of this
// file so the Phase-4 cleanup is one delete + one move.
//
// Why `@MainActor` on the whole class: every AppKit interaction in this
// file (`NSStatusBar`, `NSPopover`, `NSHostingController`) is main-actor
// constrained in Swift 6 strict mode. Marking the class once is cleaner
// than annotating every member.

import AppKit
import SwiftUI
import os

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - Status item & popover

    /// The system-vended menu bar slot. Held strongly because
    /// `NSStatusBar` releases it the moment we drop the reference.
    private var statusItem: NSStatusItem?

    /// The popover shown on status-item click. Created lazily on first
    /// open so launch is fast even if the user never clicks the icon.
    private var popover: NSPopover?

    // MARK: - Discovery

    /// Phase-1 USB walker, configured to hit live IOKit. Kept on the
    /// AppDelegate so the popover can request a fresh walk on every
    /// open. Phase 3 will replace on-demand walking with event-driven
    /// updates from `EventService`.
    private let usbWalker = USBWalker()

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        installStatusItem()
        performInitialUSBWalk()
#if DEBUG
        runLeakBenchIfRequested()
#endif
    }

#if DEBUG
    /// DEBUG-only stress harness. Runs `usbWalker.walk()` N times in a
    /// tight loop when the `MANIFOLD_LEAK_BENCH` environment variable
    /// is set to a positive integer. Used to satisfy the SPEC §18 Phase 1
    /// "Instruments Leaks pass — zero leaks after walking 100x" criterion
    /// without an interactive Instruments session: launch the app with
    /// the env var, wait for completion (logged to stderr), then attach
    /// `leaks(1)` to the still-alive process and inspect.
    ///
    /// Tagged DEBUG-only because Release builds must never run gratuitous
    /// IOKit traversals at launch. This is also the seed of followup
    /// F7 ("scriptable leak bench") — Phase 3+ may extend this with an
    /// XCTest wrapper that drives the same loop and asserts via Mach
    /// task allocation diff or the `leaks` exit status.
    private func runLeakBenchIfRequested() {
        guard
            let raw = ProcessInfo.processInfo.environment["MANIFOLD_LEAK_BENCH"],
            let count = Int(raw),
            count > 0
        else { return }

        let start = Date()
        for _ in 0..<count {
            _ = try? usbWalker.walk()
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
#endif

    /// One-shot walk at launch so the popover already has data on first
    /// open and so the SPEC criterion's "prints every connected device"
    /// requirement is satisfied without requiring user interaction. The
    /// log lines surface in `log show --predicate 'subsystem ==
    /// "com.Loofa.Manifold"'`. Phase 3 replaces this initial walk with
    /// event-driven updates from `EventService`.
    private func performInitialUSBWalk() {
        do {
            let devices = try usbWalker.walkAndLog()
            Phase1PopoverModel.shared.update(devices: devices)
        } catch {
            // Log and swallow — a failed initial walk should not crash
            // the app. The popover will simply show the empty state
            // until the user clicks (which retries) or until Phase 3
            // events kick in.
            Log.discovery.error("Initial USB walk failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Status item setup

    /// Builds the `NSStatusItem`, sets a templated SF Symbol as its icon,
    /// and wires the click handler to `togglePopover`.
    ///
    /// Template image (`isTemplate = true`) tells AppKit to invert and
    /// tint the icon to match the menu bar's appearance — required for
    /// the icon to stay legible across light/dark menu bar backgrounds.
    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: AppConstants.statusItemLength)

        guard let button = item.button else {
            // `NSStatusItem.button` is nil only when the status bar is
            // unavailable (headless test runs). Safe no-op in that case.
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

    // MARK: - Click handling

    @objc
    private func statusItemClicked(_ sender: Any?) {
        togglePopover()
    }

    /// Open the popover if it is closed, close it if open.
    ///
    /// Why request a fresh walk on every open (Phase 1 only): there is
    /// no event subscription yet, so the popover would otherwise show
    /// stale state. Phase 3 introduces hot-plug events and removes this
    /// per-open walk in favor of subscribed updates.
    private func togglePopover() {
        let popover = popoverIfNeeded()
        if popover.isShown {
            popover.performClose(nil)
            return
        }

        let devices = (try? usbWalker.walkAndLog()) ?? []
        Phase1PopoverModel.shared.update(devices: devices)

        guard let button = statusItem?.button else { return }
        popover.show(
            relativeTo: button.bounds,
            of: button,
            preferredEdge: .minY
        )
    }

    /// Lazy popover construction. The `NSHostingController` wraps the
    /// SwiftUI body so the entire popover content is SwiftUI from
    /// Phase 1 onward — matches DECISIONS.md D1 ("AppKit shim only").
    private func popoverIfNeeded() -> NSPopover {
        if let existing = popover { return existing }

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = AppConstants.popoverContentSize
        popover.contentViewController = NSHostingController(
            rootView: Phase1PopoverContent(model: Phase1PopoverModel.shared)
        )
        self.popover = popover
        return popover
    }
}

// MARK: - Phase 1 popover model

/// View-model carrying the most recent walk result to the popover.
///
/// `@Observable` (not `ObservableObject`) so we don't pull in Combine.
/// SwiftUI auto-observes property reads on `@Observable` reference
/// types passed in by value — no `@Environment` or `@StateObject`
/// needed for this Phase-1 use. Phase 4 replaces this with the proper
/// `@Observable PortGraph` once Phase 2 has built the model.
///
/// Singleton because the popover content view sees one instance and
/// AppDelegate is the only writer. Worth noting and not generalising —
/// this is a Phase-1 shortcut that goes away with Phase 4's full UI.
@MainActor
@Observable
final class Phase1PopoverModel {
    static let shared = Phase1PopoverModel()
    private init() {}

    private(set) var devices: [USBDeviceSnapshot] = []

    func update(devices: [USBDeviceSnapshot]) {
        self.devices = devices
    }
}

// MARK: - Phase 1 popover view

/// Phase-1 popover body. Header line ("N devices connected") + a list
/// of detected devices with VID/PID/speed/power. Replaced wholesale by
/// `PopoverRoot` in Phase 4.
///
/// All strings live in `Localizable.xcstrings`; no string literals
/// inline in the view body, per builder.md.
private struct Phase1PopoverContent: View {

    /// Reference to the shared @Observable model. Reads inside `body`
    /// are tracked by SwiftUI and re-render the view when the model
    /// updates.
    let model: Phase1PopoverModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(headerString(for: model.devices.count))
                .font(.headline)

            Divider()

            if model.devices.isEmpty {
                // Empty state — surfaces explicitly so the user knows
                // the walker ran rather than wondering whether the app
                // is broken.
                Text("popover.devices.empty")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
            } else {
                // Phase 1 list: one row per device. Phase 4 will swap
                // this for a hierarchy-aware `OutlineGroup` over `Port`
                // values. ScrollView so a long device list stays
                // navigable inside the fixed-size popover.
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(model.devices, id: \.registryPath) { device in
                            Phase1DeviceRow(device: device)
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

    /// Build the header label, picking singular/plural via the string
    /// catalog. `String(localized:)` reads the `popover.devices.count`
    /// entry in `Localizable.xcstrings`, which carries the plural rules.
    private func headerString(for count: Int) -> String {
        String(
            format: NSLocalizedString(
                "popover.devices.count",
                comment: "Phase 1 popover header: total connected devices."
            ),
            count
        )
    }
}

/// Row representing one Phase-1 device. Pure presentation; no app
/// behaviour. Replaced by `DeviceRow` in Phase 4.
private struct Phase1DeviceRow: View {
    let device: USBDeviceSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(device.productName ?? device.fallbackName)
                .font(.body)
            Text(device.detailLine)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - USBDeviceSnapshot display helpers

private extension USBDeviceSnapshot {

    /// Used when `productName` is nil — falls back to a "VID:PID"
    /// pseudo-name so the row is never empty.
    var fallbackName: String {
        String(format: "Device %04X:%04X", vendorID, productID)
    }

    /// Two-segment caption: VID/PID + speed + power. Power is
    /// suppressed when nil so the row doesn't end in a dangling
    /// separator.
    var detailLine: String {
        var segments: [String] = [
            String(format: "%04X:%04X", vendorID, productID),
            USBDiscoveryConstants.speedName(for: speed)
        ]
        if let mA = requestedPowerMA {
            segments.append("\(mA) mA")
        }
        return segments.joined(separator: " · ")
    }
}
