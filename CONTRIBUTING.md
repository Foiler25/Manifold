# Contributing to Manifold

Thanks for considering a contribution. This file is the
end-to-end "how do I work on Manifold" reference for anyone showing
up to the repo for the first time.

## Quick start

```sh
# 1. Clone
git clone https://github.com/Foiler25/Manifold.git
cd Manifold

# 2. Open in Xcode 26 or later
open Manifold.xcodeproj
# Xcode resolves SPM dependencies (GRDB.swift + Sparkle) on first
# open. Wait for the "Resolved Package Dependencies" step to finish
# before running.

# 3. Build + run
# In Xcode: Cmd-R. Manifold lives in the menu bar; click the icon
# for the popover.

# 4. Run the headless ManifoldKit tests from the command line
swift test --package-path ManifoldKit

# 5. Run the full Xcode test suite (Manifold + LeakBenchTests)
xcodebuild -scheme Manifold -destination 'platform=macOS' \
    -only-testing:ManifoldTests test
```

## Requirements

| Tool | Version |
|---|---|
| macOS | 26.0+ (Tahoe) |
| Xcode | 26.0+ |
| Swift toolchain | 6.0+ (bundled with Xcode 26) |
| `create-dmg` | latest (only needed if you build a DMG: `brew install create-dmg`) |

Manifold builds + runs on Apple Silicon and Intel Macs. CI runs on
GitHub-hosted `macos-15` runners with Xcode 26.

## Project layout

```
Manifold/
├── Manifold/                  Main app target
│   ├── App/                   @main, AppDelegate
│   ├── Sources/               Per-layer subdirs (Discovery, Events,
│   │                          Telemetry, Diagnostics, Storage, …)
│   ├── UI/                    SwiftUI views + AppKit shim
│   └── Resources/             Info.plist, entitlements, asset catalog,
│                              Localizable.xcstrings
├── ManifoldKit/               Headless framework (data types, codecs,
│                              snapshot wire format) — SPM-buildable
├── ManifoldWidget/            WidgetKit extension target
├── ManifoldTests/             XCTest target (per-layer subdirs)
├── ManifoldUITests/           XCUITest target
├── docs/                      Architecture doc, screenshots, announcement
├── scripts/icons/             Icon generator (Swift script + masters)
├── build-dmg.sh               Local DMG packaging + Sparkle EdDSA sign
├── release-github.sh          Local GitHub release pipeline
└── appcast.xml                Sparkle update feed (initial empty seed)
```

The internal Architect/Builder/Reviewer agent docs (`SPEC.md`,
`BRIEF.md`, `DECISIONS.md`, `BUILD_LOG.md`, `REVIEW.md`) are
gitignored — they're working documents for the agent pipeline, not
public artifacts.

## Coding conventions

- **Swift 6 strict concurrency.** All targets compile with
  `-strict-concurrency=complete`. `@MainActor` for anything
  touching `@Observable PortGraph`; actors for the IOKit hop +
  GRDB repositories; `Sendable` everywhere a value crosses an
  isolation boundary.
- **No raw IOKit C calls outside `Manifold/Sources/Support/IOKit/`.**
  The `IOObject` + `withMatchingServices` + `forEachEntry` wrapper
  layer + the `NotificationPort` + `MatchNotificationToken`
  primitives are the blessed surface. The Reviewer enforces this
  via a grep invariant on every PR.
- **Protocol-first dependency injection** for OS-touching surfaces
  (login items, intents, IOKit walks). Tests pass stubs; production
  passes the live impl. Keeps unit tests free of system side
  effects (no real `SMAppService.register` calls in test runs).
- **`@AppStorage` keys are centralized** in
  `Manifold/Sources/Settings/SettingsKeys.swift` (and
  `NotificationPreferences.Key` for notifications, `HistoryPane.Key`
  for the History pane). Renaming a string in one place would
  silently orphan existing user values; the constants give us one
  place to grep + a test that pins the literal strings.
- **Localized strings** in `Manifold/Resources/Localizable.xcstrings`
  with namespaced keys (`popover.*`, `window.tab.*`,
  `settings.*`, `notification.*`, `intent.*`, `accessibility.*`,
  `onboarding.*`, `export.*`, `diagnostic.*`).
- **Comments explain WHY, not WHAT.** A function's body shows what
  it does; comments capture the trade-off, the SPEC reference, the
  past-bug context.
- **Tests pin contracts, not implementation.** Each diagnostic rule
  has positive / negative / edge tests. Each Codable type has a
  round-trip test. Each repository has happy-path + failure-path
  tests. UI tests assert on accessibility identifiers, not pixel
  positions.

## Running the tests

```sh
# Headless ManifoldKit tests (fastest — runs in ~0.02s)
swift test --package-path ManifoldKit

# Full Xcode test suite (Debug build + ManifoldTests target)
xcodebuild -scheme Manifold -destination 'platform=macOS' \
    -only-testing:ManifoldTests test

# Skip the leak bench (saves ~3s per run)
MANIFOLD_SKIP_LEAK_BENCH=1 xcodebuild -scheme Manifold \
    -destination 'platform=macOS' -only-testing:ManifoldTests test

# UI tests (require Accessibility permission; flaky on CLI per macOS,
# stable from Xcode IDE)
xcodebuild -scheme Manifold -destination 'platform=macOS' \
    -only-testing:ManifoldUITests test
```

Manifold doesn't currently have a hosted CI workflow — the
release pipeline (`build-dmg.sh` + `release-github.sh`) is the
build gate. Run the test commands above locally before opening
a PR. `LeakBenchTests` is the per-PR replacement for the
Reviewer-deferred §18.0 LEAK-100x procedure; run it explicitly
with `-only-testing:ManifoldTests/LeakBenchTests` whenever a
change touches IOKit.

## PR checklist

Before opening a PR:

- [ ] All tests pass: `xcodebuild test -only-testing:ManifoldTests` AND `swift test --package-path ManifoldKit`.
- [ ] Both Debug and Release builds succeed.
- [ ] No new raw IOKit C calls outside `Manifold/Sources/Support/IOKit/` (the Reviewer's grep invariant).
- [ ] New `@AppStorage` keys land in `SettingsKeys` (or one of the per-pane key namespaces) AND have a string-pin test.
- [ ] User-facing text uses `LocalizedStringKey` / `NSLocalizedString` and has a key in `Localizable.xcstrings`.
- [ ] New Codable wire-format types have a round-trip test.
- [ ] If the change touches diagnostics, the new rule has positive / negative / edge tests.
- [ ] If the change touches the snapshot wire format, the round-trip test still passes AND the file size stays under 10 KB typical.
- [ ] PR description explains the *why*, not just the diff.

## Release process

Manifold ships via [GitHub Releases](https://github.com/Foiler25/Manifold/releases).
The pipeline runs locally on the maintainer's Mac (no CI involved
beyond the per-PR build/test):

```sh
# 1. Build the DMG, ad-hoc-sign, EdDSA-sign the update artifact
./build-dmg.sh

# 2. Generate the .release-notes-draft.md
./release-github.sh

# 3. Edit RELEASE_NOTES.md by hand (or use Claude)

# 4. Tag, push, create the GitHub release, update appcast.xml
./release-github.sh --publish
```

The Sparkle EdDSA private key lives in `keyfile.txt` (gitignored).
Generated once via Sparkle's `bin/generate_keys`; the matching
public key is in `Manifold/Resources/Info.plist` + hard-coded in
`build-dmg.sh`.

## Filing bugs / requesting features

Use the issue templates:

- [Bug report](.github/ISSUE_TEMPLATE/bug_report.md)
- [Feature request](.github/ISSUE_TEMPLATE/feature_request.md)

When in doubt about scope or design, start with a
[Discussion](https://github.com/Foiler25/Manifold/discussions)
before a PR.

## Code of Conduct

By participating in this project you agree to abide by the
[Contributor Covenant 2.1](CODE_OF_CONDUCT.md).
