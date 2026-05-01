// ManifoldKit/Sources/ManifoldKit.swift
//
// ManifoldKit is the leaf data module shared by the Manifold app and the
// ManifoldWidget extension. By design it depends on Foundation and `os.log`
// only — no Combine, no SwiftUI, no IOKit, no AppKit. That isolation is
// what lets the widget extension import this module safely (widgets cannot
// link IOKit) and what keeps `swift build` driving without an Xcode app
// shell underneath it.
//
// Phase 0 status: scaffold only. The real data types (Host, Port, Device,
// Diagnostic, Snapshot codec, …) land in Phase 2 per SPEC.md §4. The single
// `ManifoldKit.specRevision` constant exists so the smoke test has something
// concrete to assert against, and so future phases can fail loudly when the
// SPEC revision and the in-code types drift apart.

import Foundation

/// Module-level namespace for top-of-tree constants and metadata.
///
/// This is intentionally a caseless `enum` rather than a `struct` to make it
/// impossible to instantiate. The only reason to add members here is module
/// metadata that does not belong to any single domain type.
public enum ManifoldKit {
    /// SPEC.md revision this module's types correspond to.
    ///
    /// Bumped by the Builder whenever Phase 2+ updates the data model in a
    /// way that callers should care about. Phase 0 baseline matches
    /// `SPEC.md` revision 1.
    public static let specRevision: Int = 1
}
