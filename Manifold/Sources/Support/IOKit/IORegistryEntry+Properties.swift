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
// IORegistryEntry+Properties.swift
//
// Typed convenience readers on top of the raw `property(_:of:as:)`
// helper in `IOKitWrapper.swift`. The reasons to centralize these here
// rather than re-typing the bridging at every call site:
//
//   1. The CFType→Swift bridge for a given property is the same
//      everywhere; getting it wrong once is hard to track down.
//   2. Keys are stringly-typed and easy to typo. A single named accessor
//      per property removes that surface.
//   3. Future phases that want to add coercion (e.g. accept a string
//      `idVendor` from a misbehaving driver) only have to change one
//      function.
//
// These helpers are intentionally thin and free-function-style. They are
// not extensions on `IOObject` because `IOObject` is `~Copyable` and
// extensions on non-copyable types are a much more limited surface in
// Swift 6 (no protocol conformances, restricted method shapes). Plain
// functions taking `borrowing IOObject` work everywhere.

import Foundation
import IOKit

/// Read a `UInt16` (such as `idVendor`, `idProduct`, `bcdUSB`).
/// IOKit publishes these as `NSNumber` regardless of the underlying
/// width; we narrow to `UInt16` because the USB spec caps these fields
/// at 16 bits.
func uint16Property(
    _ key: String,
    of entry: borrowing IOObject
) -> UInt16? {
    property(key, of: entry, as: NSNumber.self)?.uint16Value
}

/// Read a `UInt32` (used by `Speed`, `locationID`, `PortNum` in some
/// drivers). Some IOKit properties have widths that vary across kexts;
/// `UInt32` is the safe upper bound for everything Manifold reads here.
func uint32Property(
    _ key: String,
    of entry: borrowing IOObject
) -> UInt32? {
    property(key, of: entry, as: NSNumber.self)?.uint32Value
}

/// Read a signed `Int` (used by `Requested Power`, expressed as
/// milliamps in IOKit). Returns `nil` rather than `0` when missing so
/// callers can distinguish "device did not advertise" from "advertised
/// 0 mA" — a real device descriptor distinction, even if rare.
func intProperty(
    _ key: String,
    of entry: borrowing IOObject
) -> Int? {
    property(key, of: entry, as: NSNumber.self)?.intValue
}

/// Read a `Bool` (e.g. `ConnectionActive` on `AppleTCControllerType10`).
/// IOKit Bools cross the CF bridge as `NSNumber` with `boolValue` ==
/// `true` for `Yes` and `false` for `No`. Returns `nil` rather than
/// `false` when missing so callers can distinguish "not advertised"
/// from "advertised No" — the USB-C port walker uses this to detect
/// schema drift.
func boolProperty(
    _ key: String,
    of entry: borrowing IOObject
) -> Bool? {
    property(key, of: entry, as: NSNumber.self)?.boolValue
}

/// Read a `[String]` (e.g. `TransportsActive` on
/// `AppleTCControllerType10`, which is a CF array of CF strings).
/// Returns `nil` when the property is absent and `[]` when the
/// property exists but is empty — distinct semantics that downstream
/// callers care about.
func stringArrayProperty(
    _ key: String,
    of entry: borrowing IOObject
) -> [String]? {
    guard let array = property(key, of: entry, as: NSArray.self) else {
        return nil
    }
    return array.compactMap { $0 as? String }
}

/// Read a string property (e.g. `USB Product Name`, `USB Vendor Name`,
/// `iSerialNumber`). Trims surrounding whitespace because some vendors
/// ship product strings padded out to a fixed buffer length.
func stringProperty(
    _ key: String,
    of entry: borrowing IOObject
) -> String? {
    let raw = property(key, of: entry, as: NSString.self) as String?
    return raw?.trimmingCharacters(in: .whitespacesAndNewlines)
        .nonEmptyOrNil
}

private extension String {
    /// `nil` when the string is empty after trimming, otherwise `self`.
    /// Avoids spreading "" through downstream code where `nil` is the
    /// correct "no value" signal.
    var nonEmptyOrNil: String? {
        isEmpty ? nil : self
    }
}
