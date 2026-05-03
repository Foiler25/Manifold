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
// Snapshot.swift
//
// Per SPEC §12.2 + §12.3 + §12.4. Top-level snapshot enum that
// future-proofs the on-disk format: the widget reads the version
// tag first and falls back to a "no data" entry when it sees a
// version it doesn't understand. Adding `case v2(SnapshotV2)`
// later doesn't break Phase-13-vintage widget builds.
//
// Atomic write per SPEC §12.3: write a uniquely-named temp file
// in the same directory, then `FileManager.replaceItemAt`. Same
// directory matters because `replaceItemAt` is atomic only on the
// same filesystem; cross-FS would silently fall back to copy+delete.

public import Foundation

public enum Snapshot: Sendable, Equatable {

    case v1(SnapshotV1)

    /// SPEC §12.2 names this `appGroupID` and assumes a sandboxed
    /// `~/Library/Group Containers/<id>/` path. Phase 13 ships
    /// without the App Group entitlement (would require a
    /// provisioning profile + break ad-hoc signing per DECISIONS.md
    /// D11), so the constant is preserved as a SPEC-compliance
    /// marker but the on-disk path resolves to
    /// `~/Library/Application Support/com.Loofa.Manifold/` instead.
    /// Both processes run unsandboxed as the user's uid; the widget
    /// reads the same path the host app writes.
    public static let appGroupID = "group.com.Loofa.Manifold"

    /// Filename used in the resolved container directory.
    public static let filename = "snapshot.json"

    // MARK: - Resolved container

    /// `~/Library/Application Support/com.Loofa.Manifold/`. Used by
    /// both the host app's `SnapshotPublisher` and the widget
    /// extension's `SnapshotProvider`. Returns nil only when the
    /// home directory + Application Support resolution fails (rare;
    /// requires a broken sandbox or zero-permission home dir).
    public static func resolvedContainerURL() -> URL? {
        guard let appSupport = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        let dir = appSupport.appendingPathComponent("com.Loofa.Manifold", isDirectory: true)
        // Best-effort directory creation; silently ignore if it
        // already exists or if creation fails (the subsequent
        // write will surface the error with a useful message).
        try? FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true,
            attributes: nil
        )
        return dir
    }

    // MARK: - Convenience accessors

    /// Schema version stamped on whichever case is active.
    public var schemaVersion: Int {
        switch self {
        case .v1(let payload): return payload.schemaVersion
        }
    }

    // MARK: - Write

    /// Atomic write per SPEC §12.3. `containerURL` should be the
    /// App Group container directory (host app side); the snapshot
    /// is encoded into `containerURL/<filename>`.
    ///
    /// Throws on any disk-side failure (out-of-space, permission
    /// denied, etc.). Caller is expected to log + drop — the
    /// next snapshot tick will retry.
    public func write(to containerURL: URL) throws {
        let target = containerURL.appendingPathComponent(Self.filename)
        let temp = containerURL.appendingPathComponent(
            ".\(Self.filename).tmp.\(UUID().uuidString)"
        )

        let data = try SnapshotCodec.encode(self)
        try data.write(to: temp, options: .atomic)

        do {
            // `replaceItemAt` returns the new URL on success. We
            // ignore it because we already know the target path
            // and the on-disk file is what every reader sees. If
            // the target doesn't exist yet the replace falls back
            // to a plain rename, which is what we want on first
            // write.
            _ = try FileManager.default.replaceItemAt(target, withItemAt: temp)
        } catch {
            // Replace failed — clean up the temp so we don't leak
            // stray .tmp files in the App Group directory.
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
    }

    // MARK: - Load

    /// Read + decode whichever schema version is on disk. Tolerant
    /// of unknown future versions per SPEC §12.4: a v2 file landed
    /// by a newer Manifold against a Phase-13-vintage widget binary
    /// surfaces here as `LoadError.unknownSchemaVersion(2)`; the
    /// widget timeline provider catches it and renders a placeholder
    /// entry.
    public static func load(from containerURL: URL) throws -> Snapshot {
        let target = containerURL.appendingPathComponent(Self.filename)
        let data = try Data(contentsOf: target)
        do {
            return try SnapshotCodec.decode(data)
        } catch SnapshotCodec.Error.unknownSchemaVersion(let v) {
            throw LoadError.unknownSchemaVersion(v)
        }
    }

    /// Public errors thrown from `load(from:)`. Widget extensions
    /// pattern-match against this to render a placeholder for
    /// future-snapshot files they don't understand. Disk-side
    /// errors (file not found, permission denied) propagate as the
    /// underlying `CocoaError` rather than getting wrapped — the
    /// widget treats both shapes the same way (no-data fallback).
    public enum LoadError: Error, Equatable {
        case unknownSchemaVersion(Int)
    }
}
