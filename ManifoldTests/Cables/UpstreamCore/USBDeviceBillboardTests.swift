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

@Suite("USB Billboard device detection")
struct USBDeviceBillboardTests {

    private func device(
        deviceClass: UInt8? = nil,
        ioClassName: String? = nil,
        productName: String? = nil
    ) -> USBDevice {
        USBDevice(
            id: 1, locationID: 0x0100_0000, vendorID: 0, productID: 0,
            vendorName: nil, productName: productName, serialNumber: nil,
            usbVersion: nil, speedRaw: nil, busPowerMA: nil, currentMA: nil,
            deviceClass: deviceClass, ioClassName: ioClassName,
            rawProperties: [:]
        )
    }

    @Test("bDeviceClass 0x11 is the spec-defined Billboard Device Class")
    func detectsByDeviceClass() {
        #expect(device(deviceClass: 0x11).isBillboardDevice)
    }

    @Test("Apple's Billboard IOKit class is recognised")
    func detectsByClassName() {
        #expect(device(ioClassName: "AppleUSBHostBillboardDevice").isBillboardDevice)
    }

    @Test("The product name macOS assigns is recognised")
    func detectsByProductName() {
        // The one signal observed in the wild so far: a real device showed up
        // named "Generic Billboard Device".
        #expect(device(productName: "Generic Billboard Device").isBillboardDevice)
    }

    @Test("An ordinary device is not a Billboard device")
    func ordinaryDeviceIsNot() {
        // bDeviceClass 9 is a USB hub, the common case next to a dock.
        #expect(!device(deviceClass: 9, ioClassName: "IOUSBHostDevice", productName: "USB3.0 Hub").isBillboardDevice)
        #expect(!device().isBillboardDevice)
    }

    @Test("An informative product name is surfaced")
    func informativeNameReturned() {
        // A Billboard device (class 0x11) whose name names the real product.
        let d = device(deviceClass: 0x11, productName: "Anker USB-C Hub Device")
        #expect(d.billboardInformativeName == "Anker USB-C Hub Device")
    }

    @Test("A generic billboard name is suppressed")
    func genericNameSuppressed() {
        // Names that are themselves just a "billboard" variant add nothing,
        // so callers fall back to the plain phrase.
        #expect(device(deviceClass: 0x11, productName: "Generic Billboard Device").billboardInformativeName == nil)
        #expect(device(deviceClass: 0x11, productName: "USB 2.0 BILLBOARD").billboardInformativeName == nil)
        #expect(device(deviceClass: 0x11, productName: nil).billboardInformativeName == nil)
        // Whitespace-padded real names (seen in the corpus) are trimmed.
        #expect(device(deviceClass: 0x11, productName: "  TS5 Plus Composite Device  ").billboardInformativeName == "TS5 Plus Composite Device")
    }

    @Test("The older IOKit class name is recognised too")
    func detectsByOlderClassName() {
        // The substring match covers both "AppleUSBHostBillboardDevice" and the
        // older "IOUSBHostBillboardDevice" the C probe also looks for.
        #expect(device(ioClassName: "IOUSBHostBillboardDevice").isBillboardDevice)
    }
}
