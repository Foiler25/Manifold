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
import IOKit

@MainActor
public final class LiquidDetectionWatcher: ObservableObject {
    public struct LiquidDetectionUpdate: Codable, Sendable, Equatable {
        public let portIndex: Int
        public let portType: String
        public let status: LiquidDetectionStatus
    }

    @Published public private(set) var statuses: [LiquidDetectionUpdate] = []

    private var notifyPort: IONotificationPortRef?
    private var addedIterator: io_iterator_t = 0
    private var removedIterator: io_iterator_t = 0

    public init() {}

    public func start() {
        guard notifyPort == nil else { return }
        let port = IONotificationPortCreate(kIOMainPortDefault)
        IONotificationPortSetDispatchQueue(port, DispatchQueue.main)
        notifyPort = port

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let added: IOServiceMatchingCallback = { refcon, iterator in
            guard let refcon else { return }
            let watcher = Unmanaged<LiquidDetectionWatcher>.fromOpaque(refcon).takeUnretainedValue()
            // Capture weakly so that if the watcher is torn down before this
            // task runs, it becomes a no-op rather than touching freed memory.
            Task { @MainActor [weak watcher] in watcher?.handleAdded(iterator) }
        }
        let removed: IOServiceMatchingCallback = { refcon, iterator in
            guard let refcon else { return }
            let watcher = Unmanaged<LiquidDetectionWatcher>.fromOpaque(refcon).takeUnretainedValue()
            Task { @MainActor [weak watcher] in watcher?.handleRemoved(iterator) }
        }

        if IOServiceAddMatchingNotification(
            port,
            kIOMatchedNotification,
            IOServiceMatching("AppleHPMLDCMType2"),
            added,
            selfPtr,
            &addedIterator
        ) == KERN_SUCCESS {
            handleAdded(addedIterator)
        }

        if IOServiceAddMatchingNotification(
            port,
            kIOTerminatedNotification,
            IOServiceMatching("AppleHPMLDCMType2"),
            removed,
            selfPtr,
            &removedIterator
        ) == KERN_SUCCESS {
            handleRemoved(removedIterator)
        }
    }

    public func stop() {
        if addedIterator != 0 { IOObjectRelease(addedIterator); addedIterator = 0 }
        if removedIterator != 0 { IOObjectRelease(removedIterator); removedIterator = 0 }
        if let port = notifyPort {
            IONotificationPortDestroy(port)
            notifyPort = nil
        }
        statuses.removeAll()
    }

    public func refresh() {
        // Build the new list locally and assign once. Mutating the published
        // `statuses` in place (removeAll then re-append) emits a transient empty
        // value that downstream subscribers see as "no ports," causing brief UI
        // flicker on every poll tick. See issue #227.
        var rebuilt: [LiquidDetectionUpdate] = []
        var iter: io_iterator_t = 0
        if IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleHPMLDCMType2"), &iter) == KERN_SUCCESS {
            while case let service = IOIteratorNext(iter), service != 0 {
                if let update = makeUpdate(from: service) {
                    rebuilt.removeAll {
                        $0.portIndex == update.portIndex && $0.portType == update.portType
                    }
                    rebuilt.append(update)
                }
                IOObjectRelease(service)
            }
            IOObjectRelease(iter)
        }
        if rebuilt != statuses { statuses = rebuilt }
    }

    private func handleAdded(_ iterator: io_iterator_t) {
        while case let service = IOIteratorNext(iterator), service != 0 {
            if let update = makeUpdate(from: service) {
                statuses.removeAll {
                    $0.portIndex == update.portIndex && $0.portType == update.portType
                }
                statuses.append(update)
            }
            IOObjectRelease(service)
        }
    }

    private func handleRemoved(_ iterator: io_iterator_t) {
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            func read(_ key: String) -> Any? {
                IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            }
            let portIndex = wcPortIndex(read: read, service: service)
            let portType = wcPortType(read: read, service: service)
            statuses.removeAll {
                $0.portIndex == portIndex && $0.portType == portType
            }
        }
    }

    private func makeUpdate(from service: io_service_t) -> LiquidDetectionUpdate? {
        func read(_ key: String) -> Any? {
            IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        }

        return Self.parseUpdate(
            read: read,
            portIndex: wcPortIndex(read: read, service: service),
            portType: wcPortType(read: read, service: service)
        )
    }

    /// Parse a `LiquidDetectionUpdate` from a property-read closure and
    /// pre-resolved port context. Extracted from `makeUpdate(from:)` so
    /// corpus-replay tests can drive the parse logic without real IOKit services.
    internal nonisolated static func parseUpdate(
        read: (String) -> Any?,
        portIndex: Int,
        portType: String
    ) -> LiquidDetectionUpdate? {
        let state = (read("StateDescription") as? String)
            ?? read("State").map { String(wcInt($0)) }
            ?? "Unknown"
        let status = LiquidDetectionStatus(
            liquidDetected: wcBool(read("LiquidDetected")),
            state: state,
            measurementStatus: wcInt(read("MeasurementStatus")),
            mitigationsEnabled: wcBool(read("MitigationsEnabled"))
        )
        return LiquidDetectionUpdate(
            portIndex: portIndex,
            portType: portType,
            status: status
        )
    }
}
