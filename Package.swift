// swift-tools-version:6.1
//
// Manifold — Package.swift
//
// SPM entry point for the ManifoldKit framework and its unit tests.
//
// Why SPM lives alongside Manifold.xcodeproj:
//   - The main app and widget extension targets need macOS-app entitlements
//     (App Group, NSStatusItem, login item, hardened runtime) and a widget
//     extension lifecycle that SPM does not model directly. Those targets
//     stay in the Xcode project.
//   - ManifoldKit, however, is a pure data-and-codec module that builds
//     headlessly. Exposing it through SPM lets `swift build` and
//     `swift test` from a clean checkout drive the framework + its tests
//     without Xcode involvement, which is exactly what builder.md's
//     static-checks step demands.
//
// Phase 0 deliberately keeps ManifoldKit empty save for a sentinel constant
// and one smoke test. Real types arrive in Phase 2 per SPEC.md §4.

import PackageDescription

// Per-target Swift settings shared by ManifoldKit and its tests.
// Declared before `package` because Package.swift runs top-down as a script.
let phaseZeroSwiftSettings: [SwiftSetting] = [
    // Surfaces missing `any` on protocol existentials — catches API drift
    // before it becomes a Swift 7 hard error.
    .enableUpcomingFeature("ExistentialAny"),
    // Forces explicit `public import` for re-exported modules. Keeps the
    // public surface honest as ManifoldKit gains real types in Phase 2.
    .enableUpcomingFeature("InternalImportsByDefault")
]

let package = Package(
    name: "ManifoldKit",
    platforms: [
        // macOS 26.0 (Tahoe) is the locked minimum per BRIEF.md and SPEC.md
        // criterion `MACOSX_DEPLOYMENT_TARGET = 26.0`. The string form is used
        // because PackageDescription's enum cases lag the OS releases.
        .macOS("26.0")
    ],
    products: [
        .library(name: "ManifoldKit", targets: ["ManifoldKit"])
    ],
    targets: [
        .target(
            name: "ManifoldKit",
            // SPEC.md §3 places ManifoldKit sources at `ManifoldKit/Sources/`
            // (with `Models/`, `Snapshot/`, `Strings/` subdirs in later phases).
            // Pointing the target there keeps the SPM layout and the SPEC's
            // file tree identical instead of forcing a redundant nested dir.
            path: "ManifoldKit/Sources",
            swiftSettings: phaseZeroSwiftSettings
        ),
        .testTarget(
            name: "ManifoldKitTests",
            dependencies: ["ManifoldKit"],
            path: "ManifoldKit/ManifoldKitTests",
            swiftSettings: phaseZeroSwiftSettings
        )
    ],
    // Swift 6 language mode = strict concurrency baseline. Required by
    // builder.md ("strict concurrency: no warnings under Swift 6 strict mode").
    swiftLanguageModes: [.v6]
)
