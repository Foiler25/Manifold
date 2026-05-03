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
// ManifoldWidgetBundle.swift
//
// Phase 13. The bundle aggregates every widget the extension
// publishes to the system per SPEC §18 Phase 13:
//
//   - PowerWidget — lock-screen circular AND desktop small.
//     Renders total power draw OR device count (Phase 13 default:
//     total power; Phase 14+ Settings will toggle to device count
//     per the SPEC §18 #4 "user-configurable" wording).
//   - TopDevicesWidget — desktop medium. Top 4 devices by power
//     with sparklines.
//   - ControlCenterWidget — Control Center compact. Tap opens
//     the menu bar popover (or main window as a fallback).
//
// **The widget extension does NOT import IOKit.** Per SPEC §18
// Phase 13 #9. Builder verification: `nm` of the built widget
// binary must not reference IOKit symbols. Source-level: every
// widget file imports only WidgetKit + SwiftUI + ManifoldKit;
// ManifoldKit itself is IOKit-free (the IOKit walkers live in
// the Manifold app target).

import WidgetKit
import SwiftUI

@main
struct ManifoldWidgetBundle: WidgetBundle {
    var body: some Widget {
        PowerWidget()
        TopDevicesWidget()
        ControlCenterWidget()
    }
}
