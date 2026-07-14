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
// ─────────────────────────────────────────────────────────────────────
// PDContractInspector.swift

import SwiftUI

struct PDContractInspector: View {
    let contract: PDContract

    var body: some View {
        DisclosureGroup("PD contract · \(PowerUnitFormatter.watts(contract.maxPower))") {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(contract.pdoList.enumerated()), id: \.offset) { index, pdo in
                    HStack {
                        Image(systemName: index == activeIndex ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(index == activeIndex ? Color.accentColor : Color.secondary)
                        Text(PowerUnitFormatter.pdoLabel(pdo))
                            .font(.caption.monospacedDigit())
                    }
                }
                if contract.capMismatch {
                    Label(
                        "Requested power exceeds the advertised profiles",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
            }
            .padding(.top, 6)
        }
        .font(.callout)
    }

    private var activeIndex: Int? {
        let objectPosition = Int((contract.activeRdo >> 28) & 0x7)
        return objectPosition > 0 ? objectPosition - 1 : nil
    }
}

struct PDPowerSourceInspector: View {
    let source: PowerSource

    var body: some View {
        DisclosureGroup("PD profiles") {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(source.options.enumerated()), id: \.offset) { _, option in
                    HStack {
                        Image(systemName: option == source.winning ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(option == source.winning ? Color.accentColor : Color.secondary)
                        Text("\(option.voltsLabel) · \(option.ampsLabel) · \(option.wattsLabel)")
                            .font(.caption.monospacedDigit())
                    }
                }
            }
            .padding(.top, 6)
        }
        .font(.callout)
    }
}

enum PowerUnitFormatter {
    static func watts(_ milliwatts: Int) -> String {
        String(format: "%.1f W", Double(milliwatts) / 1000)
    }

    static func volts(_ millivolts: Int) -> String {
        String(format: "%.2f V", Double(millivolts) / 1000)
    }

    static func amps(_ milliamps: Int) -> String {
        String(format: "%.2f A", Double(milliamps) / 1000)
    }

    static func pdoLabel(_ pdo: PDO) -> String {
        switch pdo {
        case let .fixed(voltage, current):
            String(localized: "Fixed · \(volts(voltage)) · \(amps(current))")
        case let .battery(minimum, maximum, power):
            String(localized: "Battery · \(volts(minimum))–\(volts(maximum)) · \(watts(power))")
        case let .variable(minimum, maximum, current):
            String(localized: "Variable · \(volts(minimum))–\(volts(maximum)) · \(amps(current))")
        case let .pps(minimum, maximum, current):
            String(localized: "PPS · \(volts(minimum))–\(volts(maximum)) · \(amps(current))")
        case let .eprAvs(minimum, maximum, power):
            String(localized: "EPR AVS · \(volts(minimum))–\(volts(maximum)) · \(watts(power))")
        case let .sprAvs(current15V, current20V):
            String(localized: "SPR AVS · 15V \(amps(current15V)) · 20V \(amps(current20V))")
        }
    }
}
