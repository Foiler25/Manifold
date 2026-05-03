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
// CSVEncoder.swift
//
// Tiny RFC 4180 CSV serializer. Why not import a CSV library: every
// Phase 11 export is a flat row-shape with at most 8 columns; a
// 30-line encoder reads cleaner than the dependency cost. Stays
// stateless so callers can build a row at a time without owning a
// stream.
//
// Excel + Numbers compatibility per SPEC §18 Phase 11:
//   - CRLF line endings (Excel-on-Windows requires; Numbers/Excel-Mac
//     tolerate).
//   - UTF-8 BOM prefix so Excel-on-Mac reads accented characters
//     correctly (without BOM, Excel-on-Mac mis-decodes as MacRoman
//     for non-ASCII content).
//   - Quote any field containing ", CR, LF, or comma; double-quote
//     any embedded quote character per RFC 4180.

import Foundation

enum CSVEncoder {

    /// CRLF — Excel-on-Windows is the strictest reader; Numbers and
    /// Excel-on-Mac tolerate either.
    static let lineSeparator = "\r\n"

    /// UTF-8 BOM bytes prepended to every CSV file we emit. Without
    /// these three bytes Excel-on-Mac decodes the file as MacRoman.
    static let utf8BOM = Data([0xEF, 0xBB, 0xBF])

    /// Encode one row from an array of fields. Each field is RFC-4180
    /// quoted only when it must be (contains ", CR, LF, or comma);
    /// otherwise emitted verbatim so simple cells stay readable in
    /// raw form.
    static func encodeRow(_ fields: [String]) -> String {
        fields.map(quote(_:)).joined(separator: ",")
    }

    /// Encode a header row + every data row + the line separator.
    /// Returns a `String` ready to be UTF-8-encoded + prefixed with
    /// `utf8BOM` by the caller.
    static func encode(header: [String], rows: [[String]]) -> String {
        var output = encodeRow(header)
        output.append(lineSeparator)
        for row in rows {
            output.append(encodeRow(row))
            output.append(lineSeparator)
        }
        return output
    }

    /// Convenience: header + rows + UTF-8 BOM into one `Data` blob
    /// the caller can write to disk.
    static func encodeData(header: [String], rows: [[String]]) -> Data {
        var data = utf8BOM
        data.append(Data(encode(header: header, rows: rows).utf8))
        return data
    }

    // MARK: - Quoting

    /// RFC 4180 quoting: wrap in `"..."` if the field contains a
    /// reserved character, and escape any literal `"` by doubling it.
    static func quote(_ field: String) -> String {
        if field.contains(where: { $0 == "\"" || $0 == "," || $0 == "\r" || $0 == "\n" }) {
            return "\"\(field.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return field
    }
}
