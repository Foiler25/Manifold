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
// DiscoveryService.swift
//
// Phase-2 discovery entry point. Replaces Phase 1's direct
// `usbWalker.walk()` call from AppDelegate with the per-SPEC §6
// `walk() async throws -> [Host]` API.
//
// Responsibilities:
//   - Drive every sub-walker (Phase 2: USB only; Phase 7 adds TB
//     and DisplayResolver).
//   - Resolve the local Host's metadata from `IOPlatformExpertDevice`.
//   - Hand everything to `PortGraphBuilder` and return the assembled
//     `[Host]` graph.
//
// Why `async throws`: the SPEC mandates this signature so Phase 3 can
// hop to a dedicated `IOKitQueue` without changing the callers' world.
// Phase 2's implementation runs synchronously on the calling actor —
// the live IOKit walk takes < 1 ms on M1 Max per Phase 1's leak bench
// (5263 walks/s) so blocking the caller is acceptable for now.
//
// `MainActor` because the popover, the eventual PortGraph, and the
// AppDelegate that drives this all live on MainActor. Phase 3
// rewrites the walker hop pattern; this isolation may relax then.

import Foundation
import IOKit
import ManifoldKit

@MainActor
final class DiscoveryService {

    // MARK: - Dependencies

    /// USB-side walker. Defaulted to a live IOKit source; tests inject
    /// a `USBWalker(source: FixtureUSBSource(...))` to drive
    /// fixture-based assertions without hitting hardware.
    private let usbWalker: USBWalker

    /// Pure transformation from snapshots → graph.
    private let builder: PortGraphBuilder

    /// Override host metadata for tests. nil means "resolve from live
    /// IOKit at walk time"; tests pass an explicit `HostMetadata` so
    /// the assembled `Host` is deterministic.
    private let hostMetadataOverride: HostMetadata?

    init(
        usbWalker: USBWalker = USBWalker(),
        builder: PortGraphBuilder = PortGraphBuilder(),
        hostMetadataOverride: HostMetadata? = nil
    ) {
        self.usbWalker = usbWalker
        self.builder = builder
        self.hostMetadataOverride = hostMetadataOverride
    }

    // MARK: - Public API

    /// Walk the IORegistry once and return the resulting `[Host]`
    /// graph. Single-Mac for Phase 2 (the array always has exactly
    /// one element); future "remote machine" support — explicitly out
    /// of scope per BRIEF.md — would let the array grow.
    ///
    /// Internally calls `usbWalker.walkAndLog()` so the SPEC §16.1
    /// logging discipline (os.Logger always, DEBUG-only stderr) still
    /// fires once per discovery call. Errors propagate from the
    /// walker. The host-metadata resolver returns sane defaults
    /// rather than throwing — a Mac without a `IOPlatformExpertDevice`
    /// registry entry is a catastrophe no error message could
    /// meaningfully describe.
    func walk() async throws -> [ManifoldKit.Host] {
        let snapshots = try usbWalker.walkAndLog()
        let metadata = hostMetadataOverride ?? Self.resolveLiveHostMetadata()
        let host = builder.buildHost(metadata: metadata, usbDevices: snapshots)
        return [host]
    }

    // MARK: - Host metadata resolver

    /// Read the local Mac's stable identifier and model from
    /// `IOPlatformExpertDevice`. Falls back to a labelled placeholder
    /// if either property is missing — a missing UUID would mean we
    /// can't track this Mac across reboots, which is bad, but worse
    /// would be crashing the discovery pipeline over it.
    private static func resolveLiveHostMetadata() -> HostMetadata {
        var resolvedID: HostID?
        var resolvedModel: String?

        guard let matching = IOServiceMatching("IOPlatformExpertDevice") else {
            return fallbackMetadata()
        }

        withMatchingServices(matching) { iterator in
            forEachEntry(in: iterator) { entry in
                if resolvedID == nil,
                   let uuid = stringProperty("IOPlatformUUID", of: entry) {
                    resolvedID = HostID(uuid)
                }
                // The `model` property comes back as `Data` (a
                // C-string with trailing NUL bytes) on Apple Silicon.
                // Convert via String(decoding:as:) and strip the NUL.
                if resolvedModel == nil,
                   let modelData = property("model", of: entry, as: Data.self) {
                    let bytes = modelData.prefix(while: { $0 != 0 })
                    let model = String(decoding: bytes, as: UTF8.self)
                    if !model.isEmpty { resolvedModel = model }
                }
            }
        }

        return HostMetadata(
            id: resolvedID ?? HostID("UNKNOWN-\(ProcessInfo.processInfo.hostName)"),
            name: ProcessInfo.processInfo.hostName,    // user-visible host name; Phase 6 may swap to model-derived
            model: resolvedModel ?? "Unknown"
        )
    }

    /// Returned when even the matching dictionary couldn't be built —
    /// a configuration error (bad class name) that should never fire
    /// in practice, but if it does we want a non-crashing fallback.
    private static func fallbackMetadata() -> HostMetadata {
        HostMetadata(
            id: HostID("UNKNOWN-\(ProcessInfo.processInfo.hostName)"),
            name: ProcessInfo.processInfo.hostName,
            model: "Unknown"
        )
    }
}
