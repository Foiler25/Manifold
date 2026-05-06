# Cables — Attribution

The cable-diagnostics engine under `Manifold/Sources/Cables/` derives from
[WhatCable](https://github.com/darrylmorley/whatcable) by Darryl Morley.

- **Upstream repo:** https://github.com/darrylmorley/whatcable
- **Imported at commit:** `785d6bc24179ed66106e90afd76c50ab05898faa`
- **Original licence:** MIT (text reproduced below — required by MIT)
- **Re-licensed in Manifold under:** GPL-3.0 (the project's umbrella licence)

## Which files derive from WhatCable

Everything under the following paths is derived work — each file carries an
in-source paragraph in its header pointing back to this attribution:

- `Manifold/Sources/Cables/Models/` (all `.swift` files and `Resources/usbif-vendors.tsv`)
- `Manifold/Sources/Cables/Formatting/` (all `.swift` files)
- `Manifold/Sources/Cables/Watchers/` (all `.swift` files)
- `Manifold/Sources/Cables/Engine/CableSnapshotProvider.swift`
- `Manifold/Sources/Cables/Engine/CableDarwinProvider.swift`

The remaining files in `Manifold/Sources/Cables/Engine/` (`CableEngine.swift`,
`CableEngineLifecycle.swift`, `Constants.swift`) are original Manifold
work and carry only the GPL-3.0 header.

## Renames applied during import

To match Manifold naming conventions, two upstream class/file names were
renamed during the import. Type semantics are unchanged:

| Upstream                      | Manifold                  |
|-------------------------------|---------------------------|
| `DarwinSnapshotProvider`      | `CableDarwinProvider`     |
| `USBCPortWatcher`             | `CablePortWatcher`        |

All `import WhatCableCore` statements were removed — the absorbed code now
lives in the same Swift module as the rest of the Manifold app target.

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
