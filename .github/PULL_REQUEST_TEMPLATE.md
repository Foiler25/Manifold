# Summary

<!-- One paragraph. What changed and why. Lead with the user-facing
     impact when there is one; lead with the architectural reason
     when the change is internal. Don't restate the diff — link to
     the relevant lines if a particular spot needs context. -->

# Type of change

- [ ] Bug fix
- [ ] New feature
- [ ] Breaking change (user-facing settings / data format / wire format / public API)
- [ ] Refactor / internals only
- [ ] Docs / tooling
- [ ] Test improvement

# Checklist

- [ ] All tests pass: `xcodebuild -scheme Manifold -only-testing:ManifoldTests test` AND `swift test --package-path ManifoldKit`.
- [ ] Both Debug and Release builds succeed.
- [ ] No new raw IOKit C calls outside `Manifold/Sources/Support/IOKit/` (`grep` invariant — see `CONTRIBUTING.md`).
- [ ] If the change touches `@AppStorage`: keys land in `SettingsKeys` (or one of the per-pane key namespaces) AND have a string-pin test.
- [ ] If the change touches user-facing text: localized via `Localizable.xcstrings`.
- [ ] If the change touches a Codable wire-format type (`SnapshotV1`, `Diagnostic`, `PortEvent`, …): the round-trip test still passes.
- [ ] If the change adds a diagnostic rule: positive / negative / edge tests added.
- [ ] If the change touches the snapshot wire format: the snapshot file stays under 10 KB typical.
- [ ] If the change touches AppDelegate event-handling: ordering of notify / persist / apply / snapshot stays sane (see `AppDelegate.handle`).

# Screenshots

<!-- If the PR has user-facing UI changes, drop before / after
     screenshots here. Skip for refactors / internals. -->

# Related issues

<!-- "Closes #123" / "Fixes #456" / "Part of #789". Skip if none. -->

# Notes for the reviewer

<!-- Anything that helps the reviewer focus. Trade-offs you considered
     and rejected, surprising design choices, areas you want extra
     scrutiny on. Skip if the diff is straightforward. -->
