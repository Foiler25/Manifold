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
@testable import Manifold
import Foundation
import Testing

/// Stress test for the DAR-60 fix: many concurrent reads of the localized
/// bundle while other tasks flip the locale. Run under ThreadSanitizer to prove
/// there is no data race on the shared global.
///
/// Gated behind an env var because it deliberately mutates the process-wide
/// locale at speed; leaving it in the normal (parallel) suite would let it
/// perturb other tests' localized reads. Run it on its own:
///
///   WHATCABLE_TSAN_STRESS=1 swift test --sanitize=thread \
///     --filter LocalizedBundleConcurrencyTests
///
/// On the pre-fix code (stored `var` global) TSan reports a data race here; on
/// the lock-guarded version it is clean.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["WHATCABLE_TSAN_STRESS"] != nil))
struct LocalizedBundleConcurrencyTests {
    @Test("Concurrent reads during a locale switch do not race")
    func concurrentReadWrite() async {
        defer { setCoreLocale("") }   // restore the default bundle afterwards
        await withTaskGroup(of: Void.self) { group in
            // Writers: flip the locale back and forth.
            for _ in 0..<4 {
                group.addTask {
                    for i in 0..<5000 {
                        setCoreLocale(i.isMultiple(of: 2) ? "fr" : "")
                    }
                }
            }
            // Readers: touch the bundle the same way a localized string would.
            for _ in 0..<8 {
                group.addTask {
                    for _ in 0..<5000 {
                        _ = _coreLocalizedBundle.bundlePath
                    }
                }
            }
        }
    }
}
