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
// GetActiveDiagnosticsIntent.swift
//
// Per SPEC §11.2. Returns the current active diagnostic list as
// `[DiagnosticEntity]`. Empty array when no rules have fired.

import AppIntents

struct GetActiveDiagnosticsIntent: AppIntent {

    static let title: LocalizedStringResource = "intent.getActiveDiagnostics.title"
    static let description = IntentDescription(
        "intent.getActiveDiagnostics.description"
    )

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[DiagnosticEntity]> {
        let entities = DiagnosticEntityQuery.allDiagnosticEntities()
        return .result(value: entities)
    }
}
