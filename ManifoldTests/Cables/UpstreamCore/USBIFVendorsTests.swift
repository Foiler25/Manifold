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

/// Tests for the bundled SQLite vendor database. Most user-facing behaviour
/// is covered by VendorDBTests via the curated-then-bundled fallback chain;
/// these tests pin properties of the bundled data itself.
@Suite("CableDB bundled database")
struct CableDBTests {

    @Test("loads many entries")
    func loadsManyEntries() {
        // The bundled DB from USB-IF's March 2026 list has ~13,000
        // vendors. If the resource fails to load (e.g. SPM resource
        // wiring breaks) the count would be 0; pin a generous lower
        // bound so future refreshes that grow the list don't fail
        // this test, but a regression to "nothing loaded" would.
        #expect(CableDB.vendorCount > 10_000)
    }

    @Test("known VID resolves")
    func knownVIDResolves() {
        #expect(CableDB.vendorName(vid: 0x05AC) == "Apple")
    }

    @Test("zero VID returns name")
    func zeroVIDReturnsName() {
        // VID 0 is "USB Implementers Forum" in the USB-IF list. CableDB
        // returns the raw name; VendorDB filters it for display purposes.
        #expect(CableDB.vendorName(vid: 0) != nil)
    }

    @Test("zero VID is USB-IF registered")
    func zeroVIDIsUSBIFRegistered() {
        #expect(CableDB.isUSBIFRegistered(0))
    }

    @Test("unregistered VID returns nil")
    func unregisteredVIDReturnsNil() {
        // 0xDEAD (decimal 57005) is not a USB-IF assignment.
        #expect(CableDB.vendorName(vid: 0xDEAD) == nil)
        #expect(CableDB.isUSBIFRegistered(0xDEAD) == false)
    }

    @Test("USB-IF source tracking")
    func usbIFSourceTracking() {
        // Apple should be sourced from USB-IF.
        #expect(CableDB.isUSBIFRegistered(0x05AC))
    }

    @Test("no control characters in bundled names")
    func noControlCharactersInBundledNames() {
        // pdftotext emits form-feed (\u{000C}) at the start of each
        // page, which can land glued onto vendor names if the parser
        // doesn't strip control chars. Pin specific entries that were
        // affected before the parser fix (page-boundary vendors per
        // USB-IF March 2026), and a generic "vendor names contain no
        // ASCII control characters" check on a couple more.
        #expect(VendorDB.name(for: 1011) == "Adaptec, Inc.")
        #expect(VendorDB.name(for: 1069) == "Micronics")
        #expect(VendorDB.name(for: 1196) == "Micro Audiometrics Corp.")
        for vid in [1011, 1069, 1196, 1222, 1480] {
            let name = VendorDB.name(for: vid) ?? ""
            for scalar in name.unicodeScalars {
                #expect(
                    scalar.value >= 0x20 && scalar.value != 0x7F,
                    "vendor name for \(String(format: "0x%04X", vid)) contains control char U+\(String(scalar.value, radix: 16))"
                )
            }
        }
    }

    @Test("cable e-marker chip vendors all resolve")
    func cableEmarkerChipVendorsAllResolve() {
        // The six chip vendors observed in real cable reports.
        #expect(CableDB.vendorName(vid: 0x20C2) != nil) // Sumitomo
        #expect(CableDB.vendorName(vid: 0x315C) != nil) // Convenientpower
        #expect(CableDB.vendorName(vid: 0x2095) != nil) // CE LINK
        #expect(CableDB.vendorName(vid: 0x2E99) != nil) // Hynetek
        #expect(CableDB.vendorName(vid: 0x201C) != nil) // Freeport
        #expect(CableDB.vendorName(vid: 0x2B1D) != nil) // Lintes
    }

    @Test("usb.ids vendor resolves name")
    func usbIDsVendorResolvesName() {
        // VID 0x6666 ("Prototype product Vendor ID") is in the community
        // usb.ids list but not in USB-IF's official registry.
        #expect(CableDB.vendorName(vid: 0x6666) != nil)
    }

    @Test("usb.ids vendor not USB-IF registered")
    func usbIDsVendorNotUSBIFRegistered() {
        // usb.ids entries are not USB-IF registrations, so isUSBIFRegistered
        // stays false. (A usb.ids entry with a real brand name now reads as
        // the neutral vidCommunityKnownNotUSBIF note in CableTrustReport; a
        // placeholder name like 0x6666's keeps the vidNotInUSBIFList warning.)
        #expect(CableDB.isUSBIFRegistered(0x6666) == false)
    }

    @Test("manual vendor resolves name but stays not USB-IF registered")
    func manualVendorResolvesButNotUSBIFRegistered() {
        // VID 0x01B6 is CalDigit's Thunderbolt-class identifier. It is not
        // in the USB-IF list (their USB-IF VID is 0x2188 / CalDigit, Inc.)
        // and not in usb.ids, so it lives in data/manual-vendors.tsv. The
        // app should resolve the name, but the trust signal must stay
        // "not USB-IF registered".
        #expect(CableDB.vendorName(vid: 0x01B6) == "CalDigit, Inc.")
        #expect(CableDB.isUSBIFRegistered(0x01B6) == false)
    }

    @Test("curated cable not found for unknown")
    func curatedCableNotFoundForUnknown() {
        #expect(CableDB.curatedCables(vid: 0xDEAD, pid: 0xBEEF).isEmpty)
    }

    @Test("curated cable lookup")
    func curatedCableLookup() {
        // CalDigit TS5 Plus bundled cable: VID 0x01B6, PID 0x4003.
        let cables = CableDB.curatedCables(vid: 0x01B6, pid: 0x4003)
        #expect(!cables.isEmpty)
        #expect(cables.contains { $0.brand.contains("CalDigit") })
    }

    @Test("cable count matches expected")
    func cableCountMatchesExpected() {
        // cableCount is the total number of curated cable entries loaded;
        // fingerprintCount is unique VID/PID identities. Real (both non-zero)
        // identities are deduped at build time (one row each); zeroed and
        // VID-only rows may still repeat.
        #expect(CableDB.cableCount >= 10)
        #expect(CableDB.fingerprintCount >= 10)
    }

    @Test("a zeroed vendor ID never matches a curated cable")
    func zeroedVIDNeverMatches() {
        // Identity is VID + PID only. The Cable VDO is a capability spec
        // (speed/power/type) shared across unrelated brands, so it is not part
        // of the key. A zeroed VID therefore resolves to no brand, which is
        // what stops a Statik cable showing as "Anker" off a shared generic
        // USB2/100W VDO. See #239 (and #161 for the all-zero case).
        #expect(CableDB.curatedCables(vid: 0, pid: 0).isEmpty)
        #expect(CableDB.curatedCables(vid: 0, pid: 0x1234).isEmpty)
    }

    @Test("a vendor ID with no product ID never matches a curated brand")
    func vidWithoutPIDNeverMatches() {
        // VID present but PID 0: the VID is the silicon vendor, shared across
        // retail brands (0x201C / HK Freeport ships in Anker and LG/Dell
        // cables), so we resolve the vendor name but never a curated brand.
        #expect(CableDB.curatedCables(vid: 0x201C, pid: 0).isEmpty)
    }

    @Test("a real VID+PID identity resolves to exactly one curated cable")
    func realIdentityIsUnique() {
        // The build enforces a partial unique index on (vid, pid) for non-zero
        // pairs, so a fully-identified cable can never resolve to two brands.
        // CalDigit (0x01B6, 0x4003) was reported in five issues; the db keeps
        // exactly one row, so the lookup is unambiguous. See #239.
        let caldigit = CableDB.curatedCables(vid: 0x01B6, pid: 0x4003)
        #expect(caldigit.count == 1)
        #expect(caldigit.first?.brand.contains("CalDigit") == true)
    }
}
