# Screenshots

This directory holds the public-facing screenshots referenced from
the [README.md](../../README.md). Brandon-side capture procedure
below; the README references PNGs by canonical filename so dropping
fresh captures into this directory updates the README rendering on
GitHub automatically.

## Required captures (Phase 17 acceptance)

SPEC §18 Phase 17 #6 requires at least 4 PNGs. The README references
exactly four canonical filenames:

| Filename | What it shows | Capture procedure |
|---|---|---|
| `popover.png` | Menu bar popover with the live device list | Click the menu bar Manifold icon → use Cmd-Shift-4 then Space + click on the popover. macOS includes a soft drop-shadow that reads cleanly against light-mode wallpapers. |
| `window-topology.png` | Main window, Topology tab | `File ▸ Open Window` (or click the popover's `Open Manifold` button). Stay on the default Topology tab. Cmd-Shift-4 then Space + click on the window. Make sure at least one host has 2+ devices to show the tree depth. |
| `window-history.png` | Main window, History tab | Same window. `Cmd-2` to switch to History (or click the History tab in the tab bar). The capture should show at least 3 events; if the database is empty, plug + unplug a USB device a few times before capturing. |
| `widget-medium.png` | Desktop medium widget showing top 4 devices with sparklines | Right-click desktop → `Edit Widgets` → Manifold → drop the medium widget onto the desktop. Wait ~30 seconds for the sparklines to populate. Cmd-Shift-4 then Space + click on the widget. |

All four are referenced from the README's `## Screenshots` section.
The README also embeds `popover.png` as a hero image at the top, so
that one is the highest-stakes capture.

## Conventions

- **PNG format**, lossless. Drop the @2x retina version directly —
  GitHub renders them at appropriate sizes; the larger source
  preserves quality across viewports.
- **Light mode** for the hero shot (`popover.png`). The other three
  can stay in either appearance — Manifold's dark palette
  (`Color.manifoldSurface`) actually photographs better on dark mode
  for the topology + history screens because the row contrast is
  stronger.
- **No personal device serials visible** in any capture. Manifold's
  popover redacts serials from the row labels by default; double-
  check the History tab capture for any `(serial: …)` strings
  before committing.
- **No badge counters showing pending macOS notifications** in the
  background of any capture — they distract from the Manifold UI
  and date the screenshot to the moment of capture.

## Optional captures

If you want extra screenshots beyond the SPEC-required four, the
README's `## Screenshots` section is a `<table>`; just add rows
referencing the new filenames. Suggested follow-ups:

- `popover-dark.png` — same view, dark mode appearance.
- `widget-small.png` — desktop small widget (count + power).
- `widget-control-center.png` — Control Center widget tile.
- `settings-general.png` / `settings-notifications.png` /
  `settings-history.png` — Settings panes.
- `diagnostic-badge.png` — popover row showing a diagnostic badge
  (e.g., trigger the `running-at-usb-2` rule with a USB 3 drive on
  a USB 2 hub).

## Bulk capture command

For a one-shot recapture of all four hero shots when the UI changes:

```sh
# Open every surface in advance, then Cmd-Shift-5 to bring up the
# screenshot HUD. Use the "Capture Selected Window" mode so the
# system shadow is preserved consistently.
open -a Manifold
sleep 2
# Open the main window, switch to each tab in turn, capture each.
# Drop the four PNGs into this directory with the canonical
# filenames above.
```

There is no automated screenshot pipeline today — the captures are
manual + intentional. A future polish item could wire up
`xcrun simctl ui screenshot` against an SwiftUI-Preview-driven
canvas, but for Phase 17 the manual capture path is the path.
