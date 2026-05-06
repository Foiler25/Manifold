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
// VolumeNameResolver.swift
//
// Looks up the user-set volume name ("PlanckSSD") for each mounted
// USB-attached disk and exposes a lookup map keyed by the underlying
// USB device's product string ("Creator SSD"). Uses DiskArbitration
// because it surfaces both the volume name AND the bus protocol +
// device model in a single description dictionary, avoiding a manual
// IORegistry walk.
//
// Best-effort: a device with no mounted volume (cold-plug stage,
// unmounted disk, encrypted-locked disk) returns nil. Callers must
// fall back to the USB product string.

import Foundation
import DiskArbitration

// MARK: - USBVolumeInfo

/// Phase 20 Sendable projection of one DA-known USB / TB volume.
/// `PortGraphBuilder` matches volumes back to their parent USB
/// device by `busPath` (the `kDADiskDescriptionBusPathKey` —
/// IODeviceTree path of the USB device that owns the disk). Two
/// volumes sharing a `busPath` are LUNs of the same multi-LUN
/// device (a USB SD-card reader exposes each card slot this way).
struct USBVolumeInfo: Sendable, Equatable {

    /// IODeviceTree path of the parent USB device (e.g.
    /// `IODeviceTree:/arm-io/usb-drd1@2280000/usb-drd1-port-ss@01200000`).
    /// Used as the join key against `USBDeviceSnapshot.deviceTreePath`.
    let busPath: String?

    /// IODeviceTree path of the IOMedia node itself, prefixed by
    /// `busPath`. Carries a LUN suffix on multi-LUN devices —
    /// kept around so the synthesizer can derive a stable per-LUN
    /// PortID even when multiple volumes share a `busPath`.
    let mediaPath: String?

    /// BSD device name (e.g. `disk7s2`). Stable identifier for a
    /// mounted partition.
    let bsdName: String?

    /// User-set volume label (e.g. `PlanckSSD`).
    let volumeName: String?

    /// Total media size in bytes, when DA reports it.
    let bytesTotal: UInt64?

    /// SCSI-inquiry model string (e.g. `Creator SSD`,
    /// `MassStorageClass`). Generic for some cheap enclosures, hence
    /// why path-based matching is more reliable than model-based.
    let model: String?

    /// SCSI-inquiry vendor string.
    let vendor: String?

    /// File-system kind from DA (`kDADiskDescriptionVolumeKindKey`),
    /// e.g. `"exfat"`, `"msdos"`, `"apfs"`. Surfaced lowercase
    /// verbatim from DA — `PortGraphBuilder` maps to a friendly
    /// label ("ExFAT", "FAT32", "APFS") for display in the LUN
    /// child's protocol caption.
    let volumeKind: String?
}

enum VolumeNameResolver {

    /// Snapshot the mounted USB / Thunderbolt volumes on the system.
    /// The returned map keys on the device's marketing/product string
    /// (DiskArbitration's `kDADiskDescriptionDeviceModelKey`,
    /// trimmed of trailing whitespace — Apple Silicon's USB stack
    /// often pads the field). Values are the user-set volume names.
    ///
    /// **Multi-LUN devices** (a USB SD-card reader with two card
    /// slots, for example) expose each LUN as a separate DA disk
    /// sharing the same parent device model. Both volumes get
    /// associated with the same key in this map; we concatenate the
    /// volume names with `, ` so the row reads as "Card Reader →
    /// CARD1, CARD2" rather than dropping one of the two on the
    /// floor. (A future phase may split multi-LUN devices into
    /// separate rows; concatenation is the correctness fix for the
    /// current one-row-per-IOUSBHostDevice model.)
    static func mountedVolumeNamesByDeviceModel() -> [String: String] {
        guard let session = DASessionCreate(kCFAllocatorDefault) else {
            return [:]
        }

        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: nil,
            options: []
        ) ?? []

        var result: [String: String] = [:]
        for url in urls {
            guard let disk = DADiskCreateFromVolumePath(
                kCFAllocatorDefault,
                session,
                url as CFURL
            ) else {
                continue
            }
            guard let description = DADiskCopyDescription(disk) as? [String: Any] else {
                continue
            }

            // Filter to bus protocols a USB / TB inspection app cares
            // about. "USB" covers both USB-A and USB-C mass storage;
            // "Thunderbolt" covers TB-native NVMe enclosures. Internal
            // drives ("PCI" / "SATA") get filtered out so we don't
            // re-label the boot disk.
            let proto = description[kDADiskDescriptionDeviceProtocolKey as String] as? String
            guard proto == "USB" || proto == "Thunderbolt" else { continue }

            guard let rawModel = description[kDADiskDescriptionDeviceModelKey as String] as? String,
                  let volumeName = description[kDADiskDescriptionVolumeNameKey as String] as? String else {
                continue
            }
            let model = rawModel.trimmingCharacters(in: .whitespaces)
            guard !model.isEmpty, !volumeName.isEmpty else { continue }

            // Multi-LUN merge: append rather than overwrite when two
            // volumes share a model.
            if let existing = result[model], !existing.contains(volumeName) {
                result[model] = "\(existing), \(volumeName)"
            } else {
                result[model] = volumeName
            }
        }
        return result
    }

    /// Phase 20: enumerate every mounted USB / TB volume, exposing
    /// per-disk metadata (busPath, mediaPath, BSD name, volume name,
    /// size, model, vendor). `PortGraphBuilder` consumes this list
    /// and matches volumes back to their parent USB device by
    /// `busPath` — required for multi-LUN expansion and for
    /// resolving the friendly name on devices whose SCSI-inquiry
    /// model is too generic to match the USB product string (a
    /// common case for cheap card readers, which advertise
    /// `MassStorageClass` to SCSI but `USB3.0 Card Reader` to USB).
    static func mountedUSBVolumes() -> [USBVolumeInfo] {
        guard let session = DASessionCreate(kCFAllocatorDefault) else {
            return []
        }

        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: nil,
            options: []
        ) ?? []

        var result: [USBVolumeInfo] = []
        for url in urls {
            guard let disk = DADiskCreateFromVolumePath(
                kCFAllocatorDefault,
                session,
                url as CFURL
            ) else { continue }
            guard let desc = DADiskCopyDescription(disk) as? [String: Any] else { continue }

            // Same protocol filter as the model-based path: only USB
            // and Thunderbolt. Internal drives and disk images are
            // skipped — they're not interesting to a USB inspector.
            let proto = desc[kDADiskDescriptionDeviceProtocolKey as String] as? String
            guard proto == "USB" || proto == "Thunderbolt" else { continue }

            // `kDADiskDescriptionBusPathKey` is a CFURL on this
            // platform — bridge to its absolute string. The path
            // comes through with the IODeviceTree plane prefix.
            let busPath = (desc[kDADiskDescriptionBusPathKey as String] as? URL)?.absoluteString
                ?? desc[kDADiskDescriptionBusPathKey as String] as? String
            let mediaPath = (desc[kDADiskDescriptionMediaPathKey as String] as? URL)?.absoluteString
                ?? desc[kDADiskDescriptionMediaPathKey as String] as? String

            let info = USBVolumeInfo(
                busPath: busPath,
                mediaPath: mediaPath,
                bsdName: desc[kDADiskDescriptionMediaBSDNameKey as String] as? String,
                volumeName: (desc[kDADiskDescriptionVolumeNameKey as String] as? String)?
                    .nonEmptyOrNil,
                bytesTotal: (desc[kDADiskDescriptionMediaSizeKey as String] as? NSNumber)?.uint64Value,
                model: (desc[kDADiskDescriptionDeviceModelKey as String] as? String)?
                    .trimmingCharacters(in: .whitespaces).nonEmptyOrNil,
                vendor: (desc[kDADiskDescriptionDeviceVendorKey as String] as? String)?
                    .trimmingCharacters(in: .whitespaces).nonEmptyOrNil,
                volumeKind: (desc[kDADiskDescriptionVolumeKindKey as String] as? String)?
                    .trimmingCharacters(in: .whitespaces).nonEmptyOrNil
            )
            result.append(info)
        }
        return result
    }
}

private extension String {
    var nonEmptyOrNil: String? { isEmpty ? nil : self }
}
