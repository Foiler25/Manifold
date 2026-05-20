# Manifold

![license](https://img.shields.io/badge/license-GPL--3.0-blue)
![platform](https://img.shields.io/badge/macOS-26.0%2B-lightgrey)
![swift](https://img.shields.io/badge/Swift-6-orange)

**Every port, mapped.**

A free, open-source macOS app that visualizes physical USB and
Thunderbolt connections in real time, with per-port power draw and
link-speed telemetry. Menu bar utility and standalone window app
in one — no telemetry, no network, no sandbox compromises.

---

## Features

- **Live device tree per host.** USB controllers → physical ports
  (P1, P2, …) → connected devices → daisy-chained children. Stable
  per-port labels survive reconnects.
- **Per-device telemetry.** Real-time power draw (watts), negotiated
  link speed, sparkline history (last 60 samples).
- **Hot-plug detection.** IOKit-backed events fire within ~100 ms
  of connect / disconnect, with native macOS notifications.
- **Daisy-chain awareness.** Thunderbolt downstream-of-downstream
  devices nest correctly in the topology.
- **Diagnostics engine** (5 rules ship in the initial set):
  - `Running @ USB 2.0` — USB 3.x device on a USB 2.0 link.
  - `Power deficit` — device requesting more than the port supplies.
  - `Cable bottleneck` — TB4 device on a TB3 link.
  - `Daisy-chain depth` — chain past Apple's 6-device TB limit.
  - `Hub overcommit` — sum of downstream draw exceeds the hub budget.
- **Cable diagnostics** (Phase 21). Per-port USB-C card showing PD
  power profile, transport (USB 2 / 3 / 4 / Thunderbolt), e-marker
  fingerprint, and trust signals. Apple Silicon only.
- **Display info.** Connected displays show resolution, refresh rate,
  panel type, main-display flag, built-in flag.
- **Persistent history.** SQLite-backed event log + downsampled
  telemetry. 24 h raw / 30 d 1-min / 1 y 1-hour by default; tunable.
- **Export.** Event log + samples as CSV (Excel + Numbers compatible),
  full topology as schema-versioned JSON. File ▸ Export… (Cmd-E).
- **Shortcuts (App Intents).** Five intents — `Get Connected
  Devices`, `Get Power Draw`, `Get Active Diagnostics`,
  `Watch For Device Connect`, `Export Topology Snapshot`.
- **Widgets.** Desktop small (count + power), desktop medium (top 4
  devices with sparklines), Control Center (tap → opens popover).
- **Settings panel.** Sample rate, theme, notification toggles,
  retention sliders, launch-at-login, Sparkle update channel.
- **100 % local.** No network calls except Sparkle's update check.
  Privacy explicit in the onboarding sheet.
- **Physical only.** No Wi-Fi, Bluetooth, AirPlay, Continuity, VPN,
  SMB, NFS. Manifold is a USB / Thunderbolt visualizer; the network
  surface is intentionally absent.

---

## Install

### Latest release

1. Download the `.dmg` from the [Releases page](https://github.com/Foiler25/Manifold/releases).
2. Drag `Manifold.app` to `/Applications`.
3. **First launch: right-click → Open** (then click _Open_ in the
   confirmation dialog). macOS Gatekeeper requires this one-time
   approval for ad-hoc-signed apps. Subsequent launches use the
   regular double-click path. _If you see "Manifold can't be opened
   because Apple cannot check it for malicious software", that's the
   prompt — right-click → Open works around it._
4. Manifold lives in the menu bar. Click the icon for the popover;
   open the standalone window via `File ▸ Open Window` or by clicking
   the popover's `Open Manifold` button.

### Updates

Sparkle handles updates automatically. The first launch prompts for
notification permission; subsequent launches check the appcast on
the user's chosen schedule (Settings ▸ Updates ▸ Channel: stable /
beta). You can force a check via `Settings ▸ Updates ▸ Check for
updates now`.

### Build from source

See [CONTRIBUTING.md](CONTRIBUTING.md) for the full developer setup.
Short version: clone the repo, open `Manifold.xcodeproj` in Xcode 26+,
let it resolve the SPM packages (GRDB + Sparkle), `Cmd-R` to build
and run.

---

## Architecture

High-level: six-layer stack (Discovery → Events → Telemetry →
Diagnostics → Storage → UI) with `@Observable PortGraph` as the
single source of truth. Detailed walkthrough in
[`docs/architecture.md`](docs/architecture.md).

### Tech stack

| Layer | Pick |
|---|---|
| Language | Swift 6 (strict concurrency) |
| App | SwiftUI primary, AppKit shim for `NSStatusItem` + `NSPopover` |
| Discovery | IOKit (C bridged via small wrapper layer) |
| Storage | GRDB.swift + SQLite |
| Charts | Swift Charts |
| Notifications | UserNotifications |
| Automation | App Intents (Shortcuts) |
| Widgets | WidgetKit (desktop small, desktop medium, Control Center) |
| Auto-update | Sparkle 2.x, EdDSA-signed appcast |

### What's NOT in Manifold

- **No network surface.** Manifold's only outbound call is Sparkle's
  appcast fetch. No analytics, no crash reporting, no telemetry to
  any third party.
- **No sandbox.** Direct distribution gives full IOKit access; the
  unsandboxed model is documented in DECISIONS.md (D10) and gated by
  hardened-runtime + library-validation entitlements.
- **No Wi-Fi / Bluetooth / Continuity / VPN / SMB / NFS.** Manifold
  is a *physical* port visualizer. The exclusion list is intentional;
  the on-screen Diagnostics tab will mention this if a user asks.
- **No App Store distribution.** App Store sandboxing breaks IOKit
  access. Manifold ships via direct download from this repository's
  Releases.

---

## Contributing

Pull requests welcome — see [CONTRIBUTING.md](CONTRIBUTING.md) for
the build setup, test instructions, and PR checklist. Bug reports
and feature requests use the [issue templates](.github/ISSUE_TEMPLATE/).
Conduct expectations are in [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).

---

## License

GPL-3.0. Copyright © 2026 Brandon Villar. See [LICENSE](LICENSE).

The GPL-3.0 choice is deliberate: Manifold's value is its USB/TB
visibility primitives, and the GPL ensures any derivative work that
ships those primitives also ships its source. If you fork Manifold,
your fork stays open.

---

## Acknowledgements

Cable diagnostics derive from
[WhatCable](https://github.com/darrylmorley/whatcable) by Darryl
Morley, originally MIT-licensed and re-licensed under GPL-3.0 as part
of Manifold. The original copyright + permission notice is preserved
verbatim in
[`Manifold/Sources/Cables/ATTRIBUTION.md`](Manifold/Sources/Cables/ATTRIBUTION.md).
