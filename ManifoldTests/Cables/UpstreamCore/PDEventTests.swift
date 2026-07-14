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

@Suite("PD Event Trace")
struct PDEventTests {
    @Test("All documented TPS6598x event codes decode correctly")
    func allKnownCodes() {
        let expected: [(UInt8, PDEvent)] = [
            (0x01, .plugInsertOrRemoval),
            (0x02, .prSwapComplete),
            (0x03, .drSwapComplete),
            (0x1a, .sourceCapRx),
            (0x30, .statusUpdate),
            (0x31, .pdStatusUpdate),
            (0x37, .usb2Plug),
            (0x3f, .powerStatusUpdate),
            (0x40, .appLoaded),
            (0x48, .rxIdSop),
            (0x5e, .uvdmStatusUpdate),
            (0x5f, .uvdmEnum),
            (0xf0, .sleepWake),
            (0xf1, .alert),
        ]
        for (code, event) in expected {
            #expect(PDEvent(rawValue: code) == event, "0x\(String(code, radix: 16)) should decode to \(event)")
        }
    }

    @Test("Round-trip: rawValue matches init input for all known codes")
    func roundTrip() {
        let codes: [UInt8] = [0x01, 0x02, 0x03, 0x1a, 0x30, 0x31, 0x37, 0x3f, 0x40, 0x48, 0x5e, 0x5f, 0xf0, 0xf1]
        for code in codes {
            let event = PDEvent(rawValue: code)
            #expect(event.rawValue == code, "Round-trip failed for 0x\(String(code, radix: 16))")
        }
    }

    @Test("Unknown codes produce .unknown case")
    func unknownCodes() {
        let unknowns: [UInt8] = [0x00, 0x04, 0x10, 0x99, 0xFF]
        for code in unknowns {
            if case .unknown(let raw) = PDEvent(rawValue: code) {
                #expect(raw == code)
            } else {
                Issue.record("0x\(String(code, radix: 16)) should be .unknown")
            }
        }
    }

    @Test("Observed M5 Pro trace decodes without crashing")
    func realTrace() {
        // Observed buffer from planning doc: 10 48 48 5f 5e 00 5f 40 01 5e 00 37 02
        // After filtering 0x00:             10 48 48 5f 5e 5f 40 01 5e 37 02
        let buffer: [UInt8] = [0x10, 0x48, 0x48, 0x5f, 0x5e, 0x00, 0x5f, 0x40, 0x01, 0x5e, 0x00, 0x37, 0x02]
        let filtered = buffer.filter { $0 != 0x00 }
        let events = filtered.map(PDEvent.init(rawValue:))
        #expect(events.count == 11)
        // index 0: 0x10 = unknown
        #expect(events[1] == .rxIdSop)       // 0x48
        #expect(events[2] == .rxIdSop)       // 0x48
        #expect(events[3] == .uvdmEnum)      // 0x5f
        #expect(events[4] == .uvdmStatusUpdate) // 0x5e
        #expect(events[5] == .uvdmEnum)      // 0x5f
        #expect(events[6] == .appLoaded)     // 0x40
        #expect(events[7] == .plugInsertOrRemoval) // 0x01
        #expect(events[8] == .uvdmStatusUpdate)    // 0x5e
        #expect(events[9] == .usb2Plug)      // 0x37
        #expect(events[10] == .prSwapComplete) // 0x02
    }
}
