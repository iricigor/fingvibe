# README branding

The user selected **Network radar** from three original FingVibe brand-mark
proposals in [PR #112](https://github.com/iricigor/fingvibe/pull/112).
These README assets do not replace the
application's `Scanner.ico` or set a browser favicon.

| 1. Network radar (selected) | 2. Connected devices | 3. Signal pulse |
| --- | --- | --- |
| <img src="network-radar.png" alt="Blue radar with teal sweep and colorful device nodes" width="128" height="128"> | <img src="connected-devices.png" alt="Teal hub connecting colorful computer, phone, storage, and media symbols" width="128" height="128"> | <img src="signal-pulse.png" alt="Teal network signal and amber pulse between blue nodes" width="128" height="128"> |
| Emphasizes discovery. | Emphasizes the device inventory. | Emphasizes responsiveness and Vibe. |

Each proposal has a self-contained SVG master and a transparent **256x256 PNG**.
The dark blue tile gives the colorful details consistent contrast on both
GitHub light and dark backgrounds; the area outside the rounded tile is
transparent. No fonts, external images, scripts, or remote resources are used.

The selected mark displays at **128x128**, right-aligned near the README title.
The other proposals are retained here for the design record; their original
pre-selection previews are also preserved in the PR.

The user requested these node-color changes to Network radar:

| Original | Selected | HSL saturation | HSL lightness |
| --- | --- | --- | --- |
| Yellow `#ffc45c` | Red `#ff5c5c` | 100% (unchanged) | 68.04% (unchanged) |
| Green `#4df0d3` | Green `#4df0d3` | Unchanged | Unchanged |
| Red `#ff809a` | Light blue `#80d5ff` | 100% (unchanged) | 75.10% (unchanged) |
| Purple `#bd9aff` | Yellow `#ffeb9a` | 100% (unchanged) | 80.20% (unchanged) |

Only the three requested node hues changed; their saturation and lightness,
the green node, the radar geometry, and the background remain unchanged.

To regenerate a PNG, render its SVG at 256x256 with a transparent background
using an SVG-capable renderer. Do not change the SVG's viewBox or stretch the
aspect ratio. Check the exported size, transparent corners, and 128px rendering
on both light and dark backgrounds before replacing the PNG.
