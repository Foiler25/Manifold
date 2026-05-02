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
// Per SPEC.md §6 — single entry point for "walk the IORegistry once
// and return [Host]." Phase 7 closes Reviewer F9 by routing every
// IOKit-touching call through `IOKitQueue` (the SPEC §1
// dedicated-serial-executor for IOKit traversal). Phases 1–6 ran
// USB walks synchronously on whichever actor invoked `walk()`
// (typically MainActor); Phase 7's TB walker + display resolver
// would push that visibly under load.
//
// `@MainActor` annotation kept — the public `walk()` returns to
// MainActor before its [Host] result lands so consumers (PortGraph,
// AppDelegate) don't have to re-hop. The IOKit traversal happens on
// `IOKitQueue.shared`'s serial executor via `await`.

import Foundation
import IOKit
import os
import ManifoldKit

@MainActor
final class DiscoveryService {

    // MARK: - Dependencies

    private let usbWalker: USBWalker
    private let tbWalker: ThunderboltWalker
    private let displayResolver: DisplayResolver
    private let builder: PortGraphBuilder
    private let hostMetadataOverride: HostMetadata?

    init(
        usbWalker: USBWalker = USBWalker(),
        tbWalker: ThunderboltWalker = ThunderboltWalker(),
        displayResolver: DisplayResolver = DisplayResolver(),
        builder: PortGraphBuilder = PortGraphBuilder(),
        hostMetadataOverride: HostMetadata? = nil
    ) {
        self.usbWalker = usbWalker
        self.tbWalker = tbWalker
        self.displayResolver = displayResolver
        self.builder = builder
        self.hostMetadataOverride = hostMetadataOverride
    }

    // MARK: - Public API

    /// Walk the IORegistry once and return the resulting `[Host]`
    /// graph. Every IOKit-touching call hops to `IOKitQueue.shared`
    /// (Phase 7 / Reviewer F9). Result returns to MainActor.
    ///
    /// Errors propagate from the underlying walkers. The host-metadata
    /// resolver returns sane defaults rather than throwing.
    func walk() async throws -> [ManifoldKit.Host] {
        // Hop to IOKit queue for every IOKit-touching operation.
        // Each await is a suspension point; the actor's serial
        // executor processes them one at a time, satisfying SPEC §1's
        // "serial DispatchQueue" requirement.
        async let usbAwait = IOKitQueue.shared.usbWalk(walker: usbWalker)
        async let tbAwait = Self.tryTBWalk(via: tbWalker)
        async let displaysAwait = Self.tryResolveDisplays(via: displayResolver)
        let metadata: HostMetadata
        if let override = hostMetadataOverride {
            metadata = override
        } else {
            metadata = await IOKitQueue.shared.resolveHostMetadata()
        }

        // Surface USB errors; TB and Display soft-fail to empty
        // arrays so a missing TB framework on a non-TB Mac (e.g.,
        // older Air) doesn't break discovery entirely.
        let usbSnapshots = try await usbAwait
        let tbSnapshots = await tbAwait
        let displaySnapshots = await displaysAwait

        let host = builder.merge(
            metadata: metadata,
            usbDevices: usbSnapshots,
            tbDevices: tbSnapshots,
            displays: displaySnapshots
        )
        return [host]
    }

    // MARK: - Soft-failing TB / Display walks

    /// Wrap `tbWalk` in a try-and-discard. On Macs with no TB
    /// hardware the matching dictionary returns no matches (empty
    /// result, not an error); on Macs where the TB framework
    /// genuinely throws, log + return empty so USB discovery still
    /// succeeds.
    private static func tryTBWalk(via walker: ThunderboltWalker) async -> [TBDeviceSnapshot] {
        do {
            return try await IOKitQueue.shared.tbWalk(walker: walker)
        } catch {
            Log.discovery.error("TB walk failed: \(String(describing: error), privacy: .public)")
            return []
        }
    }

    /// Same soft-fail policy for the display resolver.
    private static func tryResolveDisplays(via resolver: DisplayResolver) async -> [DisplaySnapshot] {
        do {
            return try await IOKitQueue.shared.resolveDisplays(resolver: resolver)
        } catch {
            Log.discovery.error("Display resolve failed: \(String(describing: error), privacy: .public)")
            return []
        }
    }

    // MARK: - Host metadata resolver (called from IOKitQueue)

    /// Read the local Mac's stable identifier and model from
    /// `IOPlatformExpertDevice`. Called from `IOKitQueue.shared.resolveHostMetadata()`
    /// so it runs on the IOKit serial executor like every other
    /// IOKit-touching call. Pre-Phase-7 callers used the old
    /// `resolveLiveHostMetadata()` static — that's gone; this is the
    /// single live host-metadata path now.
    ///
    /// `nonisolated` because it's invoked from `IOKitQueue` (an
    /// actor whose isolation differs from `DiscoveryService`'s
    /// MainActor). Body touches only IOKit + ProcessInfo, both
    /// thread-safe.
    nonisolated static func resolveLiveHostMetadataOnQueue() -> HostMetadata {
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
            name: ProcessInfo.processInfo.hostName,
            model: resolvedModel ?? "Unknown"
        )
    }

    nonisolated private static func fallbackMetadata() -> HostMetadata {
        HostMetadata(
            id: HostID("UNKNOWN-\(ProcessInfo.processInfo.hostName)"),
            name: ProcessInfo.processInfo.hostName,
            model: "Unknown"
        )
    }
}
