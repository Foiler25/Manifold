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

enum VolumeNameResolver {

    /// Snapshot the mounted USB / Thunderbolt volumes on the system.
    /// The returned map keys on the device's marketing/product string
    /// (DiskArbitration's `kDADiskDescriptionDeviceModelKey`,
    /// trimmed of trailing whitespace — Apple Silicon's USB stack
    /// often pads the field). Values are the user-set volume names.
    ///
    /// Two volumes from the same model would collide here; the second
    /// wins. That edge case (e.g. two identical Samsung T7s plugged in)
    /// is rare enough that we accept the simplification rather than
    /// keying on a less-readable identifier like the BSD name.
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

            result[model] = volumeName
        }
        return result
    }
}
