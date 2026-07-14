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
// CableEngineLifecycle.swift
//
// Phase 21 — thin lifecycle wrapper for `CableEngine`. Mirrors
// `SamplerLifecycle` but the cable engine has only one consumer (the
// main window's Cables tab), so we don't need the multi-surface
// counter the telemetry samplers use.
//
// `MainWindow.onAppear`/`onDisappear` call `engineDidAppear()` /
// `engineDidDisappear()` directly. When the window is closed, the
// engine stops; reopening kicks it back on. This keeps idle CPU at
// zero when the user isn't looking at the Cables tab.
//
// Per DECISIONS.md D24: scoping the engine to window lifetime
// avoids leaving 1Hz IOKit polling running unobserved.

import Foundation
import os

@MainActor
final class CableEngineLifecycle {

    private weak var engine: CableEngine?
    private(set) var isShutDown: Bool = false

    /// Tracks whether the window is currently visible. Set by
    /// `windowDidAppear` / `windowDidDisappear`; replayed by
    /// `attach()` so a `windowDidAppear` that fires before
    /// `attach()` (SwiftUI's `onAppear` can run before
    /// `applicationDidFinishLaunching` completes — observed in
    /// production logs) doesn't lose its start signal.
    private var visibleSurfaces: Set<String> = []

    init(engine: CableEngine? = nil) {
        self.engine = engine
    }

    /// Late-bind the engine so AppDelegate can construct lifecycle and
    /// engine in either order. If the window is already visible at
    /// attach time, kick the engine immediately — mirrors
    /// `SamplerLifecycle.attach`'s replay-of-current-state pattern.
    func attach(_ engine: CableEngine) {
        Log.app.info("CableEngineLifecycle.attach — engine bound, surfaces=\(self.visibleSurfaces.count, privacy: .public)")
        self.engine = engine
        if !visibleSurfaces.isEmpty && !isShutDown {
            engine.start()
        }
    }

    /// Called from `MainWindow.onAppear`. Records the visible state
    /// and starts the engine if attached. If `attach()` hasn't run
    /// yet, the visible state is replayed when it does.
    func surfaceDidAppear(_ id: String) {
        guard !isShutDown else { return }
        let wasEmpty = visibleSurfaces.isEmpty
        visibleSurfaces.insert(id)
        if wasEmpty, !visibleSurfaces.isEmpty { engine?.start() }
    }

    /// Called from `MainWindow.onDisappear`. Stops the engine. The
    /// engine is itself idempotent so this is safe to call repeatedly.
    func surfaceDidDisappear(_ id: String) {
        guard !isShutDown else { return }
        visibleSurfaces.remove(id)
        if visibleSurfaces.isEmpty { engine?.stop() }
    }

    func windowDidAppear() { surfaceDidAppear("main") }
    func windowDidDisappear() { surfaceDidDisappear("main") }

    /// `applicationWillTerminate` cleanup. Idempotent.
    func shutdown() {
        guard !isShutDown else { return }
        isShutDown = true
        visibleSurfaces.removeAll()
        engine?.stop()
    }
}
