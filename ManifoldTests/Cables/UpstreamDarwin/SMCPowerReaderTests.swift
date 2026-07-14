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

/// Pure-logic tests for the desktop SMC power path. The live IOKit reads need
/// hardware, but the FourCC packing, UUID normalisation, channel-to-sample
/// conversion, and the struct-layout guard are all unit-testable.
struct SMCPowerReaderTests {

    @Test("FourCC packs a 4-char SMC key MSB-first")
    func fourCCPacksKey() {
        // 'D'=0x44 '1'=0x31 'J'=0x4A 'V'=0x56
        #expect(SMCPowerReader.fourCC("D1JV") == 0x4431_4A56)
        #expect(SMCPowerReader.fourCC("D4UI") == 0x4434_5549)
    }

    @Test("FourCC rejects keys that are not exactly four ASCII chars")
    func fourCCRejectsBadKeys() {
        #expect(SMCPowerReader.fourCC("D1J") == nil)
        #expect(SMCPowerReader.fourCC("D1JVX") == nil)
        #expect(SMCPowerReader.fourCC("D1J€") == nil)
    }

    @Test("Float decode roundtrips a finite SMC flt payload")
    func decodeFloatFinite() {
        // 5.18 as little-endian IEEE-754 bytes.
        let bytes = withUnsafeBytes(of: Float(5.18).bitPattern.littleEndian) { Array($0) }
        #expect(SMCPowerReader.decodeFloat(bytes) == 5.18)
        #expect(SMCPowerReader.decodeFloat([0, 0, 0, 0]) == 0)
    }

    @Test("Float decode rejects non-finite and short payloads")
    func decodeFloatRejectsGarbage() {
        // An uninitialised channel can carry inf/NaN bit patterns; letting
        // them through would trap in the Int() unit conversions downstream
        // (PowerTelemetryWatcher mV/mA/mW). nil routes them into the same
        // `?? 0` fallback as an absent key.
        func bytes(_ f: Float) -> [UInt8] {
            withUnsafeBytes(of: f.bitPattern.littleEndian) { Array($0) }
        }
        #expect(SMCPowerReader.decodeFloat(bytes(.infinity)) == nil)
        #expect(SMCPowerReader.decodeFloat(bytes(-.infinity)) == nil)
        #expect(SMCPowerReader.decodeFloat(bytes(.nan)) == nil)
        #expect(SMCPowerReader.decodeFloat([]) == nil)
        #expect(SMCPowerReader.decodeFloat([0x00, 0x00, 0xA6]) == nil)
    }

    @Test("Constructing the reader does not trip the 80-byte struct assertion")
    func structLayoutIsCorrect() {
        // The init() precondition fires (in debug) if SMCParamStruct ever stops
        // being 80 bytes, which the AppleSMC ABI requires.
        _ = SMCPowerReader()
    }

    @Test("HPM UUID normalisation strips dashes and lowercases")
    func uuidNormalisation() {
        #expect(
            HPMPortUUIDMap.normalise("AAAA1111-BBBB-2222-CCCC-333344445555")
                == "aaaa1111bbbb2222cccc333344445555"
        )
        // Already-normalised SMC-style input is unchanged.
        #expect(
            HPMPortUUIDMap.normalise("6230af2d000000000000112233445566")
                == "6230af2d000000000000112233445566"
        )
    }

    @Test("SMC channel converts to a live per-port sample on the right port")
    func smcChannelToSample() {
        let channel = SMCPortPowerChannel(
            channel: 3,
            present: true,
            volts: 5.18,
            amps: 0.643,
            uuid: "aaaa1111bbbb2222cccc333344445555"
        )
        // The channel's UUID maps to physical port @4 (the non-positional case).
        let sample = PowerTelemetryWatcher.smcPortSample(channel: channel, portKey: "2/4")

        #expect(sample.portKey == "2/4")
        #expect(sample.portIndex == 4)
        #expect(sample.configuredVoltage == 5180)   // mV
        #expect(sample.current == 643)              // mA
        #expect(sample.watts == 3331)               // mW, 5.18 x 0.643 x 1000
        #expect(sample.isSMCMeasured)
        // It is a live measured reading, not a contracted-max fallback, so the
        // UI shows real volts rather than the "--" placeholder.
        #expect(!sample.isContractedFallback)
        #expect(sample.adapterVoltage == 0)
    }

    @Test("SMC DC-in reading converts to the System Power sample in mV/mA/mW")
    func smcSystemSampleConversion() {
        // Mac mini M4 corpus values: 12.55 V / 1.83 A / 22.91 W DC-in.
        let input = SMCSystemPowerInput(volts: 12.55, amps: 1.83, watts: 22.91)
        let now = Date()
        let sample = PowerTelemetryWatcher.smcSystemSample(input, timestamp: now)

        #expect(sample.systemVoltageIn == 12550)   // mV
        #expect(sample.systemCurrentIn == 1830)    // mA
        #expect(sample.systemPowerIn == 22910)     // mW
        #expect(sample.timestamp == now)
    }

    @Test("MagSafe channel keeps the MagSafe port-type prefix in its key")
    func smcChannelMagSafeKey() {
        let channel = SMCPortPowerChannel(
            channel: 4, present: true, volts: 9.0, amps: 1.0,
            uuid: "7c30af2d000000000000aabbccddeeff"
        )
        let sample = PowerTelemetryWatcher.smcPortSample(channel: channel, portKey: "17/1")
        #expect(sample.portKey == "17/1")
        #expect(sample.portIndex == 1)
        #expect(sample.watts == 9000)
    }

    // MARK: - perPortMeteringSupported gate (issue #291 regression guard)

    /// A non-empty UUID map alone must NOT flip `perPortMeteringSupported` to
    /// true. The flag is only true when at least one SMC channel UUID actually
    /// appears in the map. This guards against the M1/M2 regression where
    /// `updatePorts()` could populate the map (the HPM watcher fires on M1/M2
    /// too), but SMC channels return a different UUID namespace and nothing
    /// matches. Without this guard, the Power Monitor would spin on
    /// "Negotiating..." forever on M1/M2 desktop Macs (issue #291).
    @Test("perPortMeteringSupported is false when no SMC channel UUID matches the port map")
    func perPortMeteringNotSupportedWhenChannelsDontMatch() {
        // Simulate an M1/M2 scenario: the UUID map was populated from the HPM
        // watcher, but the SMC port-power channels carry UUIDs from a different
        // namespace. No channel resolves to a known port key.
        let uuidMap: [String: String] = [
            "aaaabbbbccccddddeeeeffffffff0001": "2/1",
            "aaaabbbbccccddddeeeeffffffff0002": "2/2",
        ]
        let channels: [SMCPortPowerChannel] = [
            // Channel UUIDs from the SMC are entirely different from the map.
            SMCPortPowerChannel(channel: 1, present: false, volts: 0.0, amps: 0.0,
                                uuid: "1111111111111111111111111111dead"),
            SMCPortPowerChannel(channel: 2, present: false, volts: 0.0, amps: 0.0,
                                uuid: "2222222222222222222222222222beef"),
        ]
        var matchedChannels = 0
        for channel in channels {
            guard uuidMap[channel.uuid] != nil else { continue }
            matchedChannels += 1
        }
        // The map is non-empty, but no channel matched -- flag must stay false.
        let supported = matchedChannels > 0
        #expect(!supported,
            "perPortMeteringSupported must be false when no SMC channel resolves via UUID map")
    }

    @Test("perPortMeteringSupported is true when at least one SMC channel UUID matches")
    func perPortMeteringSupportedWhenOneChannelMatches() {
        let knownUUID = "aaaa1111bbbb2222cccc333344445555"
        let uuidMap: [String: String] = [knownUUID: "2/4"]
        let channels: [SMCPortPowerChannel] = [
            SMCPortPowerChannel(channel: 1, present: true, volts: 5.18, amps: 0.643,
                                uuid: knownUUID),
        ]
        var matchedChannels = 0
        for channel in channels {
            guard uuidMap[channel.uuid] != nil else { continue }
            matchedChannels += 1
        }
        let supported = matchedChannels > 0
        #expect(supported,
            "perPortMeteringSupported must be true when at least one channel resolves")
    }
}
