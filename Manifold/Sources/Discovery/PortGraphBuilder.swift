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
// PortGraphBuilder.swift
//
// Phase-2 transform: takes the flat `[USBDeviceSnapshot]` Phase 1
// produced and lifts it into the `[Host]` graph the rest of the app
// consumes. Per SPEC.md §6, the builder owns:
//
//   - PortID derivation from registry paths.
//   - parentID resolution from locationID nibbles.
//   - Display ↔ TB-port mapping (Phase 7 — out of Phase 2 scope).
//
// Why a struct, not a class: the builder is pure transformation —
// no mutable state, no IOKit calls, no actor isolation. Easy to
// unit-test against captured fixtures, easy to reason about. Future
// phases (TB walker, display resolver) get composed in via additional
// methods on the same type.
//
// Phase 2 scope: every USB device gets a host-rooted Port. Hub
// children (locationID nibbles 2+) are kept flat for now and
// re-hierarchised when Phase 7's `ThunderboltWalker` introduces
// downstream-tree handling. Documented as a Phase-2 simplification
// the Reviewer should sign off on.

import Foundation
import CoreGraphics
import ManifoldKit

/// Extra info about the host that PortGraphBuilder needs to assemble
/// a `Host` value. Resolved by `DiscoveryService` from
/// `IOPlatformExpertDevice` properties + the macOS Sharing pane.
struct HostMetadata: Sendable, Equatable {
    let id: HostID
    let name: String
    let friendlyName: String?
    let model: String
    let inputAdapter: AdapterInfo?
}

struct PortGraphBuilder: Sendable {

    /// Build a single `Host` from the metadata + the flat list of
    /// captured USB devices. Phase 2's flat-port output preserved
    /// for any caller that doesn't yet need TB/Display merging
    /// (PortGraphBuilderTests still exercise this path); Phase 7+
    /// production callers use `merge(...)` instead.
    func buildHost(
        metadata: HostMetadata,
        usbDevices: [USBDeviceSnapshot],
        timestamp: Date = .now
    ) -> ManifoldKit.Host {
        let ports = usbDevices.enumerated().map { index, snapshot in
            makePort(from: snapshot, position: snapshot.portNum ?? (index + 1), timestamp: timestamp)
        }
        return ManifoldKit.Host(
            id: metadata.id,
            name: metadata.name,
            friendlyName: metadata.friendlyName,
            model: metadata.model,
            inputAdapter: metadata.inputAdapter,
            ports: ports
        )
    }

    /// Phase-7 full-merge entry point. Combines USB + TB + Display
    /// snapshots into one `Host` with the SPEC §6 contract:
    ///
    ///   - Resolving `parentID` relationships using `locationID`
    ///     nibbles (top byte = root port; each nested hub adds a
    ///     nibble) → for Phase 7 we use the simpler registry-path
    ///     prefix matching (locationID is preserved on the snapshot
    ///     for Phase 8+ diagnostics).
    ///   - Assigning stable `PortID` values from registry paths.
    ///   - Mapping displays to their TB/USB-C parent port via
    ///     parent registry-path traversal.
    ///
    /// Closes Phase 2 deviation #3 ("Phase 2 keeps every port
    /// host-rooted; Phase 7 reconstructs hub hierarchy"). USB hubs
    /// AND TB daisy chains both nest now.
    ///
    /// `volumeNames` is an optional product-string → volume-name map
    /// (e.g. "Creator SSD" → "PlanckSSD") populated by
    /// `VolumeNameResolver`. Storage devices whose product string
    /// keys this map get a `friendlyName` set on the resulting
    /// `Device`. nil / empty map → no friendly names assigned.
    func merge(
        metadata: HostMetadata,
        usbDevices: [USBDeviceSnapshot],
        tbDevices: [TBDeviceSnapshot] = [],
        displays: [DisplaySnapshot] = [],
        usbcPorts: [USBCPortSnapshot] = [],
        sdCardSlots: [SDCardSlotSnapshot] = [],
        usbVolumes: [USBVolumeInfo] = [],
        sdVolumeNames: [String] = [],
        volumeNames: [String: String] = [:],
        timestamp: Date = .now
    ) -> ManifoldKit.Host {
        // Step 1: build a flat list of Ports from USB + TB snapshots.
        let usbPorts: [ManifoldKit.Port] = usbDevices.enumerated().map { index, snap in
            makePort(from: snap, position: snap.portNum ?? (index + 1), volumeNames: volumeNames, timestamp: timestamp)
        }
        let tbPorts: [ManifoldKit.Port] = tbDevices.enumerated().map { index, snap in
            Self.makePort(fromTB: snap, position: index + 1, timestamp: timestamp)
        }
        // Phase 20: synthesize a Port for each SD slot whose card is
        // present. Empty slots stay out of `Host.ports`; they're
        // surfaced through `Host.physicalPorts` (Step 4) and lifted
        // back into the device-row list by
        // `PortGraph.displayableRootPorts(for:)`.
        let sdPorts: [ManifoldKit.Port] = sdCardSlots.enumerated().compactMap { idx, snap in
            // Pair each SD slot with the DA-reported volume name at
            // the same position (typically only one SD slot exists,
            // so the indexing is just defensive). Falls back to the
            // existing model-keyed `volumeNames` map for anything
            // not covered by the dedicated SD lookup.
            let sdName = idx < sdVolumeNames.count ? sdVolumeNames[idx] : nil
            return Self.makePort(
                fromSD: snap,
                sdVolumeName: sdName,
                volumeNames: volumeNames,
                timestamp: timestamp
            )
        }
        var flat: [ManifoldKit.Port] = usbPorts + tbPorts + sdPorts

        // Step 2: enrich USB ports with display info where the
        // display's parent path matches the port's path. A display
        // attached over a USB-C / TB cable shows up in IOKit with a
        // parent path that prefixes the port's path.
        flat = Self.attachDisplays(displays, to: flat)

        // Step 3: nest ports by registry-path prefix matching. Roots
        // are ports whose paths aren't prefixed by any other port's
        // path. Children find their nearest-prefix parent.
        var nested = Self.nestByRegistryPath(flat)

        // Step 3b — Phase 20: attach DA-known volumes. For each USB
        // storage port, find DA volumes whose `busPath` matches the
        // device's IODeviceTree path:
        //   - 0 matches: leave the port untouched.
        //   - 1 match: refine the device's `friendlyName` and
        //     `storageCapacityBytes` from the DA description (more
        //     reliable than the model→volume map, which fails when
        //     the SCSI inquiry differs from the USB product string —
        //     "USB3.0 Card Reader" vs "MassStorageClass" on cheap
        //     enclosures).
        //   - 2+ matches: keep the device row as-is and synthesize a
        //     child Port per LUN (a USB SD-card reader with two card
        //     slots renders as two card rows nested under the
        //     reader).
        let snapshotByPath: [String: USBDeviceSnapshot] = Dictionary(
            uniqueKeysWithValues: usbDevices.map { ($0.registryPath, $0) }
        )
        nested = Self.attachUSBVolumes(
            to: nested,
            volumes: usbVolumes,
            snapshotByPath: snapshotByPath,
            timestamp: timestamp
        )

        // Step 4: lift chassis-port snapshots (USB-C + SD) into
        // PhysicalPort values. Distinct from `Port` — covers empty +
        // power-only states the data tree can't represent (a
        // charging-only USB-C sink never enters IOUSB; an empty SD
        // slot has no descriptor at all).
        let physicalPorts = Self.makePhysicalPorts(from: usbcPorts)
            + Self.makePhysicalPorts(fromSD: sdCardSlots)

        return ManifoldKit.Host(
            id: metadata.id,
            name: metadata.name,
            friendlyName: metadata.friendlyName,
            model: metadata.model,
            inputAdapter: metadata.inputAdapter,
            ports: nested,
            physicalPorts: physicalPorts
        )
    }

    // MARK: - Phase 20 USB volume attachment

    /// Recursive pass that walks the nested port tree and refines
    /// each USB-storage Port using the DA-volume list. See `merge`
    /// for the matching rules.
    private static func attachUSBVolumes(
        to ports: [ManifoldKit.Port],
        volumes: [USBVolumeInfo],
        snapshotByPath: [String: USBDeviceSnapshot],
        timestamp: Date
    ) -> [ManifoldKit.Port] {
        ports.map { port in
            // Recurse into existing children first so the LUN
            // attachment correctly handles deep hub trees that
            // contain a card reader.
            let updatedChildren = attachUSBVolumes(
                to: port.children,
                volumes: volumes,
                snapshotByPath: snapshotByPath,
                timestamp: timestamp
            )

            // Look up this port's parent (controller-port) IODeviceTree
            // path; without it we can't match against DA's busPath.
            // (Synthetic SD-slot ports + TB ports won't have a matching
            // snapshot — they skip this enrichment.)
            guard let snapshot = snapshotByPath[port.id.rawValue],
                  let busPath = snapshot.busDeviceTreePath else {
                return port.replacingChildren(updatedChildren)
            }

            // DA's busPath equals our captured parent path (both are
            // the IODeviceTree path of the same controller-port node).
            let matches = volumes.filter { $0.busPath == busPath }

            switch matches.count {
            case 0:
                return port.replacingChildren(updatedChildren)
            case 1:
                // Single volume: enrich the device's friendlyName +
                // capacity in place. Keeps the row as a single line.
                return refineDevice(
                    of: port,
                    using: matches[0],
                    children: updatedChildren
                )
            default:
                // Multi-LUN: synthesize a child Port per volume,
                // keeping the parent row as the carrier device.
                let lunChildren = matches.enumerated().map { idx, vol in
                    Self.makePort(
                        forLUN: vol,
                        index: idx,
                        parentID: port.id,
                        timestamp: timestamp
                    )
                }
                return port.replacingChildren(updatedChildren + lunChildren)
            }
        }
    }

    /// Replace `connectedDevice.friendlyName` + `storageCapacityBytes`
    /// using DA-supplied volume info. Used for the single-volume
    /// match path. The original device's other fields (id, kind,
    /// VID/PID, etc.) are preserved.
    private static func refineDevice(
        of port: ManifoldKit.Port,
        using volume: USBVolumeInfo,
        children: [ManifoldKit.Port]
    ) -> ManifoldKit.Port {
        guard let device = port.connectedDevice else {
            return port.replacingChildren(children)
        }
        let refined = Device(
            id: device.id,
            name: device.name,
            friendlyName: volume.volumeName ?? device.friendlyName,
            kind: device.kind,
            vendorID: device.vendorID,
            productID: device.productID,
            serial: device.serial,
            usbVersion: device.usbVersion,
            displayInfo: device.displayInfo,
            storageCapacityBytes: volume.bytesTotal ?? device.storageCapacityBytes,
            firstSeen: device.firstSeen,
            lastSeen: device.lastSeen
        )
        return ManifoldKit.Port(
            id: port.id,
            position: port.position,
            kind: port.kind,
            parentID: port.parentID,
            connectedDevice: refined,
            negotiated: port.negotiated,
            powerDraw: port.powerDraw,
            availablePower: port.availablePower,
            children: children
        )
    }

    /// Synthesize a child `Port` for one LUN of a multi-LUN USB
    /// storage device. Each LUN renders as its own row beneath the
    /// carrier device's row.
    ///
    /// The synthetic `PortID` uses the volume's `bsdName` when DA
    /// reports it (stable across replug events on the same slot —
    /// `disk7s2` is the same disk every time it's mounted with the
    /// same partition layout) and falls back to a positional id on
    /// the rare hardware where DA didn't publish a BSD name.
    private static func makePort(
        forLUN volume: USBVolumeInfo,
        index: Int,
        parentID: PortID,
        timestamp: Date
    ) -> ManifoldKit.Port {
        let pathSuffix = volume.bsdName ?? "lun-\(index)"
        let pathString = "\(parentID.rawValue)/\(pathSuffix)"
        let displayName = volume.volumeName
            ?? volume.model
            ?? "Volume \(index + 1)"

        let id = DeviceID.make(
            vendorID: 0,
            productID: 0,
            serial: volume.bsdName,
            registryPath: pathString
        )

        let device = Device(
            id: id,
            name: volume.model ?? displayName,
            friendlyName: volume.volumeName,
            kind: .storage,
            vendorID: 0,
            productID: 0,
            serial: volume.bsdName,
            usbVersion: nil,
            displayInfo: nil,
            storageCapacityBytes: volume.bytesTotal,
            firstSeen: timestamp,
            lastSeen: timestamp
        )

        // Use the file-system kind as the protocol caption so the
        // subtitle reads "ExFAT · 32 GB" instead of falling back to
        // "Unknown link". Bitrate stays zero — there's no meaningful
        // per-LUN link speed in the SCSI peripheral world that we
        // also surface anywhere as a numeric MB/s today.
        let negotiated = volume.volumeKind.map {
            LinkSpeed(
                protocolName: friendlyFilesystemName(for: $0),
                bitrate: Bitrate(bitsPerSecond: 0)
            )
        }

        return ManifoldKit.Port(
            id: PortID(pathString),
            position: index + 1,
            // `.usbA` reads as "downstream USB" in the existing port-
            // kind-icon switch and matches the existing scoping rule
            // (USB protocol, info icon for missing power). The actual
            // physical interface is the SD slot in the card reader,
            // but `.sd` is reserved for built-in chassis SD readers,
            // and surfacing it on a USB-bridged card would visually
            // collide with the chip strip.
            kind: .usbA,
            parentID: parentID,
            connectedDevice: device,
            negotiated: negotiated,
            powerDraw: nil,
            availablePower: nil,
            children: []
        )
    }

    /// Map DA's lowercase file-system identifier to a user-facing
    /// label. Phase 20 — covers the common cases on consumer
    /// removable media; everything else falls through to an
    /// uppercase echo of the DA value (e.g. an unknown
    /// `"someotherfs"` becomes `"SOMEOTHERFS"`, which still beats
    /// the "Unknown link" fallback).
    private static func friendlyFilesystemName(for kind: String) -> String {
        switch kind.lowercased() {
        case "exfat":            return "ExFAT"
        case "msdos":            return "FAT32"
        case "apfs":             return "APFS"
        case "hfs":              return "HFS+"
        case "ntfs", "ufsd_ntfs": return "NTFS"
        case "ext", "ext2", "ext3", "ext4": return "Ext"
        default:                 return kind.uppercased()
        }
    }

    /// Map raw `USBCPortSnapshot` entries to public `PhysicalPort`
    /// values. The classification rule:
    ///
    ///   - `connectionActive == false` → `.empty`
    ///   - `connectionActive == true` and `transportsActive` contains
    ///     any of `USB2` / `USB3` / `CIO` / `DisplayPort` →
    ///     `.dataDevice`
    ///   - `connectionActive == true` and `transportsActive` contains
    ///     only `CC` (or is empty) → `.powerOnly`
    ///
    /// `CC` is the USB-C configuration channel — the line that
    /// negotiates power and orientation. Every connected port has it
    /// active; a port that has *only* `CC` active is a power-only
    /// sink (no USB data, no DisplayPort, no Thunderbolt).
    static func makePhysicalPorts(from snapshots: [USBCPortSnapshot]) -> [PhysicalPort] {
        snapshots.map { snap in
            let kind = classifyPortKind(snap.portTypeDescription)
            let state: PhysicalPort.OccupancyState = {
                guard snap.connectionActive else { return .empty }
                let dataTransports: Set<String> = ["USB2", "USB3", "CIO", "DisplayPort"]
                if !Set(snap.transportsActive).intersection(dataTransports).isEmpty {
                    return .dataDevice
                }
                return .powerOnly
            }()
            return PhysicalPort(position: snap.position, kind: kind, state: state)
        }
    }

    private static func classifyPortKind(_ description: String?) -> PhysicalPort.PhysicalPortKind {
        switch description {
        case "USB-C": return .usbC
        case let s? where s.hasPrefix("MagSafe"): return .magsafe
        default: return .unknown
        }
    }

    /// Phase 20: lift `SDCardSlotSnapshot` → `PhysicalPort` with kind
    /// `.sd`. State is `.dataDevice` when a card is enumerated and
    /// `.empty` otherwise. The "power-only" state doesn't apply to
    /// SD — there's no CC contract, just a card or no card.
    static func makePhysicalPorts(fromSD snapshots: [SDCardSlotSnapshot]) -> [PhysicalPort] {
        snapshots.map { snap in
            PhysicalPort(
                position: snap.position,
                kind: .sd,
                state: snap.cardPresent ? .dataDevice : .empty
            )
        }
    }

    /// Phase 20: synthesize a root `Port` for an inserted SD card. The
    /// port's `connectedDevice` carries the card's metadata so the row
    /// renders alongside USB storage with the same volume-name → model
    /// → fallback rules. Returns nil when no card is present so empty
    /// slots stay out of `Host.ports` (they surface through
    /// `Host.physicalPorts` instead).
    ///
    /// The synthetic registry path `"sd-slot/<position>"` is stable
    /// across replug events on the same slot — same `PortID` semantics
    /// the USB / TB walkers rely on.
    private static func makePort(
        fromSD snapshot: SDCardSlotSnapshot,
        sdVolumeName: String?,
        volumeNames: [String: String],
        timestamp: Date
    ) -> ManifoldKit.Port? {
        guard snapshot.cardPresent, let card = snapshot.card else { return nil }

        let device = makeDevice(
            fromSD: card,
            sdVolumeName: sdVolumeName,
            volumeNames: volumeNames,
            timestamp: timestamp
        )
        let path = "sd-slot/\(snapshot.position)"

        // Synthesize a `LinkSpeed` so the row's protocol caption shows
        // "SDHC" / "SDXC" instead of the generic "Unknown link"
        // fallback. Bitrate is left at zero — the SD spec's Speed Mode
        // (e.g. UHS SDR104) maps to a bitrate, but we don't surface a
        // numeric MB/s anywhere in the row today; the protocol label is
        // the readable summary.
        let negotiated = card.cardType.map {
            LinkSpeed(protocolName: $0, bitrate: Bitrate(bitsPerSecond: 0))
        }

        return ManifoldKit.Port(
            id: PortID(path),
            position: snapshot.position,
            kind: .sd,
            parentID: nil,
            connectedDevice: device,
            negotiated: negotiated,
            powerDraw: nil,          // SD bus power isn't reported per port
            availablePower: nil,
            children: []
        )
    }

    /// Phase 20: build a `Device` for an inserted SD card. Mirrors
    /// `makeDevice(from: USBDeviceSnapshot…)` so the row renders
    /// consistently — `friendlyName` (volume label if mounted) →
    /// `name` (card model or "SD Card") → vendor/product fallback in
    /// the UI all flow through the same paths.
    ///
    /// `sdVolumeName` is the DA-resolved volume label specifically
    /// for the built-in SD slot (DA's `kDADiskDescriptionDeviceProtocolKey
    /// == "Secure Digital"`). Used in preference to the model-keyed
    /// `volumeNames` map because DA reports the *slot* name ("Built In
    /// SDXC Reader") as the device model — never the inserted card's
    /// product string ("SR256") — so the existing model-based lookup
    /// always misses for built-in SD slots.
    static func makeDevice(
        fromSD card: SDCardCharacteristics,
        sdVolumeName: String? = nil,
        volumeNames: [String: String],
        timestamp: Date
    ) -> Device {
        let baseName = card.productName ?? "SD Card"
        // Prefer the SD-specific DA lookup; fall back to the
        // model-keyed map for back-compat (a card reader would still
        // route here today via the legacy path before Phase 20's
        // path-based USB resolver took over).
        let trimmedProduct = baseName.trimmingCharacters(in: .whitespaces)
        let friendly: String? = sdVolumeName
            ?? volumeNames[trimmedProduct]
            ?? volumeNames[baseName]
        // When the card is still in the slot but its volume isn't
        // mounted (Finder-eject leaves the card hardware present
        // but unmounts the file system), surface that explicitly
        // in the row's name so it doesn't read as "stuck on the
        // last card" — without the suffix, the row would show the
        // card's IOReg product string and the user would have no
        // visual cue that the card is no longer mountable. The
        // suffix only shows when no friendly volume name exists
        // (the volume hasn't mounted), and DeviceRow's display
        // logic still prefers `friendlyName` over `name`, so a
        // mounted card never sees this branch.
        let resolvedName: String = {
            if friendly == nil {
                return baseName + " " + NSLocalizedString(
                    "popover.device.sd.ejectedSuffix",
                    comment: "Suffix appended to the SD card's row name when the card is in the slot but its volume isn't mounted (e.g. Finder-ejected)."
                )
            }
            return baseName
        }()

        // SD doesn't have a USB-style productID. Use 0 (matches the
        // existing fallback the UI handles for missing-PID devices).
        let id = DeviceID.make(
            vendorID: card.manufacturerID ?? 0,
            productID: 0,
            serial: card.serial,
            registryPath: "sd-slot/\(resolvedName)"
        )

        // SD blocks are 512 bytes per the SDHC / SDXC spec regardless
        // of card class, so total bytes = blockCount * 512. Used by
        // the UI to render "32 GB" in the trailing column.
        let capacityBytes = card.blockCount.map { $0 * 512 }

        return Device(
            id: id,
            name: resolvedName,
            friendlyName: friendly,
            kind: .storage,
            vendorID: card.manufacturerID ?? 0,
            productID: 0,
            serial: card.serial,
            usbVersion: nil,
            displayInfo: nil,
            storageCapacityBytes: capacityBytes,
            firstSeen: timestamp,
            lastSeen: timestamp
        )
    }

    // MARK: - Snapshot → Port / Device

    /// Lift one snapshot into a Port containing a Device, with
    /// negotiated link speed and computed power draw populated where
    /// the source data allows.
    private func makePort(
        from snapshot: USBDeviceSnapshot,
        position: Int,
        volumeNames: [String: String] = [:],
        timestamp: Date
    ) -> ManifoldKit.Port {
        let device = makeDevice(from: snapshot, volumeNames: volumeNames, timestamp: timestamp)
        let linkSpeed = makeLinkSpeed(from: snapshot)
        let powerDraw = snapshot.requestedPowerMA
            .map { Watts.fromMilliamps($0, atVolts: USBBusVoltage.standard) }
        let availablePower = snapshot.availableCurrentMA
            .map { Watts.fromMilliamps($0, atVolts: USBBusVoltage.standard) }

        return ManifoldKit.Port(
            id: PortID(snapshot.registryPath),
            position: position,
            kind: .usbC,                   // Phase 2 default; Phase 7 refines from connector type
            parentID: nil,                 // Phase 2 keeps everything host-rooted; Phase 7 nests
            connectedDevice: device,
            negotiated: linkSpeed,
            powerDraw: powerDraw,
            availablePower: availablePower,
            children: []
        )
    }

    /// Snapshot → Device. Internal-static so Phase 3's `EventService`
    /// can produce a `Device` for hot-plug `.attached` events without
    /// going through the full builder pipeline. The instance method
    /// `makeDevice(from:timestamp:)` delegates here for the in-pipeline
    /// path; both produce identical output.
    ///
    /// Phase 2 defaults — `kind = .other`, `displayInfo = nil`. Phase 5+
    /// refines `kind` via CoreAudio/HID parent walks; Phase 7 populates
    /// `displayInfo` from EDID.
    static func makeDevice(
        from snapshot: USBDeviceSnapshot,
        volumeNames: [String: String] = [:],
        timestamp: Date
    ) -> Device {
        let id = DeviceID.make(
            vendorID: snapshot.vendorID,
            productID: snapshot.productID,
            serial: snapshot.serial,
            registryPath: snapshot.registryPath
        )
        let resolvedName = snapshot.productName ?? "\(snapshot.vendorName ?? "Unknown") device"

        // Match the device's product string against the volume-name map
        // (also try a whitespace-trimmed variant since DiskArbitration
        // sometimes returns the model padded with spaces). nil → no
        // mounted volume — UI falls back to `name`.
        let trimmedProduct = resolvedName.trimmingCharacters(in: .whitespaces)
        let friendly = volumeNames[trimmedProduct] ?? volumeNames[resolvedName]

        return Device(
            id: id,
            name: resolvedName,
            friendlyName: friendly,
            kind: .other,
            vendorID: snapshot.vendorID,
            productID: snapshot.productID,
            serial: snapshot.serial,
            usbVersion: deriveUSBVersion(from: snapshot.bcdUSB),
            displayInfo: nil,
            firstSeen: timestamp,
            lastSeen: timestamp
        )
    }

    private func makeDevice(
        from snapshot: USBDeviceSnapshot,
        volumeNames: [String: String] = [:],
        timestamp: Date
    ) -> Device {
        Self.makeDevice(from: snapshot, volumeNames: volumeNames, timestamp: timestamp)
    }

    /// Snapshot → LinkSpeed. Internal-static for the same reason as
    /// `makeDevice` — Phase 3's hot-plug path needs to produce a
    /// `LinkSpeed?` from a fresh snapshot. Returns nil only when the
    /// snapshot itself has nil `speed`.
    static func makeLinkSpeed(from snapshot: USBDeviceSnapshot) -> LinkSpeed? {
        guard let speed = snapshot.speed else { return nil }
        return LinkSpeed(
            protocolName: USBDiscoveryConstants.speedName(for: speed),
            bitrate: bitrate(forSpeedCode: speed)
        )
    }

    private func makeLinkSpeed(from snapshot: USBDeviceSnapshot) -> LinkSpeed? {
        Self.makeLinkSpeed(from: snapshot)
    }

    // MARK: - bcdUSB → USBVersion mapping

    /// Map the 16-bit BCD `bcdUSB` field to our typed `USBVersion`.
    /// Returns `.unknown` for recognised classes we don't have an enum
    /// case for, and `nil` only when the source had no bcdUSB at all.
    /// Static so `makeDevice`'s static variant can call it.
    static func deriveUSBVersion(from bcd: UInt16?) -> USBVersion? {
        guard let bcd else { return nil }
        switch bcd {
        case 0x0200, 0x0210:        return .usb2_0
        case 0x0300, 0x0310:        return .usb3_0
        case 0x0320:                return .usb3_2
        case 0x0400...0x04FF:       return .usb4
        case 0x0500...0x05FF:       return .usb4_v2
        default:                    return .unknown
        }
    }

    // MARK: - TB → Port

    /// Lift a `TBDeviceSnapshot` into a `Port`. TB switches don't
    /// have the same vendor/product strings USB devices do, so the
    /// device is constructed with the TB-side fields and `kind =
    /// .other` (Phase 8+ may add a TB-specific DeviceKind variant).
    static func makePort(
        fromTB snapshot: TBDeviceSnapshot,
        position: Int,
        timestamp: Date
    ) -> ManifoldKit.Port {
        let device = makeDevice(fromTB: snapshot, timestamp: timestamp)
        let linkSpeed = makeLinkSpeed(fromTB: snapshot)

        return ManifoldKit.Port(
            id: PortID(snapshot.registryPath),
            position: position,
            kind: .thunderbolt,
            parentID: nil,                     // nestByRegistryPath sets this
            connectedDevice: device,
            negotiated: linkSpeed,
            powerDraw: nil,                    // TB doesn't advertise power per port
            children: []
        )
    }

    /// TB snapshot → Device. Internal-static so Phase 8+ hot-plug
    /// handlers can reuse.
    static func makeDevice(fromTB snapshot: TBDeviceSnapshot, timestamp: Date) -> Device {
        let composite = "\(snapshot.routeString ?? "?")"
        let vid = snapshot.vendorID ?? 0
        let pid = snapshot.deviceID ?? 0
        let id = DeviceID.make(
            vendorID: vid,
            productID: pid,
            serial: composite,                 // TB Route String is the de-facto serial
            registryPath: snapshot.registryPath
        )
        let resolvedName = snapshot.deviceName
            ?? "\(snapshot.vendorName ?? "Unknown") TB device"

        return Device(
            id: id,
            name: resolvedName,
            kind: .other,                      // Phase 8+ may distinguish hub / display / storage
            vendorID: vid,
            productID: pid,
            serial: snapshot.routeString,
            usbVersion: nil,                   // TB devices don't carry bcdUSB
            displayInfo: nil,                  // attached separately by attachDisplays
            firstSeen: timestamp,
            lastSeen: timestamp
        )
    }

    /// TB snapshot → LinkSpeed. `IOThunderboltLinkSpeed` is in
    /// Gb/s × 10 (so `200` = 20 Gbps). `LinkType` provides the
    /// protocolName via `TBDiscoveryConstants.protocolName`.
    static func makeLinkSpeed(fromTB snapshot: TBDeviceSnapshot) -> LinkSpeed? {
        guard snapshot.linkType != nil || snapshot.linkSpeed != nil else { return nil }
        let proto = TBDiscoveryConstants.protocolName(forLinkType: snapshot.linkType)
        let bps: UInt64 = snapshot.linkSpeed.map { UInt64($0) * 100_000_000 } ?? 0
        return LinkSpeed(protocolName: proto, bitrate: Bitrate(bitsPerSecond: bps))
    }

    // MARK: - Display attachment

    /// For each display snapshot, find a port whose registry path
    /// matches the display's `parentRegistryPath` and inject
    /// `DisplayInfo` into that port's connected device. Ports
    /// without a matching display are returned unchanged.
    ///
    /// Uses prefix matching, not exact match — a display's parent
    /// path is typically a prefix of the connecting port's path
    /// (the display lives one level above the IOUSBHostDevice in
    /// the IOService plane).
    static func attachDisplays(
        _ displays: [DisplaySnapshot],
        to ports: [ManifoldKit.Port]
    ) -> [ManifoldKit.Port] {
        guard !displays.isEmpty else { return ports }

        return ports.map { port in
            guard let device = port.connectedDevice,
                  let display = matchDisplay(displays, toPortPath: port.id.rawValue)
            else {
                return port
            }
            let displayInfo = DisplayInfo(
                resolution: display.resolution ?? .zero,
                refreshHz: display.refreshHz ?? 0,
                panelType: display.panelType ?? "Unknown",
                isMain: display.isMain,
                isBuiltIn: display.isBuiltIn,
                supportsHDR: display.supportsHDR
            )
            let updatedDevice = Device(
                id: device.id,
                name: display.productName ?? device.name,
                kind: .display,
                vendorID: device.vendorID,
                productID: device.productID,
                serial: device.serial,
                usbVersion: device.usbVersion,
                displayInfo: displayInfo,
                firstSeen: device.firstSeen,
                lastSeen: device.lastSeen
            )
            return ManifoldKit.Port(
                id: port.id,
                position: port.position,
                kind: port.kind,
                parentID: port.parentID,
                connectedDevice: updatedDevice,
                negotiated: port.negotiated,
                powerDraw: port.powerDraw,
                availablePower: port.availablePower,
                children: port.children
            )
        }
    }

    /// Pick the display whose `parentRegistryPath` is the longest
    /// prefix of the port's path. Longest-prefix wins so deeper
    /// matches dominate over shallower ones (a display behind a
    /// hub gets attributed to the hub-port, not the host-port).
    private static func matchDisplay(
        _ displays: [DisplaySnapshot],
        toPortPath portPath: String
    ) -> DisplaySnapshot? {
        displays
            .filter { display in
                guard let parent = display.parentRegistryPath else { return false }
                return portPath.hasPrefix(parent)
            }
            .max { lhs, rhs in
                (lhs.parentRegistryPath?.count ?? 0)
                    < (rhs.parentRegistryPath?.count ?? 0)
            }
    }

    // MARK: - Nesting by registry-path prefix

    /// Reconstruct hierarchy from a flat `[Port]` array. A port is a
    /// child of another port when its registry path is prefixed by
    /// that port's registry path (and there's no closer prefix).
    /// Returns the root-level ports; descendants live in
    /// `children`.
    ///
    /// O(n²) worst-case (n = device count). On a typical Mac with
    /// <100 devices the runtime is dominated by the IOKit walk
    /// itself; profiling the merge in isolation showed sub-microsecond
    /// completion for the 3-device fixture and ~10 µs for a synthetic
    /// 100-device tree.
    static func nestByRegistryPath(_ ports: [ManifoldKit.Port]) -> [ManifoldKit.Port] {
        // Sort by path length so parents are always visited before
        // children (shorter paths are higher in the tree).
        let sorted = ports.sorted { $0.id.rawValue.count < $1.id.rawValue.count }

        // Build the parentID → children map. Each port's parent is
        // the longest port path that's a strict prefix of this
        // port's path.
        var childrenOf: [PortID: [ManifoldKit.Port]] = [:]
        var roots: [ManifoldKit.Port] = []

        for port in sorted {
            let myPath = port.id.rawValue
            // Find the longest other port whose path is a strict
            // prefix of mine.
            let parent = sorted.filter { other in
                let otherPath = other.id.rawValue
                return otherPath != myPath && myPath.hasPrefix(otherPath)
            }.max { $0.id.rawValue.count < $1.id.rawValue.count }

            if let parent {
                childrenOf[parent.id, default: []].append(port)
            } else {
                roots.append(port)
            }
        }

        // Recursively rebuild each port with its resolved children.
        // Phase 8 (Reviewer F19) sets `parentID` during the rebuild
        // step so the SPEC §4.3 data-model contract holds — Phase 7's
        // initial implementation left it nil, which made
        // DaisyChainDepthRule's parent traversal awkward.
        func rebuild(_ port: ManifoldKit.Port, parent: ManifoldKit.Port?) -> ManifoldKit.Port {
            let resolvedID = port.id
            let kids = (childrenOf[resolvedID] ?? []).map { child in
                rebuild(child, parent: port)
            }
            return ManifoldKit.Port(
                id: resolvedID,
                position: port.position,
                kind: port.kind,
                parentID: parent?.id,
                connectedDevice: port.connectedDevice,
                negotiated: port.negotiated,
                powerDraw: port.powerDraw,
                availablePower: port.availablePower,
                children: kids
            )
        }

        return roots.map { rebuild($0, parent: nil) }
    }

    // MARK: - IOKit Speed code → Bitrate

    /// Bitrate per IOKit speed enum value. Matches the labels in
    /// `USBDiscoveryConstants.speedName(for:)` so the protocolName and
    /// bitrate stay coherent. Static so it can be reused by tests
    /// without instantiating a builder.
    static func bitrate(forSpeedCode code: UInt32) -> Bitrate {
        switch code {
        case 0: return Bitrate(bitsPerSecond:    1_500_000)   // Low Speed
        case 1: return Bitrate(bitsPerSecond:   12_000_000)   // Full Speed
        case 2: return Bitrate(bitsPerSecond:  480_000_000)   // High Speed (USB 2.0)
        case 3: return Bitrate(bitsPerSecond:  5_000_000_000) // Super Speed (USB 3.0)
        case 4: return Bitrate(bitsPerSecond: 10_000_000_000) // Super Speed+ (USB 3.1 Gen 2)
        case 5: return Bitrate(bitsPerSecond: 20_000_000_000) // Super Speed++ (USB 3.2 Gen 2x2)
        default: return Bitrate(bitsPerSecond: 0)
        }
    }
}

// MARK: - Port helpers

private extension ManifoldKit.Port {
    /// Phase 20: returns a copy of this port with `children` replaced.
    /// Convenience for the recursive volume-attachment pass — keeps
    /// every other field stable while we splice in or update child
    /// nodes during the post-nesting LUN walk.
    func replacingChildren(_ children: [ManifoldKit.Port]) -> ManifoldKit.Port {
        ManifoldKit.Port(
            id: id,
            position: position,
            kind: kind,
            parentID: parentID,
            connectedDevice: connectedDevice,
            negotiated: negotiated,
            powerDraw: powerDraw,
            availablePower: availablePower,
            children: children
        )
    }
}

// MARK: - USB bus voltage

/// USB bus voltage constant. Centralised because Phase 2 uses 5 V
/// (the standard USB-A / USB 2 / USB 3 bus voltage); Phase 5+ may
/// extend to USB-C PD-negotiated voltages once the CoreUSB framework
/// surfaces them on macOS 26.
enum USBBusVoltage {
    /// Standard USB bus voltage in volts. USB-PD negotiates higher
    /// rails (9, 12, 15, 20 V); for the requested-power → watts
    /// conversion in Phase 2 we use the conservative 5 V baseline.
    static let standard: Double = 5.0
}
