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
public import Combine

/// Single owner of the app's IOKit watchers. Lives in the backend (not the app
/// target) so both the menu bar app and the Pro plugin can share one set of
/// watchers instead of each constructing its own. Builds the watchers once,
/// starts them together, polls every second, and fires a burst of refreshes on
/// plug/unplug.
@MainActor
public final class WatcherHub {
    public static let shared = WatcherHub()

    public let portWatcher    = AppleHPMInterfaceWatcher()
    public let deviceWatcher  = USBWatcher()
    public let powerWatcher   = PowerSourceWatcher()
    public let pdWatcher      = USBPDSOPWatcher()
    public let tbWatcher      = IOIOThunderboltSwitchWatcher()
    public let usb3Watcher    = USB3TransportWatcher()
    public let trmWatcher     = TRMTransportWatcher()
    public let displayWatcher = DisplayPortTransportWatcher()

    /// Fires once after each steady-poll or burst `refreshAll()`. Lets an
    /// always-on consumer (the Pro cable-history sampler) sample at the hub's
    /// own cadence (1 Hz while a UI surface is visible, 30 s idle) without
    /// starting a second IOKit poll. A bare tick, no payload: the consumer reads
    /// whichever watcher state it needs after the tick.
    public let didRefresh = PassthroughSubject<Void, Never>()

    private var isStarted = false
    private var pollTask: Task<Void, Never>?
    private var burstTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    /// Steady-poll cadence. 1 Hz while a UI surface (the popover or a visible
    /// window) is on screen, so live readings tick smoothly. When nothing is
    /// visible we back right off: connect/disconnect already arrives via the
    /// watchers' own IOKit notifications (and the burst triggers below), so the
    /// steady poll's only idle job is catching slow value drift, which no one
    /// can see with the UI hidden. This is the bulk of the app's energy use
    /// when it just sits in the menu bar.
    private let activeInterval: Duration = .seconds(1)
    private let idleInterval: Duration = .seconds(30)
    /// Tokens for the UI surfaces currently on screen. The hub polls at the
    /// active cadence whenever any surface is visible. This is a set, not a
    /// single bool, so the main popover/window and any number of detached Pro
    /// windows each report independently: closing one detached window can't
    /// wrongly mark the hub idle while the popover (or another detached window)
    /// is still open. Starts empty: in menu-bar mode (the default) the app
    /// launches with the popover closed, so it begins idle.
    private var visibleSurfaces: Set<String> = []
    /// Derived: a UI surface is visible when at least one surface is on screen.
    private var isUIVisible: Bool { !visibleSurfaces.isEmpty }

    private init() {}

    public func start() {
        guard !isStarted else { return }
        isStarted = true

        portWatcher.start()
        deviceWatcher.start()
        powerWatcher.start()
        pdWatcher.start()
        tbWatcher.start()
        usb3Watcher.start()
        trmWatcher.start()
        displayWatcher.start()

        // Lets powerWatcher.refresh() synthesize a per-port source when macOS
        // never publishes a real IOPortFeaturePowerSource node (M1 Pro/Max/Ultra
        // USB-C, issue #401). Weak self: the closure only reads live watcher
        // state, never touches the hub's own lifecycle.
        powerWatcher.synthesisContext = { [weak self] in
            guard let self else { return nil }
            return PowerSourceSynthesisContext(
                ports: self.portWatcher.ports,
                identities: self.pdWatcher.identities,
                // hpmPortKeys() walks six IOKit service classes; wrapped in
                // a closure so it only runs on the rare tick that reaches
                // the actual synthesis call, not on every refresh().
                positionalPortKeys: { PowerTelemetryWatcher.hpmPortKeys() }
            )
        }

        startPoll()
        setupBurstTriggers()
    }

    /// Tell the hub whether a UI surface is on screen. The app calls this when
    /// the popover opens/closes (menu-bar mode) or the window's visibility
    /// changes (window mode). Becoming visible refreshes once immediately so the
    /// surface paints current data, then restarts the poll at the faster
    /// cadence; going idle restarts it at the slower one. Connect/disconnect
    /// detection is unaffected either way: it runs off IOKit notifications, not
    /// this poll.
    public func setUIVisible(_ visible: Bool) {
        setSurfaceVisible(visible, surface: "main")
    }

    /// Mark a named UI surface as visible or hidden. The main popover/window
    /// reports through `setUIVisible` (surface "main"); detached Pro windows
    /// report their own per-window token. The hub becomes visible when the
    /// first surface appears (refreshing once so the surface paints current
    /// data) and goes idle only when the last one disappears.
    public func setSurfaceVisible(_ visible: Bool, surface: String) {
        guard isStarted else { return }
        let wasVisible = isUIVisible
        if visible {
            visibleSurfaces.insert(surface)
        } else {
            visibleSurfaces.remove(surface)
        }
        guard wasVisible != isUIVisible else { return }
        if isUIVisible { refreshAll() }
        startPoll()
    }

    public func refreshAll() {
        portWatcher.refresh()
        // pdWatcher before powerWatcher: PowerSourceSynthesis's partner-kind
        // attribution rung (issue #401) needs this tick's identities, not
        // last tick's, to recognise a power-brick SOP partner.
        pdWatcher.refresh()
        powerWatcher.refresh()
        tbWatcher.refresh()
        usb3Watcher.refresh()
        trmWatcher.refresh()
        displayWatcher.refresh()
        didRefresh.send(())
    }

    private func startPoll() {
        pollTask?.cancel()
        let interval = isUIVisible ? activeInterval : idleInterval
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { return }
                self.refreshAll()
            }
        }
    }

    private func setupBurstTriggers() {
        deviceWatcher.$devices
            .dropFirst()
            .sink { [weak self] _ in
                guard let self else { return }
                self.scheduleBurst()
            }
            .store(in: &cancellables)

        powerWatcher.$sources
            .dropFirst()
            .sink { [weak self] _ in
                guard let self else { return }
                self.scheduleBurst()
            }
            .store(in: &cancellables)

        pdWatcher.$identities
            .dropFirst()
            .sink { [weak self] _ in
                guard let self else { return }
                self.scheduleBurst()
            }
            .store(in: &cancellables)
    }

    private func scheduleBurst() {
        burstTask?.cancel()
        burstTask = Task { @MainActor [weak self] in
            for delay in [150, 500, 1500, 3000, 6000] {
                try? await Task.sleep(for: .milliseconds(delay))
                guard !Task.isCancelled, let self else { return }
                self.refreshAll()
            }
        }
    }
}
