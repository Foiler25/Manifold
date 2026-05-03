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
// AboutPane.swift
//
// Phase 14 settings pane per SPEC §13: app version, copyright,
// GitHub repo link, GPL-3.0 license link. Read-only; no @AppStorage.

import SwiftUI

struct AboutPane: View {

    var body: some View {
        VStack(alignment: .center, spacing: 14) {
            Image(systemName: "cable.connector.horizontal")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
                .padding(.top, 24)

            Text("Manifold")
                .font(.title.weight(.semibold))

            Text(versionLine)
                .font(.body.monospacedDigit())
                .foregroundStyle(.secondary)

            Text("settings.about.copyright")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider().padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 8) {
                Link(destination: URL(string: "https://github.com/Foiler25/Manifold")!) {
                    Label("settings.about.github", systemImage: "link")
                }
                Link(destination: URL(string: "https://www.gnu.org/licenses/gpl-3.0.html")!) {
                    Label("settings.about.license", systemImage: "doc.text")
                }
            }

            Spacer()
        }
        .padding()
        .frame(minWidth: 460, minHeight: 380)
        .multilineTextAlignment(.center)
    }

    /// "Version 1.2.3 (45)" assembled from `Info.plist`. Falls
    /// back to "Version unknown" when the dictionary is missing
    /// (shouldn't happen in production; defensive for tests +
    /// previews).
    private var versionLine: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String
        let build = info["CFBundleVersion"] as? String
        switch (short, build) {
        case (let s?, let b?):
            return String(format: NSLocalizedString("settings.about.version.full", comment: ""), s, b)
        case (let s?, nil):
            return String(format: NSLocalizedString("settings.about.version.short", comment: ""), s)
        default:
            return NSLocalizedString("settings.about.version.unknown", comment: "")
        }
    }
}

#Preview("AboutPane") {
    AboutPane()
}
