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
import Testing
import Foundation

@Suite("Cable Report")
struct CableReportTests {

    private func cableIdentity(
        vendorID: Int = 0x05AC,
        productID: Int = 0x1234,
        endpoint: USBPDSOP.Endpoint = .sopPrime,
        vdos: [UInt32] = [
            // ID Header VDO: passive cable from VID 0x05AC
            (3 << 27) | UInt32(0x05AC),
            0,
            0,
            // Cable VDO: USB4 Gen 3 (0b011), 5A (0b10), passive,
            // latency 0001 (~1 m). A bare-zero VDO would trip the
            // reservedCableLatencyEncoding warning even though these
            // tests aren't about trust signals.
            (0b10 << 5) | 0b011 | (1 << 13)
        ]
    ) -> USBPDSOP {
        USBPDSOP(
            id: 1,
            endpoint: endpoint,
            parentPortType: 0,
            parentPortNumber: 0,
            vendorID: vendorID,
            productID: productID,
            bcdDevice: 0,
            vdos: vdos,
            specRevision: 3
        )
    }

    @Test("Payload only built for cable endpoints")
    func payloadOnlyBuiltForCableEndpoints() {
        #expect(CableReport.payload(for: cableIdentity(endpoint: .sopPrime)) != nil)
        #expect(CableReport.payload(for: cableIdentity(endpoint: .sopDoublePrime)) != nil)
        #expect(CableReport.payload(for: cableIdentity(endpoint: .sop)) == nil)
        #expect(CableReport.payload(for: cableIdentity(endpoint: .unknown)) == nil)
    }

    @Test("Fingerprint formats hex as uppercase four digits")
    func fingerprintFormatsHexAsUppercaseFourDigits() {
        let payload = CableReport.payload(for: cableIdentity(vendorID: 0x05AC, productID: 0x004C))!
        #expect(payload.cable.vendorIDHex == "0x05AC")
        #expect(payload.cable.productIDHex == "0x004C")
    }

    @Test("Fingerprint labels unregistered vendor")
    func fingerprintLabelsUnregisteredVendor() {
        let payload = CableReport.payload(for: cableIdentity(vendorID: 0xDEAD))!
        #expect(payload.cable.vendorName == "Unregistered / unknown")
    }

    @Test("Curated VID+PID match prefers the brand over the silicon vendor")
    func curatedMatchPrefersBrand() {
        // CalDigit TB5 cable (VID 0x01B6, PID 0x4003) is in the curated DB.
        // On a confident VID+PID match the report surfaces the curated
        // brand/model rather than only the silicon vendor name. See #239.
        let curated = CableDB.curatedCables(vid: 0x01B6, pid: 0x4003)
        #expect(!curated.isEmpty)
        let payload = CableReport.payload(for: cableIdentity(vendorID: 0x01B6, productID: 0x4003))!
        #expect(payload.cable.vendorName == curated.first?.brand)
        #expect(payload.cable.vendorName.contains("CalDigit"))
    }

    @Test("Markdown includes fingerprint and environment")
    func markdownIncludesFingerprintAndEnvironment() {
        let payload = CableReport.payload(for: cableIdentity(), appVersion: "1.2.3")!
        let md = payload.markdown
        #expect(md.contains("### Cable e-marker fingerprint"))
        #expect(md.contains("`0x05AC`"))
        #expect(md.contains("Apple"))
        #expect(md.contains("### Environment"))
        #expect(md.contains("WhatCable: `1.2.3`"))
        // No system info opt-in: should be flagged as not included.
        #expect(md.contains("not included by reporter"))
    }

    @Test("Payload carries the injected Mac model, not a sysctl lookup")
    func payloadCarriesInjectedMacModel() {
        // CableReport doesn't call sysctl itself anymore (that's a
        // Darwin-only API, out of bounds for Core). Callers fetch the model
        // via WhatCableDarwinBackend and pass it in; this checks it flows
        // through untouched.
        let payload = CableReport.payload(
            for: cableIdentity(),
            includeSystemInfo: true,
            macModel: "Mac16,1"
        )!
        #expect(payload.system?.macModel == "Mac16,1")
    }

    @Test("Payload defaults Mac model to unknown when the caller doesn't provide one")
    func payloadDefaultsMacModelToUnknown() {
        let payload = CableReport.payload(for: cableIdentity(), includeSystemInfo: true)!
        #expect(payload.system?.macModel == "unknown")
    }

    @Test("Markdown includes system info when provided")
    func markdownIncludesSystemInfoWhenProvided() {
        let payload = CableReport.Payload(
            cable: CableReport.CableFingerprint(identity: cableIdentity()),
            system: CableReport.SystemInfo(macModel: "Mac15,3", macOSVersion: "14.5.0"),
            appVersion: "1.2.3"
        )
        let md = payload.markdown
        #expect(md.contains("Mac: `Mac15,3`"))
        #expect(md.contains("macOS: `14.5.0`"))
        #expect(md.contains("not included by reporter") == false)
    }

    @Test("GitHub URL targets template and carries fingerprint")
    func gitHubURLTargetsTemplateAndCarriesFingerprint() throws {
        let payload = CableReport.payload(for: cableIdentity())!
        let url = payload.githubURL
        let comps = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(comps.host == "github.com")
        #expect(comps.path == "/darrylmorley/whatcable/issues/new")
        let items = Dictionary(uniqueKeysWithValues:
            (comps.queryItems ?? []).map { ($0.name, $0.value ?? "") }
        )
        #expect(items["template"] == "cable-report.yml")
        #expect(items["labels"] == "cable-report")
        #expect(items["title"]?.hasPrefix("[Cable Report]") == true)
        #expect(items["fingerprint"]?.contains("0x05AC") == true)
    }

    @Test("Issue title includes vendor and speed")
    func issueTitleIncludesVendorAndSpeed() {
        let payload = CableReport.payload(for: cableIdentity())!
        #expect(payload.issueTitle.contains("Apple"))
        #expect(payload.issueTitle.contains("USB4"))
    }

    @Test("Fingerprint carries raw VDOs")
    func fingerprintCarriesRawVDOs() {
        let payload = CableReport.payload(for: cableIdentity())!
        // Fixture has 4 VDOs: ID Header, Cert Stat, Product, Cable.
        #expect(payload.cable.vdos.count == 4)
        // VDO[0] = passive cable header (3 << 27) | 0x05AC.
        #expect(payload.cable.vdos[0] == (3 << 27) | UInt32(0x05AC))
    }

    @Test("Markdown includes raw VDO section")
    func markdownIncludesRawVDOSection() {
        let payload = CableReport.payload(for: cableIdentity())!
        let md = payload.markdown
        #expect(md.contains("### Raw VDOs"))
        // ID Header VDO from the fixture: (3 << 27) | 0x05AC = 0x180005AC.
        #expect(md.contains("`0x180005AC`"))
        // Role labels appear so future readers can tell which is which
        // without having to know the spec layout.
        #expect(md.contains("ID Header"))
        #expect(md.contains("Cable"))
        #expect(md.contains("Product"))
    }

    @Test("Markdown omits raw VDO section when absent")
    func markdownOmitsRawVDOSectionWhenAbsent() {
        // Identity with no VDOs (e.g. a cable that didn't respond to
        // Discover Identity at all) shouldn't render an empty Raw VDOs table.
        let id = USBPDSOP(
            id: 1,
            endpoint: .sopPrime,
            parentPortType: 0,
            parentPortNumber: 0,
            vendorID: 0x05AC,
            productID: 0,
            bcdDevice: 0,
            vdos: [],
            specRevision: 3
        )
        let payload = CableReport.payload(for: id)!
        let md = payload.markdown
        #expect(md.contains("### Raw VDOs") == false)
    }

    @Test("Markdown notes when the e-marker was not read")
    func markdownNotesUnreadEmarker() {
        // Endpoint present but no VDOs: the e-marker was not woken on this
        // connection. The report should say so, so a blank vendor ID is not
        // mistaken for a faulty or counterfeit cable.
        let id = USBPDSOP(
            id: 1,
            endpoint: .sopPrime,
            parentPortType: 0,
            parentPortNumber: 0,
            vendorID: 0,
            productID: 0,
            bcdDevice: 0,
            vdos: [],
            specRevision: 3
        )
        let md = CableReport.payload(for: id)!.markdown
        #expect(md.contains("e-marker was not read on this connection"))
        // The fingerprint rows must not show a bogus 0x0000: the identity was
        // not read, so they read "not read on this connection" too.
        #expect(md.contains("| Vendor ID | not read on this connection |"))
        #expect(md.contains("0x0000") == false)
    }

    // MARK: - USB-IF certification ID (from Cert Stat VDO)

    @Test("USB-IF cert ID present when non-zero")
    func usbIFCertIDPresentWhenNonZero() {
        let id = USBPDSOP(
            id: 1,
            endpoint: .sopPrime,
            parentPortType: 0,
            parentPortNumber: 0,
            vendorID: 0x05AC,
            productID: 0x1234,
            bcdDevice: 0,
            vdos: [
                (3 << 27) | UInt32(0x05AC),
                0x00012345,             // Cert Stat with XID
                0,
                (0b10 << 5) | 0b011 | (1 << 13)
            ],
            specRevision: 3
        )
        let payload = CableReport.payload(for: id)!
        #expect(payload.cable.usbifCertID == 0x00012345)
        let md = payload.markdown
        #expect(md.contains("USB-IF certification ID"))
        #expect(md.contains("0x00012345"))
    }

    @Test("USB-IF cert ID absent when zero")
    func usbIFCertIDAbsentWhenZero() {
        // Calibration: Anker #60 and Caldigit #62 both ship with XID = 0.
        // We surface that as "none" rather than a trust signal.
        let payload = CableReport.payload(for: cableIdentity())!
        #expect(payload.cable.usbifCertID == nil)
        let md = payload.markdown
        #expect(md.contains("USB-IF certification ID"))
        #expect(md.contains("none (XID = 0)"))
    }

    @Test("USB-IF cert ID distinguishes absent VDO from zero value")
    func usbIFCertIDDistinguishesAbsentVDOFromZeroValue() {
        // Identity with only an ID Header VDO -- macOS didn't surface a
        // Cert Stat. The fingerprint should record that explicitly,
        // not flatten it to "XID = 0", so calibration data stays
        // faithful to what the cable actually reported.
        let id = USBPDSOP(
            id: 1,
            endpoint: .sopPrime,
            parentPortType: 0,
            parentPortNumber: 0,
            vendorID: 0x05AC,
            productID: 0,
            bcdDevice: 0,
            vdos: [
                (3 << 27) | UInt32(0x05AC) // only ID Header, no Cert Stat
            ],
            specRevision: 3
        )
        let payload = CableReport.payload(for: id)!
        #expect(payload.cable.usbifCertID == nil)
        let md = payload.markdown
        #expect(md.contains("USB-IF certification ID"))
        #expect(md.contains("not provided by this Mac"))
        #expect(
            md.contains("none (XID = 0)") == false,
            "Missing VDO[1] must not be rendered the same as a real zero XID"
        )
    }

    // MARK: - CIO Thunderbolt link context

    @Test("Markdown includes CIO section when present")
    func markdownIncludesCIOSectionWhenPresent() {
        let cio = CIOCableCapability(
            id: 1,
            portKey: "2/0",
            cableGeneration: 2,
            negotiatedLinkSpeed: 3,
            generation: 3,
            asymmetricModeSupported: true,
            legacyAdapter: false,
            linkTrainingMode: 2
        )
        let payload = CableReport.payload(
            for: cableIdentity(),
            cioCapability: cio
        )!
        let md = payload.markdown
        #expect(md.contains("### Thunderbolt link context"))
        #expect(md.contains("CableGeneration"))
        #expect(md.contains("| `2` |"))
        #expect(md.contains("CableSpeed"))
        #expect(md.contains("| `3` |"))
        #expect(md.contains("Generation"))
        #expect(md.contains("AsymmetricModeSupported"))
        #expect(md.contains("| Yes |"))
        #expect(md.contains("LegacyAdapter"))
        #expect(md.contains("| No |"))
        #expect(md.contains("LinkTrainingMode"))
    }

    @Test("Markdown omits CIO section when absent")
    func markdownOmitsCIOSectionWhenAbsent() {
        let payload = CableReport.payload(for: cableIdentity())!
        let md = payload.markdown
        #expect(md.contains("### Thunderbolt link context") == false)
        #expect(md.contains("CableGeneration") == false)
    }

    @Test("CIO section omitted when all fields nil")
    func cioSectionOmittedWhenAllFieldsNil() {
        let cio = CIOCableCapability(
            id: 1,
            portKey: "2/0",
            cableGeneration: nil,
            negotiatedLinkSpeed: nil,
            generation: nil,
            asymmetricModeSupported: nil,
            legacyAdapter: nil,
            linkTrainingMode: nil
        )
        let payload = CableReport.payload(
            for: cableIdentity(),
            cioCapability: cio
        )!
        let md = payload.markdown
        #expect(
            md.contains("### Thunderbolt link context") == false,
            "All-nil CIO should not render an empty table"
        )
    }

    @Test("CIO section omits nil fields")
    func cioSectionOmitsNilFields() {
        // CIO with only negotiatedLinkSpeed set, everything else nil.
        let cio = CIOCableCapability(
            id: 1,
            portKey: "2/0",
            cableGeneration: nil,
            negotiatedLinkSpeed: 3,
            generation: nil,
            asymmetricModeSupported: nil,
            legacyAdapter: nil,
            linkTrainingMode: nil
        )
        let payload = CableReport.payload(
            for: cableIdentity(),
            cioCapability: cio
        )!
        let md = payload.markdown
        #expect(md.contains("### Thunderbolt link context"))
        #expect(md.contains("CableSpeed"))
        #expect(md.contains("CableGeneration") == false)
        #expect(md.contains("AsymmetricModeSupported") == false)
        #expect(md.contains("LinkTrainingMode") == false)
    }

    @Test("Markdown labels extra VDOs as Other")
    func markdownLabelsExtraVDOsAsOther() {
        // PD response can include up to 7 VDOs (ID Header + Cert Stat +
        // Product + up to 4 Product Type VDOs). Index 4 is Active Cable VDO2;
        // anything past that we label "Other" rather than guessing.
        let id = USBPDSOP(
            id: 1,
            endpoint: .sopPrime,
            parentPortType: 0,
            parentPortNumber: 0,
            vendorID: 0x05AC,
            productID: 0x1234,
            bcdDevice: 0,
            vdos: [
                (3 << 27) | UInt32(0x05AC),
                0,
                0,
                (0b10 << 5) | 0b011 | (1 << 13), // valid 1m latency
                0xDEADBEEF,
                0xCAFEBABE
            ],
            specRevision: 3
        )
        let payload = CableReport.payload(for: id)!
        let md = payload.markdown
        #expect(md.contains("`0xDEADBEEF`"))
        #expect(md.contains("`0xCAFEBABE`"))
        // Index 4 is now "Active Cable VDO2"; index 5 falls through to "Other".
        #expect(md.contains("Active Cable VDO2"))
        #expect(md.contains("Other"))
    }

    // MARK: - VDO role labels (spec Figure 6.5)

    @Test("vdoRoleLabel returns correct labels for indices 0 to 4")
    func vdoRoleLabelKnownIndices() {
        // USB PD R3.2 Figure 6.5: 0=ID Header, 1=Cert Stat, 2=Product,
        // 3=Cable (Passive Cable VDO or Active Cable VDO1), 4=Active Cable VDO2.
        #expect(CableReport.vdoRoleLabel(at: 0) == "ID Header")
        #expect(CableReport.vdoRoleLabel(at: 1) == "Cert Stat")
        #expect(CableReport.vdoRoleLabel(at: 2) == "Product")
        #expect(CableReport.vdoRoleLabel(at: 3) == "Cable")
        #expect(CableReport.vdoRoleLabel(at: 4) == "Active Cable VDO2")
    }

    @Test("vdoRoleLabel returns Other for indices 5 and above")
    func vdoRoleLabelUnknownIndices() {
        #expect(CableReport.vdoRoleLabel(at: 5) == "Other")
        #expect(CableReport.vdoRoleLabel(at: 6) == "Other")
        #expect(CableReport.vdoRoleLabel(at: 99) == "Other")
    }
}
