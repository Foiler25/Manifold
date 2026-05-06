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
import SystemConfiguration
import os
import ManifoldKit

@MainActor
final class DiscoveryService {

    // MARK: - Dependencies

    private let usbWalker: USBWalker
    private let tbWalker: ThunderboltWalker
    private let displayResolver: DisplayResolver
    private let usbcPortWalker: USBCPortWalker
    private let sdCardSlotWalker: SDCardSlotWalker
    private let builder: PortGraphBuilder
    private let hostMetadataOverride: HostMetadata?

    init(
        usbWalker: USBWalker = USBWalker(),
        tbWalker: ThunderboltWalker = ThunderboltWalker(),
        displayResolver: DisplayResolver = DisplayResolver(),
        usbcPortWalker: USBCPortWalker = USBCPortWalker(),
        sdCardSlotWalker: SDCardSlotWalker = SDCardSlotWalker(),
        builder: PortGraphBuilder = PortGraphBuilder(),
        hostMetadataOverride: HostMetadata? = nil
    ) {
        self.usbWalker = usbWalker
        self.tbWalker = tbWalker
        self.displayResolver = displayResolver
        self.usbcPortWalker = usbcPortWalker
        self.sdCardSlotWalker = sdCardSlotWalker
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
        async let usbcPortsAwait = Self.tryUSBCPortWalk(via: usbcPortWalker)
        async let sdCardSlotsAwait = Self.trySDCardSlotWalk(via: sdCardSlotWalker)
        let metadata: HostMetadata
        if let override = hostMetadataOverride {
            metadata = override
        } else {
            metadata = await IOKitQueue.shared.resolveHostMetadata()
        }

        // Surface USB errors; TB, Display, USB-C-port, and SD-slot
        // walks soft-fail to empty arrays so a missing class on
        // Intel / older Macs doesn't break discovery entirely.
        let usbSnapshots = try await usbAwait
        let tbSnapshots = await tbAwait
        let displaySnapshots = await displaysAwait
        let usbcPortSnapshots = await usbcPortsAwait
        let sdCardSlotSnapshots = await sdCardSlotsAwait

        // Look up friendly volume names for any mounted USB / TB
        // storage device. Cheap (DiskArbitration enumeration of a
        // handful of mounted volumes) so we run it on every walk;
        // hot-plugging an SSD between walks reliably picks up the new
        // volume name after the next sample.
        let volumeNames = VolumeNameResolver.mountedVolumeNamesByDeviceModel()
        // Phase 20: also pull the per-disk DA records (with bus path,
        // media path, capacity). PortGraphBuilder uses these to
        // expand multi-LUN USB devices (a card reader with two card
        // slots becomes a parent row + two LUN children) and to
        // resolve volume names on devices whose SCSI inquiry doesn't
        // match the USB product string.
        let usbVolumes = VolumeNameResolver.mountedUSBVolumes()
        Log.discovery.debug(
            "walk: usbDevices=\(usbSnapshots.count, privacy: .public) usbVolumes=\(usbVolumes.count, privacy: .public)"
        )

        let host = builder.merge(
            metadata: metadata,
            usbDevices: usbSnapshots,
            tbDevices: tbSnapshots,
            displays: displaySnapshots,
            usbcPorts: usbcPortSnapshots,
            sdCardSlots: sdCardSlotSnapshots,
            usbVolumes: usbVolumes,
            volumeNames: volumeNames
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

    /// Same soft-fail policy for the USB-C chassis-port walker. On
    /// Intel Macs / Apple Silicon variants where
    /// `AppleTCControllerType10` doesn't exist, the matching dict
    /// returns no results — that becomes an empty
    /// `Host.physicalPorts` and the UI hides the section.
    private static func tryUSBCPortWalk(via walker: USBCPortWalker) async -> [USBCPortSnapshot] {
        do {
            return try await IOKitQueue.shared.usbcPortWalk(walker: walker)
        } catch {
            Log.discovery.error("USB-C port walk failed: \(String(describing: error), privacy: .public)")
            return []
        }
    }

    /// Phase 20: same soft-fail policy for the SD-card-slot walker.
    /// Most Macs don't have an internal SD reader (M-series Air,
    /// base 13" Pro, all desktops) — `AppleSDXCSlot` enumerates
    /// empty there, the snapshot list is empty, and no SD UI shows.
    private static func trySDCardSlotWalk(via walker: SDCardSlotWalker) async -> [SDCardSlotSnapshot] {
        do {
            return try await IOKitQueue.shared.sdCardSlotWalk(walker: walker)
        } catch {
            Log.discovery.error("SD card slot walk failed: \(String(describing: error), privacy: .public)")
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
            friendlyName: resolveFriendlyName(),
            model: resolvedModel ?? "Unknown",
            inputAdapter: AdapterPowerReader.currentInputPower()
        )
    }

    nonisolated private static func fallbackMetadata() -> HostMetadata {
        HostMetadata(
            id: HostID("UNKNOWN-\(ProcessInfo.processInfo.hostName)"),
            name: ProcessInfo.processInfo.hostName,
            friendlyName: resolveFriendlyName(),
            model: "Unknown",
            inputAdapter: AdapterPowerReader.currentInputPower()
        )
    }

    /// Read the user-set Computer Name from
    /// `SCDynamicStoreCopyComputerName`. Returns `nil` when the call
    /// fails (the toll-free-bridged String cast can't fail in
    /// practice, but we propagate nil rather than empty so
    /// `Host.displayName` falls back to the bonjour hostname).
    nonisolated private static func resolveFriendlyName() -> String? {
        guard let name = SCDynamicStoreCopyComputerName(nil, nil) as String? else {
            return nil
        }
        return name.isEmpty ? nil : name
    }
}
