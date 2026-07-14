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
// PowerTelemetryLifecycle.swift

import Foundation

@MainActor
final class PowerTelemetryLifecycle {
    private weak var engine: PowerTelemetryEngine?
    private var surfaces: Set<String> = []
    private(set) var isShutDown = false

    func attach(_ engine: PowerTelemetryEngine) {
        self.engine = engine
        if !surfaces.isEmpty, !isShutDown { engine.start() }
    }

    func surfaceDidAppear(_ id: String) {
        guard !isShutDown else { return }
        let wasEmpty = surfaces.isEmpty
        surfaces.insert(id)
        if wasEmpty, !surfaces.isEmpty { engine?.start() }
    }

    func surfaceDidDisappear(_ id: String) {
        guard !isShutDown else { return }
        surfaces.remove(id)
        if surfaces.isEmpty { engine?.stop() }
    }

    func shutdown() {
        guard !isShutDown else { return }
        isShutDown = true
        surfaces.removeAll()
        engine?.stop()
    }
}
