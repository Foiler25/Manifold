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

public enum PDO: Codable, Sendable, Equatable {
    case fixed(voltage: Int, maxCurrent: Int)
    // Battery: min and max voltage (50mV units), max power (250mW units) - Table 6.11
    case battery(minVoltage: Int, maxVoltage: Int, maxPower: Int)
    // Variable: min and max voltage (50mV units), max current (10mA units) - Table 6.12
    case variable(minVoltage: Int, maxVoltage: Int, maxCurrent: Int)
    // Programmable Power Supply APDO (PPS, bits 29:28 = 00) - Table 6.13
    case pps(minVoltage: Int, maxVoltage: Int, maxCurrent: Int)
    // Extended Power Range Adjustable Voltage Supply APDO (bits 29:28 = 01) - Table 6.16
    case eprAvs(minVoltage: Int, maxVoltage: Int, pdp: Int)
    // Standard Power Range Adjustable Voltage Supply APDO (bits 29:28 = 10) - Table 6.15
    case sprAvs(maxCurrent15V: Int, maxCurrent20V: Int)

    public static func decode(rawValue: UInt32) -> PDO {
        switch (rawValue >> 30) & 0x3 {
        case 0:
            // Fixed supply: bits 19..10 = voltage (50mV), bits 9..0 = max current (10mA)
            let voltage = Int((rawValue >> 10) & 0x3FF) * 50
            let maxCurrent = Int(rawValue & 0x3FF) * 10
            return .fixed(voltage: voltage, maxCurrent: maxCurrent)
        case 1:
            // Battery: bits 29..20 = max voltage (50mV), bits 19..10 = min voltage (50mV), bits 9..0 = max power (250mW)
            let maxVoltage = Int((rawValue >> 20) & 0x3FF) * 50
            let minVoltage = Int((rawValue >> 10) & 0x3FF) * 50
            let maxPower = Int(rawValue & 0x3FF) * 250
            return .battery(minVoltage: minVoltage, maxVoltage: maxVoltage, maxPower: maxPower)
        case 2:
            // Variable: bits 29..20 = max voltage (50mV), bits 19..10 = min voltage (50mV), bits 9..0 = max current (10mA)
            let maxVoltage = Int((rawValue >> 20) & 0x3FF) * 50
            let minVoltage = Int((rawValue >> 10) & 0x3FF) * 50
            let maxCurrent = Int(rawValue & 0x3FF) * 10
            return .variable(minVoltage: minVoltage, maxVoltage: maxVoltage, maxCurrent: maxCurrent)
        default:
            // APDO: subtype in bits 29..28 determines layout
            switch (rawValue >> 28) & 0x3 {
            case 0:
                // PPS (Table 6.13): bits 24..17 = max voltage (100mV), bits 15..8 = min voltage (100mV), bits 6..0 = max current (50mA)
                let maxVoltage = Int((rawValue >> 17) & 0xFF) * 100
                let minVoltage = Int((rawValue >> 8) & 0xFF) * 100
                let maxCurrent = Int(rawValue & 0x7F) * 50
                return .pps(minVoltage: minVoltage, maxVoltage: maxVoltage, maxCurrent: maxCurrent)
            case 1:
                // EPR AVS (Table 6.16): bits 25..17 = max voltage (100mV), bits 15..8 = min voltage (100mV), bits 7..0 = PDP (1W)
                let maxVoltage = Int((rawValue >> 17) & 0x1FF) * 100
                let minVoltage = Int((rawValue >> 8) & 0xFF) * 100
                let pdp = Int(rawValue & 0xFF) * 1000
                return .eprAvs(minVoltage: minVoltage, maxVoltage: maxVoltage, pdp: pdp)
            case 2:
                // SPR AVS (Table 6.15): bits 19..10 = max current at 15V (10mA), bits 9..0 = max current at 20V (10mA)
                let maxCurrent15V = Int((rawValue >> 10) & 0x3FF) * 10
                let maxCurrent20V = Int(rawValue & 0x3FF) * 10
                return .sprAvs(maxCurrent15V: maxCurrent15V, maxCurrent20V: maxCurrent20V)
            default:
                // Subtype 11 is invalid per spec; fall back to PPS layout so we still show something
                let maxVoltage = Int((rawValue >> 17) & 0xFF) * 100
                let minVoltage = Int((rawValue >> 8) & 0xFF) * 100
                let maxCurrent = Int(rawValue & 0x7F) * 50
                return .pps(minVoltage: minVoltage, maxVoltage: maxVoltage, maxCurrent: maxCurrent)
            }
        }
    }
}

public struct PDContract: Codable, Sendable, Equatable {
    public let activeRdo: UInt32
    public let pdoList: [PDO]
    public let pdoCount: Int
    public let maxPower: Int
    public let capMismatch: Bool
    public let srcTypes: Int

    public init(
        activeRdo: UInt32,
        pdoList: [PDO],
        pdoCount: Int,
        maxPower: Int,
        capMismatch: Bool,
        srcTypes: Int
    ) {
        self.activeRdo = activeRdo
        self.pdoList = pdoList
        self.pdoCount = pdoCount
        self.maxPower = maxPower
        self.capMismatch = capMismatch
        self.srcTypes = srcTypes
    }
}

public struct PortHealthCounters: Codable, Sendable, Equatable {
    public let attachCount: Int
    public let detachCount: Int
    public let hardResetCount: Int
    public let shortDetectCount: Int
    public let i2cErrCount: Int
    public let dataRoleSwapCount: Int
    public let dataRoleSwapFailCount: Int
    public let pwrRoleSwapCount: Int
    public let pwrRoleSwapFailCount: Int
    public let vdoFailCount: Int
    public let fetEnableFailCount: Int
    public let fetStatus: UInt8
    public let pdState: UInt8
    public let dnState: UInt8

    public init(
        attachCount: Int,
        detachCount: Int,
        hardResetCount: Int,
        shortDetectCount: Int,
        i2cErrCount: Int,
        dataRoleSwapCount: Int,
        dataRoleSwapFailCount: Int,
        pwrRoleSwapCount: Int,
        pwrRoleSwapFailCount: Int,
        vdoFailCount: Int,
        fetEnableFailCount: Int,
        fetStatus: UInt8,
        pdState: UInt8,
        dnState: UInt8
    ) {
        self.attachCount = attachCount
        self.detachCount = detachCount
        self.hardResetCount = hardResetCount
        self.shortDetectCount = shortDetectCount
        self.i2cErrCount = i2cErrCount
        self.dataRoleSwapCount = dataRoleSwapCount
        self.dataRoleSwapFailCount = dataRoleSwapFailCount
        self.pwrRoleSwapCount = pwrRoleSwapCount
        self.pwrRoleSwapFailCount = pwrRoleSwapFailCount
        self.vdoFailCount = vdoFailCount
        self.fetEnableFailCount = fetEnableFailCount
        self.fetStatus = fetStatus
        self.pdState = pdState
        self.dnState = dnState
    }
}

/// TPS6598x interrupt event types observed in PortControllerEvtBuffer.
/// Codes from the TPS6598x Host Interface TRM and empirical traces.
public enum PDEvent: Codable, Sendable, Equatable {
    case plugInsertOrRemoval
    case prSwapComplete
    case drSwapComplete
    case sourceCapRx
    case statusUpdate
    case pdStatusUpdate
    case usb2Plug
    case powerStatusUpdate
    case appLoaded
    case rxIdSop
    case uvdmStatusUpdate
    case uvdmEnum
    case sleepWake
    case alert
    case unknown(UInt8)

    public init(rawValue: UInt8) {
        switch rawValue {
        case 0x01: self = .plugInsertOrRemoval
        case 0x02: self = .prSwapComplete
        case 0x03: self = .drSwapComplete
        case 0x1a: self = .sourceCapRx
        case 0x30: self = .statusUpdate
        case 0x31: self = .pdStatusUpdate
        case 0x37: self = .usb2Plug
        case 0x3f: self = .powerStatusUpdate
        case 0x40: self = .appLoaded
        case 0x48: self = .rxIdSop
        case 0x5e: self = .uvdmStatusUpdate
        case 0x5f: self = .uvdmEnum
        case 0xf0: self = .sleepWake
        case 0xf1: self = .alert
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: UInt8 {
        switch self {
        case .plugInsertOrRemoval: return 0x01
        case .prSwapComplete: return 0x02
        case .drSwapComplete: return 0x03
        case .sourceCapRx: return 0x1a
        case .statusUpdate: return 0x30
        case .pdStatusUpdate: return 0x31
        case .usb2Plug: return 0x37
        case .powerStatusUpdate: return 0x3f
        case .appLoaded: return 0x40
        case .rxIdSop: return 0x48
        case .uvdmStatusUpdate: return 0x5e
        case .uvdmEnum: return 0x5f
        case .sleepWake: return 0xf0
        case .alert: return 0xf1
        case .unknown(let value): return value
        }
    }
}

public struct PDEventTrace: Codable, Sendable, Equatable {
    public let rawBuffer: Data
    public let events: [PDEvent]

    public init(rawBuffer: Data, events: [PDEvent]) {
        self.rawBuffer = rawBuffer
        self.events = events
    }
}

public struct VDMIdentity: Codable, Sendable, Equatable {
    public let vendorId: Int
    public let productId: Int
    public let bcdDevice: Int
    public let specRevision: Int
    public let vdos: [Data]
    public let productType: Int?
    public let productTypeDescription: String?

    public init(
        vendorId: Int,
        productId: Int,
        bcdDevice: Int,
        specRevision: Int,
        vdos: [Data],
        productType: Int?,
        productTypeDescription: String?
    ) {
        self.vendorId = vendorId
        self.productId = productId
        self.bcdDevice = bcdDevice
        self.specRevision = specRevision
        self.vdos = vdos
        self.productType = productType
        self.productTypeDescription = productTypeDescription
    }

    /// Reads `vdos[3]` as a little-endian UInt32 and returns its value,
    /// or nil when VDO[3] is absent or malformed. Used by the diagnostic
    /// view to check the SOP'' Controller Present bit without depending on
    /// the USBPDSOP / PDVDO decode path.
    public var cableVDO3Value: UInt32? {
        guard vdos.count > 3, vdos[3].count == 4 else { return nil }
        let b = vdos[3]
        return UInt32(b[0]) | (UInt32(b[1]) << 8) | (UInt32(b[2]) << 16) | (UInt32(b[3]) << 24)
    }

    /// True when the cable's ID Header self-reports as passive (Product Type = 3)
    /// but VDO[3] bit 3 is set. Mirrors `USBPDSOP.hasActiveLayoutContradiction`.
    /// Used in the Pro diagnostic view which works from `VDMIdentity` rather
    /// than `USBPDSOP`.
    public var hasActiveLayoutContradiction: Bool {
        guard productType == 3, let vdo3 = cableVDO3Value else { return false }
        return (vdo3 >> 3) & 1 == 1
    }
}
