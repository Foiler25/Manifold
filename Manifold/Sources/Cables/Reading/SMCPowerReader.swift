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
import IOKit

/// One USB-C / MagSafe power-OUT channel as the SMC reports it.
///
/// Desktops (Mac mini / Studio / Pro) have no battery controller, so the IOKit
/// per-port power paths the laptop pipeline uses are empty. The per-port
/// power-OUT figures still exist, they just live in the SMC (the System
/// Management Controller, a small always-on chip) on channels `D1..D4`.
///
/// `uuid` is the channel's `DxUI` key. It equals the port controller's
/// `AppleHPMDeviceHALType3.UUID`, which is how a channel is tied to a physical
/// port (see ``HPMPortUUIDMap``). It is an internal join key only: never put it
/// in `--json` / `--raw` output or the UI.
public struct SMCPortPowerChannel: Sendable, Equatable {
    /// The SMC D-index (1..4). NOT the physical port number; map via ``uuid``.
    public let channel: Int
    /// The channel's `DxPR` flag: something is drawing on this channel.
    public let present: Bool
    /// Volts the Mac is putting out of the port (`DxJV`).
    public let volts: Double
    /// Amps the Mac is putting out of the port (`DxJI`).
    public let amps: Double
    /// Normalised 32-char lowercase hex of `DxUI`. Internal join key only.
    public let uuid: String

    public var watts: Double { volts * amps }

    public init(channel: Int, present: Bool, volts: Double, amps: Double, uuid: String) {
        self.channel = channel
        self.present = present
        self.volts = volts
        self.amps = amps
        self.uuid = uuid
    }
}

/// The Mac's overall power input, as the SMC reports it on the DC-in rail.
///
/// Desktops (Mac mini / Studio / Pro) have no battery controller, so the laptop
/// pipeline's `AppleSmartBattery.SystemPowerIn` is always 0 there. The figure
/// still exists: the internal PSU feeds the logic board on a DC rail the SMC
/// meters as `VD0R` / `ID0R` / `PDTR`. On a Mac mini M4 that reads ~12.5 V,
/// ~1.8 A, ~23 W.
///
/// This is the *total* the machine pulls from the wall, so it is larger than the
/// sum of the per-port power-OUT channels: the difference is the Mac itself.
public struct SMCSystemPowerInput: Sendable, Equatable {
    /// DC-in voltage (`VD0R`).
    public let volts: Double
    /// DC-in current (`ID0R`).
    public let amps: Double
    /// DC-in total power (`PDTR`), or `volts * amps` when `PDTR` is absent.
    public let watts: Double

    public init(volts: Double, amps: Double, watts: Double) {
        self.volts = volts
        self.amps = amps
        self.watts = watts
    }
}

/// Reads the SMC per-port power channels via the AppleSMC user client.
///
/// This is the app's first SMC read. Every other watcher reads IOKit registry
/// *properties*; this opens a user client (`IOServiceOpen` on `AppleSMC`) and
/// calls a struct method, the long-standing public ABI used by powermetrics,
/// smcFanControl and libsmc. The main app is not sandboxed, so a hardened-
/// runtime Developer ID build is allowed to do this. If the open ever fails
/// (entitlements change, no AppleSMC), every method degrades to "no data"
/// rather than crashing, and the Power Monitor falls back to its no-per-port
/// state.
///
/// Read-only: it only ever reads keys, never writes.
public final class SMCPowerReader {
    private var connection: io_connect_t = 0

    public init() {
        // The kernel reads this struct at fixed C offsets and rejects any other
        // size. Catch a layout regression during development (assert is a
        // debug-build check). In release a bad layout would make the kernel
        // calls fail, and the reader already degrades to no data, so users get
        // the no-per-port fallback rather than a crash.
        assert(
            MemoryLayout<SMCParamStruct>.stride == 80,
            "SMCParamStruct must be 80 bytes to match the AppleSMC ABI, got \(MemoryLayout<SMCParamStruct>.stride)"
        )
    }

    deinit { close() }

    /// Opens the AppleSMC user client. Idempotent: a no-op once open. Returns
    /// false when AppleSMC is missing or the open is refused.
    @discardableResult
    public func open() -> Bool {
        if connection != 0 { return true }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        var conn: io_connect_t = 0
        let kr = IOServiceOpen(service, mach_task_self_, 0, &conn)
        guard kr == KERN_SUCCESS else { return false }
        connection = conn
        return true
    }

    public func close() {
        if connection != 0 {
            IOServiceClose(connection)
            connection = 0
        }
    }

    /// Reads channels `D1..D4`. Opens lazily. Returns `[]` when the SMC can't
    /// be opened or the keys aren't present (older silicon, Mac Pro). A channel
    /// is only returned when it has a usable `DxUI`, since without it the
    /// channel can't be tied to a port.
    public func readPortPowerChannels() -> [SMCPortPowerChannel] {
        guard open() else { return [] }
        var channels: [SMCPortPowerChannel] = []
        for index in 1...4 {
            guard let uuid = readUUID("D\(index)UI"), !uuid.isEmpty else { continue }
            let volts = readFloat("D\(index)JV") ?? 0
            let amps = readFloat("D\(index)JI") ?? 0
            let present = (readUInt8("D\(index)PR") ?? 0) >= 1
            channels.append(SMCPortPowerChannel(
                channel: index,
                present: present,
                volts: Double(volts),
                amps: Double(amps),
                uuid: uuid
            ))
        }
        return channels
    }

    /// Reads the Mac's DC-in power input (`VD0R` / `ID0R` / `PDTR`). Opens
    /// lazily. Returns `nil` when the SMC can't be opened or neither voltage nor
    /// current is present (so callers leave the input card blank rather than
    /// inventing a reading). Watts prefers the dedicated `PDTR` total and falls
    /// back to `volts * amps`.
    ///
    /// Unlike per-port metering, this works on every supported desktop including
    /// M1/M2 Mac minis (the DC-in keys don't depend on the per-port UUID map).
    public func readSystemPowerInput() -> SMCSystemPowerInput? {
        guard open() else { return nil }
        let volts = readFloat("VD0R")
        let amps = readFloat("ID0R")
        guard volts != nil || amps != nil else { return nil }
        let watts = readFloat("PDTR") ?? ((volts ?? 0) * (amps ?? 0))
        return SMCSystemPowerInput(
            volts: Double(volts ?? 0),
            amps: Double(amps ?? 0),
            watts: Double(watts)
        )
    }

    /// Live battery discharge power in milliwatts, read from the SMC battery
    /// rail (`PPBR`). Opens lazily. Returns `nil` when the SMC can't be opened,
    /// the key is absent (a desktop has no battery rail), or the value is
    /// implausible.
    ///
    /// Why this exists: on Apple Silicon, `AppleSmartBattery`'s `BatteryPower` /
    /// `SystemLoad` do not update under load (the fuel gauge holds a value for
    /// tens of seconds), so a battery-discharge figure read from there sits
    /// stale. `PPBR` is the live battery rail (updates ~1 Hz, tracks load);
    /// confirmed on M5 Pro and present on every Apple Silicon laptop generation
    /// in the probe corpus. Callers prefer this on battery and fall back to the
    /// gauge when it returns `nil`.
    public func readBatteryPowerMW() -> Int? {
        guard open() else { return nil }
        guard let watts = readFloat("PPBR") else { return nil }
        // Guard against an absent/garbage key: real discharge is a few watts to
        // tens of watts (the highest Apple Silicon MacBook draws well under 100 W
        // sustained, so 200 W is a safe ceiling). Anything negative or above it
        // means the wrong key on this silicon; fall back to the gauge.
        guard watts >= 0, watts < 200 else { return nil }
        return Int((Double(watts) * 1000).rounded())
    }

    // MARK: - Key reads

    /// `flt` keys (`DxJV`, `DxJI`): a 4-byte IEEE float in native (little-
    /// endian) byte order on Apple Silicon, so the bytes load straight into a
    /// `Float` bit pattern.
    private func readFloat(_ key: String) -> Float? {
        guard let bytes = readKey(key) else { return nil }
        return Self.decodeFloat(bytes)
    }

    /// Decode an SMC `flt` payload. Returns nil for short payloads and for
    /// non-finite values (infinity, NaN). An uninitialised or garbage SMC
    /// channel can carry an inf/NaN bit pattern; letting it through would
    /// reach `Int(...)` unit conversions downstream, which trap on
    /// non-finite doubles. nil makes the callers' `?? 0` fallbacks handle
    /// it like any other absent reading. Internal (not private) so the
    /// decode is unit-testable without SMC hardware.
    static func decodeFloat(_ bytes: [UInt8]) -> Float? {
        guard bytes.count >= 4 else { return nil }
        let bits = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
        let value = Float(bitPattern: bits)
        return value.isFinite ? value : nil
    }

    /// `ui8` keys (`DxPR`): a single byte.
    private func readUInt8(_ key: String) -> UInt8? {
        guard let bytes = readKey(key), let first = bytes.first else { return nil }
        return first
    }

    /// `hex_` keys (`DxUI`): 16 raw bytes, returned as 32 lowercase hex chars
    /// to match the dash-stripped `AppleHPMDeviceHALType3.UUID` string.
    private func readUUID(_ key: String) -> String? {
        guard let bytes = readKey(key), !bytes.isEmpty else { return nil }
        // A channel with no controller reads all-zero here; treat as absent.
        guard bytes.contains(where: { $0 != 0 }) else { return nil }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - SMC ABI

    /// Reads one SMC key's raw bytes: first ask for its size and type, then
    /// read the value (the same two-step the C probe uses).
    private func readKey(_ key: String) -> [UInt8]? {
        guard let fourCC = Self.fourCC(key) else { return nil }

        var info = SMCParamStruct()
        info.key = fourCC
        info.data8 = Self.cmdGetKeyInfo
        guard let infoOut = callDriver(&info) else { return nil }
        let size = infoOut.keyInfo.dataSize
        guard size > 0 else { return nil }

        var read = SMCParamStruct()
        read.key = fourCC
        read.keyInfo.dataSize = size
        read.keyInfo.dataType = infoOut.keyInfo.dataType
        read.data8 = Self.cmdReadKey
        guard let readOut = callDriver(&read) else { return nil }

        let count = Int(min(size, 32))
        var value = readOut.bytes
        return withUnsafeBytes(of: &value) { Array($0.prefix(count)) }
    }

    private func callDriver(_ input: inout SMCParamStruct) -> SMCParamStruct? {
        guard connection != 0 else { return nil }
        var output = SMCParamStruct()
        var outputSize = MemoryLayout<SMCParamStruct>.stride
        let kr = IOConnectCallStructMethod(
            connection,
            Self.kernelIndex,
            &input,
            MemoryLayout<SMCParamStruct>.stride,
            &output,
            &outputSize
        )
        return kr == KERN_SUCCESS ? output : nil
    }

    /// Packs a 4-character key into its FourCC `UInt32` (MSB first).
    static func fourCC(_ key: String) -> UInt32? {
        let scalars = Array(key.unicodeScalars)
        guard scalars.count == 4 else { return nil }
        var value: UInt32 = 0
        for scalar in scalars {
            guard scalar.value <= 0xFF else { return nil }
            value = (value << 8) | UInt32(scalar.value)
        }
        return value
    }

    private static let kernelIndex: UInt32 = 2
    private static let cmdReadKey: UInt8 = 5
    private static let cmdGetKeyInfo: UInt8 = 9
}

// MARK: - AppleSMC user-client ABI structs
//
// These mirror the C layout used by powermetrics / smcFanControl byte-for-byte.
// Field order and types must not change: the kernel reads this struct at fixed
// offsets. `MemoryLayout<SMCParamStruct>.stride` must be 80 bytes.

private struct SMCVersion {
    var major: UInt8 = 0
    var minor: UInt8 = 0
    var build: UInt8 = 0
    var reserved: UInt8 = 0
    var release: UInt16 = 0
}

private struct SMCPLimitData {
    var version: UInt16 = 0
    var length: UInt16 = 0
    var cpuPLimit: UInt32 = 0
    var gpuPLimit: UInt32 = 0
    var memPLimit: UInt32 = 0
}

private struct SMCKeyInfoData {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
}

/// A 32-byte payload buffer as a homogeneous tuple (the C `char bytes[32]`).
private typealias SMCBytes = (
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
)

private struct SMCParamStruct {
    var key: UInt32 = 0
    var vers = SMCVersion()
    var pLimit = SMCPLimitData()
    var keyInfo = SMCKeyInfoData()
    // C keeps `keyInfo`'s 3-byte trailing padding before `result`; Swift would
    // otherwise pack `result` into it and shrink the struct to 76 bytes, which
    // the kernel rejects. This explicit pad restores the C offsets so the total
    // is 80 (asserted in `init()`).
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: SMCBytes = (
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0
    )
}
