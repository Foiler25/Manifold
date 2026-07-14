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

/// ANSI color helpers. Disabled automatically when stdout isn't a TTY
/// (piped output, redirected to file) or when NO_COLOR is set -
/// see https://no-color.org for the convention.
///
/// Core has no way to ask the OS "is stdout a real terminal" by itself:
/// that check (`isatty`) is a Darwin-only call, and Core stays free of
/// platform imports so it can later build for a non-Darwin backend (see
/// CLAUDE.md). Instead, whichever program prints colored text tells us the
/// answer once at startup via `configure(isTTY:)`, using its own platform
/// layer to work it out. Until `configure` is called, colour defaults to
/// off: printing plain text is a safe default, printing raw escape codes
/// into a pipe or a file is not.
public enum ANSI {
    /// Set once at startup by `configure(isTTY:)`, before any colored output
    /// is produced, and never changed again during a run. There is only one
    /// writer and it happens before any reader, so this does not need a lock.
    nonisolated(unsafe) private static var configuredIsTTY = false

    /// Tell ANSI whether stdout is a real terminal. Call this once, as early
    /// as possible in `main`, before printing anything. Safe to call more
    /// than once (e.g. in tests); the most recent call wins.
    public static func configure(isTTY: Bool) {
        configuredIsTTY = isTTY
    }

    /// Pure decision logic, pulled out of `isEnabled` so tests can exercise
    /// every NO_COLOR / TTY combination directly, without touching the
    /// shared `configuredIsTTY` state (multiple test files run concurrently
    /// in the same process, so mutating shared state from a test would risk
    /// other tests seeing the wrong value).
    static func shouldEnable(isTTY: Bool, noColorSet: Bool) -> Bool {
        if noColorSet { return false }
        return isTTY
    }

    public static var isEnabled: Bool {
        shouldEnable(
            isTTY: configuredIsTTY,
            noColorSet: ProcessInfo.processInfo.environment["NO_COLOR"] != nil
        )
    }

    public static let reset = "\u{1B}[0m"
    public static let bold = "\u{1B}[1m"
    public static let dim = "\u{1B}[2m"

    public static let red = "\u{1B}[31m"
    public static let green = "\u{1B}[32m"
    public static let yellow = "\u{1B}[33m"
    public static let blue = "\u{1B}[34m"
    public static let magenta = "\u{1B}[35m"
    public static let cyan = "\u{1B}[36m"
    public static let gray = "\u{1B}[90m"

    public static func wrap(_ codes: String, _ text: String) -> String {
        guard isEnabled else { return text }
        return codes + text + reset
    }
}
