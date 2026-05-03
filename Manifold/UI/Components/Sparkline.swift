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
// Sparkline.swift
//
// Compact line chart embedded in each `DeviceRow` showing the last
// ~60 telemetry samples per SPEC.md §18 Phase 5 acceptance #2.
//
// Uses Swift Charts (BRIEF.md locked decision: "Charts: Swift Charts").
// Empty buffer → renders a faint placeholder; one sample → renders a
// flat line at the sampled value (so the row doesn't jump between
// zero and one samples).
//
// Phase 5 plots `watts` only — that's the primary signal users care
// about per the popover layout. Phase 6's window-side device
// inspector may grow a multi-series chart with bitrate alongside.

import SwiftUI
import Charts
import ManifoldKit

struct Sparkline: View {

    /// Samples to plot, oldest-first. Reads `buffer.samples` from a
    /// `TelemetryBuffer` snapshot — the view re-renders when the
    /// PortGraph mutates because PortGraph is `@Observable`.
    let samples: [TelemetrySample]

    var body: some View {
        Group {
            if samples.isEmpty {
                placeholder
            } else {
                chart
            }
        }
        // Phase 15 #4: VoiceOver gets a one-line spoken summary
        // ("Power: 0.5 watts current, 0.3 to 0.7 watts range over
        // last N samples"). The chart's individual marks are
        // intentionally NOT exposed — VO would read 60 separate
        // "0.5", "0.51", "0.49"… which is useless. The summary
        // collapses to the values a screen-reader user actually
        // wants: current, range, sample count.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(NSLocalizedString("accessibility.sparkline.label", comment: ""))
        .accessibilityValue(accessibilityValue)
    }

    /// One-line spoken summary derived from the samples. Empty state
    /// returns "no data yet"; non-empty returns "current X W,
    /// range Y to Z W over last N samples".
    private var accessibilityValue: String {
        let watts = samples.compactMap { $0.watts?.value }
        guard let last = watts.last else {
            return NSLocalizedString("accessibility.sparkline.empty", comment: "")
        }
        let minV = watts.min() ?? last
        let maxV = watts.max() ?? last
        return String(
            format: NSLocalizedString("accessibility.sparkline.summary", comment: ""),
            last, minV, maxV, watts.count
        )
    }

    /// "No data yet" line — faint horizontal stroke at row vertical
    /// center. Keeps the device row's height stable between
    /// zero-samples and N-samples states (no row-height jump on first
    /// sample arrival).
    private var placeholder: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.2))
            .frame(height: 1)
            .frame(width: SparklineConstants.width, height: SparklineConstants.height, alignment: .center)
    }

    /// One LineMark per sample. X = sample index (uniform spacing,
    /// not the actual timestamp — sparklines look cleanest with
    /// equally-spaced points), Y = watts. Bitrate is intentionally
    /// not plotted here; the row's caption already shows the
    /// negotiated protocol name.
    private var chart: some View {
        Chart {
            ForEach(Array(samples.enumerated()), id: \.offset) { index, sample in
                if let watts = sample.watts?.value {
                    LineMark(
                        x: .value("sample", index),
                        y: .value("watts", watts)
                    )
                    .interpolationMethod(.monotone)
                    .foregroundStyle(Color.manifoldAccent)
                }
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartPlotStyle { plot in
            plot.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // A floor of 0 W is correct for power; without an explicit
        // domain Charts auto-scales each tick which makes the line
        // dance dramatically for tiny absolute changes.
        .chartYScale(domain: yDomain)
        .frame(width: SparklineConstants.width, height: SparklineConstants.height)
    }

    /// Auto-zoom Y range with a small headroom above the max value.
    /// Falls back to [0, 1] when the buffer has nil watts only —
    /// produces a flat line at the bottom rather than a Charts
    /// "no domain" warning.
    private var yDomain: ClosedRange<Double> {
        let values = samples.compactMap { $0.watts?.value }
        guard let maxValue = values.max(), maxValue > 0 else {
            return 0...1
        }
        return 0...(maxValue * 1.1)
    }
}

// MARK: - Constants

enum SparklineConstants {
    /// SPEC §13.1 popover is 360 pt wide; row layout reserves ~80 pt
    /// for the sparkline column. Phase 6's window-side inspector chart
    /// will be larger (separate component).
    static let width: CGFloat = 80
    static let height: CGFloat = 18
}

// MARK: - Previews

#Preview("Sparkline — populated") {
    let samples = (0..<60).map { i in
        TelemetrySample(
            timestamp: Date(timeIntervalSince1970: TimeInterval(i)),
            watts: Watts(0.5 + sin(Double(i) / 5.0) * 0.3 + Double(i) * 0.01),
            bitrate: nil
        )
    }
    return Sparkline(samples: samples)
        .padding()
        .background(Color.manifoldSurface)
}

#Preview("Sparkline — empty") {
    Sparkline(samples: [])
        .padding()
        .background(Color.manifoldSurface)
}

#Preview("Sparkline — single sample") {
    Sparkline(samples: [
        TelemetrySample(timestamp: Date(), watts: Watts(2.5), bitrate: nil)
    ])
    .padding()
    .background(Color.manifoldSurface)
}
