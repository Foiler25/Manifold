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
// SnapshotCodec.swift
//
// Per SPEC §12.2. Encode + decode `Snapshot` to/from JSON. The
// on-disk format is a flat object with a top-level `schemaVersion`
// integer + the per-version payload fields. The version tag drives
// the decoder's case dispatch; SPEC §12.4 forward-compat tolerance
// throws on unknown versions so the widget renders a placeholder.
//
// Output shape (V1):
// ```json
// {
//   "schemaVersion": 1,
//   "writtenAt": "2026-05-03T12:34:56.789Z",
//   "totalPowerDraw": 1.23,
//   "connectedDeviceCount": 4,
//   "topDevicesByPower": [...],
//   "activeDiagnosticCount": 0,
//   "lastEventAt": "2026-05-03T12:33:00.123Z"
// }
// ```
//
// Compact in Release (one line, no whitespace) so the file stays
// well under the SPEC §18 Phase 13 "<10KB typical" bound.
// Pretty-printed in Debug for grep-ability when debugging.

internal import Foundation

enum SnapshotCodec {

    // MARK: - Errors

    enum Error: Swift.Error, Equatable {
        /// On-disk file claimed a version this binary doesn't
        /// understand. Widget reader maps this to a placeholder
        /// timeline entry per SPEC §12.4.
        case unknownSchemaVersion(Int)
    }

    // MARK: - Encode

    /// Encode `snapshot` to JSON bytes. Inline the schema version
    /// at the top so the `decode` path can dispatch without first
    /// decoding the whole payload.
    static func encode(_ snapshot: Snapshot) throws -> Data {
        switch snapshot {
        case .v1(let payload):
            return try encoder.encode(payload)
        }
    }

    // MARK: - Decode

    /// Peek at the top-level `schemaVersion`, then decode the
    /// matching payload. Unknown versions throw
    /// `Error.unknownSchemaVersion`.
    static func decode(_ data: Data) throws -> Snapshot {
        let envelope = try decoder.decode(VersionEnvelope.self, from: data)
        switch envelope.schemaVersion {
        case 1:
            return .v1(try decoder.decode(SnapshotV1.self, from: data))
        default:
            throw Error.unknownSchemaVersion(envelope.schemaVersion)
        }
    }

    // MARK: - Codec instances

    /// Pretty in Debug, compact in Release. Pretty adds whitespace
    /// for human-grep'ability during development; compact keeps the
    /// file under the SPEC §18 #10 10KB budget on production
    /// machines with deep docks.
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        #if DEBUG
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        #endif
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    // MARK: - Version envelope

    /// Minimal probe object used to peek at the schema version
    /// without decoding the full payload. Same shape across every
    /// future schema version — only `schemaVersion` is read.
    private struct VersionEnvelope: Decodable {
        let schemaVersion: Int
    }
}
