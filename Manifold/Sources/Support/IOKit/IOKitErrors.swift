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
// IOKitErrors.swift
//
// Typed error surface for the IOKit layer. Defined in SPEC.md §5 with
// four cases. Every error path in `IOKitWrapper.swift` and the discovery
// walkers either returns one of these or — for non-fatal "no match"
// situations — returns `nil` / an empty result. We do *not* throw for
// the empty-iterator case; an empty result is a legitimate state of the
// world (no devices plugged in) and not an error.

import Foundation
import IOKit

/// Errors raised by the Manifold IOKit layer.
enum IOKitError: Error, Sendable {

    /// `IOServiceMatching(_:)` returned `nil` for a class name we asked
    /// to match. In practice this only happens when the class name
    /// string is malformed; the kernel does not validate the class name
    /// up front, so this is effectively a programmer error.
    case matchingDictionaryFailed

    /// A registry walk operation returned a non-`KERN_SUCCESS` code.
    /// Carries the kernel return value so logs can decode it.
    case registryWalkFailed(kern_return_t)

    /// Notification subscription (Phase 3+) failed to register. Only
    /// reachable from the events layer; declared here so the IOKit
    /// errors live in one place.
    case notificationRegistrationFailed(kern_return_t)

    /// A property exists but did not bridge to the expected Swift type.
    /// Indicates a kernel ABI surprise (a vendor's class published
    /// `idVendor` as a string, for instance) — worth logging loudly so
    /// we can capture the device in a fixture and add a coercion path.
    case unexpectedPropertyType(key: String, expected: String)
}

extension IOKitError: CustomStringConvertible {
    var description: String {
        switch self {
        case .matchingDictionaryFailed:
            return "IOServiceMatching(_:) returned nil — bad class name"
        case .registryWalkFailed(let code):
            return "IOKit registry walk failed (kern_return_t=\(code))"
        case .notificationRegistrationFailed(let code):
            return "IOKit notification registration failed (kern_return_t=\(code))"
        case .unexpectedPropertyType(let key, let expected):
            return "Property \"\(key)\" did not bridge to \(expected)"
        }
    }
}
