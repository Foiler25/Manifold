# Cables — Attribution

The cable-diagnostics engine under `Manifold/Sources/Cables/` derives from
[WhatCable](https://github.com/darrylmorley/whatcable) by Darryl Morley.

- **Upstream repo:** https://github.com/darrylmorley/whatcable
- **Imported at commit:** `80114e7a482e53980c12b76839e1159f8548e9ee`
  (`v1.1.9-10-g80114e7` in the supplied upstream clone)
- **Original licence:** MIT (text reproduced below — required by MIT)
- **Re-licensed in Manifold under:** GPL-3.0 (the project's umbrella licence)

## Which files derive from WhatCable

Everything under the following paths is derived work — each file carries an
in-source paragraph in its header pointing back to this attribution:

- `Manifold/Sources/Cables/Cable/` (all `.swift` files)
- `Manifold/Sources/Cables/USB/` (all `.swift` files)
- `Manifold/Sources/Cables/Thunderbolt/` (all `.swift` files)
- `Manifold/Sources/Cables/Power/` (all `.swift` files)
- `Manifold/Sources/Cables/Display/` (all `.swift` files)
- `Manifold/Sources/Cables/Port/` (all `.swift` files)
- `Manifold/Sources/Cables/Output/` (all `.swift` files)
- `Manifold/Sources/Cables/Snapshot/` (all `.swift` files)
- `Manifold/Sources/Cables/Support/` (all `.swift` files)
- `Manifold/Sources/Cables/Reading/` (all `.swift` files)
- `Manifold/Sources/Cables/Watchers/` (all `.swift` files)
- `Manifold/Sources/Cables/BackendSupport/` (all `.swift` files)
- `Manifold/Sources/Cables/Debug/` (all `.swift` files)
- `Manifold/Sources/Cables/Resources/usbif-vendors.tsv`
- `Manifold/Sources/Cables/Resources/whatcable.db`
- `Manifold/Sources/Cables/Engine/CableSnapshotProvider.swift`
- `Manifold/Sources/Cables/Engine/CableDarwinProvider.swift`
- `ManifoldTests/Cables/UpstreamCore/` (all `.swift` files)
- `ManifoldTests/Cables/UpstreamDarwin/` (all `.swift` files)
- `ManifoldTests/Cables/Fixtures/known-cables.md`

The remaining files in `Manifold/Sources/Cables/Engine/` (`CableEngine.swift`,
`CableEngineLifecycle.swift`, `CablesConstants.swift`) are original Manifold
work and carry only the GPL-3.0 header.

## Renames applied during import

To preserve Manifold's integration boundary and avoid app-module name
collisions, these upstream names or paths were changed. Type semantics are
otherwise unchanged:

| Upstream | Manifold |
|---|---|
| `DarwinSnapshotProvider` | `CableDarwinProvider` |
| `AdapterInfo` | `CableAdapterInfo` |
| `LinkSpeed` | `CableLinkSpeed` |
| `WhatCableDarwinBackend/Support/` | `Cables/BackendSupport/` |

Upstream removed `USBCPortWatcher` (previously imported into Manifold as
`CablePortWatcher`) and replaced that discovery path with
`AppleHPMInterfaceWatcher`. The obsolete Manifold watcher was deleted and the
replacement is present under its upstream name.

## Integration deviations

- `import WhatCableCore`, `import WhatCableDarwinBackend`, and app-layer module
  imports were removed because the absorbed code is compiled into Manifold's
  app module.
- Upstream's duplicate snapshot-provider protocol was omitted; Manifold keeps
  its existing `Engine/CableSnapshotProvider.swift` contract and the renamed
  Darwin provider conforms to it.
- SwiftPM `Bundle.module` resource access was adapted to `Bundle.main`, with a
  bundle-resource fallback used by tests and previews.
- Core localization uses the upstream English source strings as fallbacks and
  returns `Bundle.main` for unavailable locales because Manifold does not ship
  WhatCable's app localization catalogs.
- Explicit public imports, `Sendable` annotations, and immutable test-fixture
  isolation annotations were added where required by Manifold's Swift 6 build
  settings.
- The upstream `WhatCableAppKit` `RefreshSignalTests` file was not imported: it
  exclusively tests an unported app/UI-layer type. The supplied upstream clone
  contains no tracked `research/customer-probes` fixture files (despite current
  upstream coverage tests requiring them), so corpus-dependent suites report an
  explicit skip when `corpus.jsonl` is absent. The available allowed
  `data/known-cables.md` fixture is carried with the tests.

No code from `WhatCablePlugins`, the WhatCable app UI, CLI, widget, licensing,
purchase, Pro-hint, or plugin-registry layers is included.

## Original MIT licence (preserved verbatim)

```
MIT License

Copyright (c) 2026 Darryl Morley

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
```
