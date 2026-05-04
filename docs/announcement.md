# Manifold 0.1.0 — first public release

**Draft. Brandon publishes when ready.** This file is the
announcement copy maintained alongside the code; edit before
pushing to wherever the announcement lives (Mastodon, Bluesky,
HN, /r/macapps, the Manifold GitHub Discussions, etc.).

---

## Tweet / Bluesky / Mastodon (≤300 chars)

> 🔌 Just released **Manifold 0.1.0** — a free, open-source macOS
> menu bar app that visualizes USB and Thunderbolt connections in
> real time. Live power draw, link speed, hot-plug detection,
> diagnostics for power deficits + cable bottlenecks. 100% local.
> macOS 26+. GPL-3.0.
>
> https://github.com/Foiler25/Manifold

## Hacker News / /r/macapps post (medium-form)

**Title:** Show HN: Manifold — Live USB and Thunderbolt
visualizer for macOS (Swift 6, GPL-3.0)

**Body:**

I've been wanting a modern replacement for ViewPorts since macOS
killed it, so I built one. Manifold lives in your menu bar and shows
every USB and Thunderbolt device currently connected to your Mac,
with live per-port power draw, link speed, and hot-plug
notifications. Daisy chains nest correctly, displays show
resolution + refresh rate, and a diagnostic engine flags common
problems (USB 3 device on USB 2 link, power deficit, cable
bottleneck on TB4 hardware, etc.).

It's a real Mac app: native SwiftUI throughout, App Intents for
Shortcuts integration, WidgetKit widgets for desktop and Control
Center, a SQLite-backed event/sample log with retention sliders,
CSV/JSON export. The standalone window has a topology browser plus
a history view; the popover keeps the at-a-glance read.

100% local — no telemetry, no analytics, no cloud sync. The only
outbound network call is Sparkle's appcast check for updates. The
unsandboxed model is the trade-off that makes this possible at all
(IOKit access is the whole point); the entitlements explicitly
disable just library validation, keeping the rest of the
hardened-runtime constraints in place.

Tech stack: Swift 6 strict concurrency, SwiftUI primary with an
AppKit shim for `NSStatusItem`, IOKit (C-bridged via a small safe
wrapper), GRDB.swift for persistence, Swift Charts for the
sparklines, Sparkle for updates. Apple Silicon and Intel; macOS
26+ (Tahoe).

GPL-3.0 because Manifold's value is its USB/TB visibility
primitives, and the license keeps any derivative work that ships
those primitives also shipping its source. PRs welcome — see
CONTRIBUTING.md for the developer setup.

**Repo:** https://github.com/Foiler25/Manifold
**Download:** https://github.com/Foiler25/Manifold/releases
**Architecture writeup:** https://github.com/Foiler25/Manifold/blob/main/docs/architecture.md

## Long-form blog post (optional)

If you want to write a longer launch post, the structure that
worked for similar tools:

1. **The problem.** What were you stuck doing before Manifold?
   ("Pulled out my MacBook to debug a USB-C dock and had no idea
   which port was overcommitted…") Concrete user scenarios.
2. **The other tools you tried.** ViewPorts (dead), system
   profiler (one-shot, no telemetry), `ioreg` (fine if you like
   reading XML).
3. **The shape Manifold landed on.** Menu bar for at-a-glance,
   standalone window for deep work, widgets for ambient awareness.
   100% local because the data is sensitive (device serials reveal
   which laptop you're using; that should never leave the Mac).
4. **The diagnostic engine.** Five rules in v0.1; the engine is
   pluggable (each rule is a `(graph) -> [Diagnostic]` function),
   so contributors can add rules in a single PR.
5. **What's next.** Live network visualizer? No — Manifold is
   physical-only by design. More diagnostic rules, more historical
   chart depth, maybe a TopDevicesWidget desktop-large variant.
6. **License + contribution.** GPL-3.0, PRs welcome, CONTRIBUTING.md
   has the full guide.

## Changelog (for the GitHub release body)

Pulled from the actual `git log` between tags. For the v0.1.0 launch:

```
Initial public release.

Features:
- Live USB + Thunderbolt device tree per host, with stable per-port
  IDs across reconnects.
- 1 Hz power + link-speed telemetry per device, with 60-sample
  sparkline history.
- Hot-plug detection via IOKit notifications.
- Native macOS notifications for connect / disconnect / diagnostic.
- Diagnostic engine with 5 initial rules (running-at-usb-2,
  power-deficit, cable-bottleneck, daisy-chain-depth, hub-overcommit).
- Persistent event + telemetry history (SQLite, GRDB-backed) with
  user-tunable retention.
- CSV and JSON export of event log + telemetry samples.
- 5 App Intents (Shortcuts) for connected devices, power draw,
  active diagnostics, watch-for-device-connect, export-topology.
- Three widgets: desktop small (count + power), desktop medium
  (top 4 with sparklines), Control Center (tap → opens popover).
- Settings: sample rate, theme, launch-at-login, notifications,
  retention, Sparkle update channel.
- Onboarding sheet on first launch.
- VoiceOver labels throughout; ⌘1/⌘2/⌘3 jumps to main window tabs.
- Sparkle auto-update with EdDSA-signed appcast.

Requirements: macOS 26.0+. Apple Silicon and Intel.

License: GPL-3.0.
```

---

## Channels to post

- [ ] Manifold GitHub Releases page (built-in to the tag push)
- [ ] Mastodon
- [ ] Bluesky
- [ ] Hacker News (Show HN)
- [ ] /r/macapps
- [ ] /r/swift
- [ ] iOS Dev Weekly newsletter (submit via their tip form)
- [ ] Manifold project Discussion at https://github.com/Foiler25/Manifold/discussions
