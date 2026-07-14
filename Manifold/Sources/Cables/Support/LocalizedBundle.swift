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

// The bundle used for all localized strings in the absorbed cable core.
// Manifold has no separate SwiftPM resource bundle: English source strings
// are themselves the default values, while any matching app localization is
// resolved from Bundle.main. Missing lookups therefore return readable
// English rather than crashing or surfacing opaque localization identifiers.
//
// Access goes through an NSLock so the live language switch (written on the
// main actor from AppSettings) can't race a concurrent read from a background
// context (the CLI and the snapshot formatters read these strings off-main).
// NSLock is plain Foundation, keeping WhatCableCore import-clean (no Apple-only
// `os` lock). Reads stay synchronous, so every
// `String(localized:bundle: _coreLocalizedBundle)` call site is unchanged.
private let _coreBundleLock = NSLock()
private nonisolated(unsafe) var _coreBundleStorage: Bundle = .main

public var _coreLocalizedBundle: Bundle {
    _coreBundleLock.lock()
    defer { _coreBundleLock.unlock() }
    return _coreBundleStorage
}

public func setCoreLocale(_ identifier: String) {
    let resolved: Bundle
    if identifier.isEmpty {
        resolved = .main
    } else if let url = Bundle.main.url(forResource: identifier, withExtension: "lproj"),
              let b = Bundle(url: url) {
        resolved = b
    } else {
        resolved = .main
    }
    _coreBundleLock.lock()
    _coreBundleStorage = resolved
    _coreBundleLock.unlock()
}
