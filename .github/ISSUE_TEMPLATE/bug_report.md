---
name: Bug report
about: Something behaving wrong? File one of these.
title: "[bug] "
labels: ["bug"]
---

## Summary

<!-- One sentence: what happened, what you expected. -->

## Reproduction

1. Step one
2. Step two
3. Step three
4. Observe: ...

## Expected behavior

<!-- What you thought would happen instead. -->

## Environment

- **Manifold version:** <!-- About pane → "Version X.Y.Z (build N)". -->
- **macOS version:** <!-- Apple menu → About This Mac. -->
- **Mac model:** <!-- e.g. MacBook Pro M3 Max, Mac Studio M2 Ultra. -->
- **Connected devices** (if relevant to the bug): <!-- vendor + model + USB / TB version. -->

## Logs

Output of:

```sh
log show --predicate 'subsystem == "com.Loofa.Manifold"' --last 5m
```

<!-- Paste a representative ~50-line excerpt below. Sensitive serials
     should appear only at the .debug level (Manifold's logging
     policy redacts them above .info); double-check the paste anyway. -->

```
(paste log excerpt here)
```

## Screenshots / screen recordings

<!-- Optional but very welcome — Cmd-Shift-5 captures a region or
     window. Drop the image / mp4 directly into this field. -->

## Anything else?

<!-- Anything you tried, anything you ruled out, anything that
     surprised you. Not required. -->
