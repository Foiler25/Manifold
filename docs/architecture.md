# Manifold Architecture

This document is the public-facing architectural summary. It captures
the shape of the codebase + the core design decisions without
exposing the internal phase-by-phase Architect/Builder/Reviewer
pipeline that produced it. For the day-to-day "how do I work on
this" guide, see [CONTRIBUTING.md](../CONTRIBUTING.md).

## Layered overview

Manifold's code splits into six layers, bottom up:

```
┌─────────────────────────────────────────────────────────────────┐
│  UI                                                              │
│   • SwiftUI: PopoverRoot, MainWindow (NavigationSplitView),     │
│     Settings panes, ExportSheet, OnboardingSheet, widgets       │
│   • AppKit shim: NSStatusItem, NSPopover                        │
└─────────────────────────────────────────────────────────────────┘
                              ▲
                              │ reads
┌─────────────────────────────────────────────────────────────────┐
│  PortGraph (@MainActor @Observable)                              │
│   • Single source of truth for every UI surface                  │
│   • Hosts → ports → devices, plus diagnostics + telemetry       │
└─────────────────────────────────────────────────────────────────┘
                  ▲                              ▲
       PortEvent  │ apply                writes  │
┌──────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│  Discovery       │    │  Events         │    │  Storage (GRDB) │
│  • USBWalker     │    │  • IOKit        │    │  • Device /     │
│  • TBWalker      │    │    notification │    │    Event /      │
│  • DisplayResolver│   │    port         │    │    Sample repos │
│  • PortGraphBuilder│   │  • EventService │    │  • RetentionPol │
└──────────────────┘    │    AsyncStream  │    │  • Downsampling │
        ▲               └─────────────────┘    └─────────────────┘
        │                       ▲                       ▲
        │                       │                       │
┌──────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│  Diagnostics     │    │  Telemetry      │    │  Snapshot       │
│  • DiagnosticRule│    │  • TelemetrySam │    │  • SnapshotV1   │
│    protocol      │    │    pler (1 Hz)  │    │  • Coordinator  │
│  • Engine +      │    │  • Buffer (60)  │    │  • Publisher    │
│    Registry      │    │  • Lifecycle    │    │  • Atomic write │
│  • 5 rules       │    └─────────────────┘    └─────────────────┘
└──────────────────┘
        │
        ▼
┌─────────────────────────────────────────────────────────────────┐
│  Notifications  │  Automation (App Intents)  │  Sparkle         │
│  • UNUserNotif  │  • 5 intents               │  • Updater       │
│  • per-event    │  • IntentDataSource bridge │    Controller    │
│    toggles      │  • Donor (.attached)       │  • Appcast feed  │
└─────────────────────────────────────────────────────────────────┘
        │                                              │
        ▼                                              ▼
┌─────────────────────────────────────────────────────────────────┐
│  Support primitives                                              │
│  • IOKit safe wrappers (IOObject + scoped iterators +           │
│    NotificationPort + MatchNotificationToken)                   │
│  • Logging (os.Logger, namespaced subsystem)                    │
│  • Concurrency bridges                                          │
└─────────────────────────────────────────────────────────────────┘
```

The arrows are reads / writes against the central `PortGraph`. Every
UI surface (popover, main window, widgets, intents) reads from it;
every IOKit-side change (discovery walks, hot-plug events) writes to
it. The `@Observable` macro plus SwiftUI's tracking machinery does
the propagation.

## ManifoldKit vs Manifold

The repo splits into three buildable targets:

| Target | What lives here | Why |
|---|---|---|
| `ManifoldKit` (framework) | Pure data types: `Host`, `Port`, `Device`, `Diagnostic`, `PortEvent`, `Watts`, `SnapshotV1`, … and their Codable round-trips. | The widget extension can't import IOKit or GRDB; ManifoldKit gives it the snapshot wire format without dragging in OS-touching code. SPM-buildable so `swift test` runs the headless type tests in <1 s on a clean checkout. |
| `Manifold` (app) | Everything else: discovery, events, telemetry, diagnostics, storage, notifications, automation, snapshot publisher, UI, Sparkle. | Where IOKit lives, so where every layer that touches it lives too. |
| `ManifoldWidget` (extension) | Three widgets (`PowerWidget`, `TopDevicesWidget`, `ControlCenterWidget`) + the `SnapshotProvider` that reads `snapshot.json` from the shared container. | Widget extensions run in a separate process with a tight memory budget; isolating them keeps the host app's IOKit + GRDB out of the widget binary. |

The Reviewer enforces a grep invariant on every PR: no raw IOKit C
API call (`IOObjectRelease`, `IOIteratorNext`,
`IORegistryEntryCreateCFProperty`, `IOServiceAddMatchingNotification`,
`IONotificationPortCreate`, etc.) appears outside
`Manifold/Sources/Support/IOKit/`. The wrapper layer holds the
unsafe API in one bounded place + exposes a scoped Swift surface
to every consumer.

## Discovery layer

Three walkers compose into one `PortGraph`:

1. **USBWalker** matches `IOUSBHostDevice` registry entries, reads
   `idVendor` / `idProduct` / `Speed` / `Requested Power` /
   `Available Current` / `iSerialNumber` / `LocationID`.
2. **ThunderboltWalker** matches `IOThunderboltSwitchType2`, reads
   `Route String` / `IOThunderboltLinkType` /
   `IOThunderboltLinkSpeed` / `IOThunderboltLinkWidth`.
3. **DisplayResolver** matches `IODisplayConnect`, reads EDID-
   derived fields where the fixture provides them (live
   `IOFramebuffer` reads are gated behind private entitlements; the
   resolver returns nil for those properties under unsandboxed
   distribution).

`PortGraphBuilder.merge(...)` fuses the three streams + nests by
registry-path prefix matching to produce the host → port →
device → child topology. Every IOKit call hops through `IOKitQueue`
— a singleton actor whose serial executor satisfies SPEC §1's
"dedicated IOKit queue" requirement.

## Event layer

`IOServiceAddMatchingNotification` for `kIOFirstMatchNotification`
and `kIOTerminatedNotification` produces hot-plug callbacks on a
dedicated `Manifold-IOKitRunLoop` thread. The callbacks fan into a
single `AsyncStream<PortEvent>` that the AppDelegate consumer
processes on `@MainActor`:

1. Notification fires (Phase 9 / `NotificationService.handle`).
2. Persistence writes to GRDB (Phase 10 / `EventRepository.write`).
3. `IntentDonor.donateAttachedDevice` for `.attached` events
   (Phase 12 + Phase 15 F25).
4. `PortGraph.apply(event)` mutates the live model.
5. Snapshot coordinator schedules a debounced write (Phase 13).

The order matters: notifications + persistence must see the
*pre-apply* graph for `.detached` device-name resolution to work.

## Diagnostics layer

`DiagnosticRule` protocol: pure `(graph: [Host]) → [Diagnostic]`.
Five rules ship in the initial set:

- `running-at-usb-2` (USB3 device on USB 2.0 link)
- `power-deficit` (request > available)
- `cable-bottleneck` (TB4 device on TB3 link)
- `daisy-chain-depth` (chain > 6)
- `hub-overcommit` (sum of children's draw > hub budget)

`DiagnosticEngine` runs every registered rule between each
discovery walk and the `PortGraph.replace` commit. New diagnostics
fire macOS notifications (deduped by `(target, ruleIdentifier)` so
a re-evaluation that produces the same finding stays quiet).

## Storage layer

GRDB-backed SQLite at
`~/Library/Application Support/com.Loofa.Manifold/manifold.sqlite`
(Phase 13 deviation: SPEC §10 implies the App Group container, but
that requires a provisioning profile that breaks ad-hoc signing per
DECISIONS.md D11 — same trick the snapshot file uses). Three actor
repositories (Device / Event / Sample) wrap the pool. Schema is
frozen at V1; future schema changes append migration files rather
than edit the V1 SQL.

`DownsamplingJob` runs a 10-min `Timer` that promotes raw → 1-min
→ 1-hour aggregates per the user-tunable `RetentionPolicy` (24h /
30d / 1y by default).

## Snapshot wire format

The widget extension reads
`~/Library/Application Support/com.Loofa.Manifold/snapshot.json` —
a `SnapshotV1` struct with `schemaVersion: 1` (frozen forever).
`SnapshotCoordinator` debounces writes at 500 ms (≤2 Hz per SPEC
§18 Phase 13 #3), dedupes on payload-equality (ignoring
`writtenAt`), then atomically writes via temp file + `replaceItemAt`
+ fires `WidgetCenter.shared.reloadAllTimelines()`.

The widget pattern-matches on `Snapshot.LoadError.unknownSchemaVersion`
to render a placeholder for future-version files it doesn't
understand — forward-compat without coupling the widget to every
new SnapshotVN type.

## Concurrency model

Swift 6 strict concurrency throughout. The shape:

- `@MainActor` for everything that touches `@Observable PortGraph`:
  AppDelegate, PortGraph itself, every SwiftUI view, the
  notification + diagnostic coordinators.
- `actor IOKitQueue` (singleton) for IOKit-touching work:
  `usbWalk`, `tbWalk`, `resolveDisplays`, `resolveHostMetadata`.
- `actor` per repository (Device, Event, Sample) for GRDB access.
- `Sendable` everywhere a value crosses an isolation boundary
  (PortEvent, Diagnostic, SnapshotV1, etc.).
- One `@unchecked Sendable` site each in `EventService`,
  `IOKitNotificationCenter`, and `NotificationPortCallbackBox` —
  blessed by SPEC §7 because the underlying state is protected by a
  lock + the C ABI requires a class with Unmanaged identity.

## Privacy and security

- **No outbound network** except Sparkle's appcast fetch.
  Everything else (telemetry, history, exports) is local.
- **No user PII or device serials** in `.notice`-or-above logs.
  Serials may appear at `.debug` for fixture matching during
  development.
- **No analytics, no crash reporting** to any third party.
  Crashes go through the standard macOS crash-reporter path (the
  user can opt in via System Settings → Privacy & Security).
- **Hardened runtime** with library-validation explicitly disabled
  (`com.apple.security.cs.disable-library-validation`) so the
  ad-hoc-signed embedded ManifoldKit framework loads under the
  hardened-runtime constraints we keep (no JIT, no
  DYLD_INSERT_LIBRARIES, no execution of unsigned code).
- **Sandbox: off.** Per BRIEF.md "Sandboxing: None — direct
  distribution gives full IOKit access". The trade-off is documented
  in DECISIONS.md D10; the unsandboxed path is what makes Manifold
  possible at all.

## Build and release

| Trigger | What runs | Where |
|---|---|---|
| Local pre-PR | `xcodebuild test -only-testing:ManifoldTests` + `swift test --package-path ManifoldKit` + (when IOKit changes) `LeakBenchTests` | Maintainer's Mac |
| `git tag v*` | `./build-dmg.sh && ./release-github.sh --publish` | Maintainer's Mac |

The release pipeline runs locally because the Sparkle EdDSA private
key (`keyfile.txt`) lives only on the maintainer's machine, and the
project's `MACOSX_DEPLOYMENT_TARGET` (macOS 26) outpaces the
GitHub-hosted runner labels' Xcode bundling — running the build
gate locally avoids tracking the runner-image promotion schedule.

## Where to look next

| For… | Read… |
|---|---|
| How to build + contribute | [CONTRIBUTING.md](../CONTRIBUTING.md) |
| User-facing feature list | [README.md](../README.md) |
| Filing a bug | [.github/ISSUE_TEMPLATE/bug_report.md](../.github/ISSUE_TEMPLATE/bug_report.md) |
| Filing a feature request | [.github/ISSUE_TEMPLATE/feature_request.md](../.github/ISSUE_TEMPLATE/feature_request.md) |
| How conduct is handled | [CODE_OF_CONDUCT.md](../CODE_OF_CONDUCT.md) |

The internal `SPEC.md`, `DECISIONS.md`, `BUILD_LOG.md`, and
`REVIEW.md` are gitignored — they're working documents for the
agent build pipeline. The architecture summary above is the public
artifact derived from them.
