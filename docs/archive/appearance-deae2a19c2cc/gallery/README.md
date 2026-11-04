# Appearance comparison gallery

[Archive introduction](../README.md) | [Implementation and evidence](../IMPLEMENTATION.md)

All captures are from `deae2a19c2cc8218183f08b777347215b7fa31e6`, using
the same synthetic eight-device saved snapshot and 1600x960 window.
Rows cover the four Light/Dark x Standard/Colored combinations; columns compare
the three styles. Each cell pairs Overview above Devices under one shared
Mode / Theme / Backdrop caption. Every thumbnail links to its full-size local
PNG. These are the same assets used by the introduction, not copies.

**Backdrop:** Glass requests **Mica Alt**; Clay and Neumorphic use **Solid**.
Native-material availability and Windows effects state are recorded in the
[per-image capture manifest](../evidence/capture-manifest.json); selection alone
does not prove native material rendering.

| Glass | Clay | Neumorphic |
| --- | --- | --- |
| **Light / Standard / Mica Alt**<br>[![Glass, Light, Standard, Overview, Mica Alt](../screenshots/glass-light-standard-overview.png)](../screenshots/glass-light-standard-overview.png)<br>[![Glass, Light, Standard, Devices, Mica Alt](../screenshots/glass-light-standard-devices.png)](../screenshots/glass-light-standard-devices.png) | **Light / Standard / Solid**<br>[![Clay, Light, Standard, Overview, Solid](../screenshots/clay-light-standard-overview.png)](../screenshots/clay-light-standard-overview.png)<br>[![Clay, Light, Standard, Devices, Solid](../screenshots/clay-light-standard-devices.png)](../screenshots/clay-light-standard-devices.png) | **Light / Standard / Solid**<br>[![Neumorphic, Light, Standard, Overview, Solid](../screenshots/neumorphic-light-standard-overview.png)](../screenshots/neumorphic-light-standard-overview.png)<br>[![Neumorphic, Light, Standard, Devices, Solid](../screenshots/neumorphic-light-standard-devices.png)](../screenshots/neumorphic-light-standard-devices.png) |
| **Light / Colored / Mica Alt**<br>[![Glass, Light, Colored, Overview, Mica Alt](../screenshots/glass-light-colored-overview.png)](../screenshots/glass-light-colored-overview.png)<br>[![Glass, Light, Colored, Devices, Mica Alt](../screenshots/glass-light-colored-devices.png)](../screenshots/glass-light-colored-devices.png) | **Light / Colored / Solid**<br>[![Clay, Light, Colored, Overview, Solid](../screenshots/clay-light-colored-overview.png)](../screenshots/clay-light-colored-overview.png)<br>[![Clay, Light, Colored, Devices, Solid](../screenshots/clay-light-colored-devices.png)](../screenshots/clay-light-colored-devices.png) | **Light / Colored / Solid**<br>[![Neumorphic, Light, Colored, Overview, Solid](../screenshots/neumorphic-light-colored-overview.png)](../screenshots/neumorphic-light-colored-overview.png)<br>[![Neumorphic, Light, Colored, Devices, Solid](../screenshots/neumorphic-light-colored-devices.png)](../screenshots/neumorphic-light-colored-devices.png) |
| **Dark / Standard / Mica Alt**<br>[![Glass, Dark, Standard, Overview, Mica Alt](../screenshots/glass-dark-standard-overview.png)](../screenshots/glass-dark-standard-overview.png)<br>[![Glass, Dark, Standard, Devices, Mica Alt](../screenshots/glass-dark-standard-devices.png)](../screenshots/glass-dark-standard-devices.png) | **Dark / Standard / Solid**<br>[![Clay, Dark, Standard, Overview, Solid](../screenshots/clay-dark-standard-overview.png)](../screenshots/clay-dark-standard-overview.png)<br>[![Clay, Dark, Standard, Devices, Solid](../screenshots/clay-dark-standard-devices.png)](../screenshots/clay-dark-standard-devices.png) | **Dark / Standard / Solid**<br>[![Neumorphic, Dark, Standard, Overview, Solid](../screenshots/neumorphic-dark-standard-overview.png)](../screenshots/neumorphic-dark-standard-overview.png)<br>[![Neumorphic, Dark, Standard, Devices, Solid](../screenshots/neumorphic-dark-standard-devices.png)](../screenshots/neumorphic-dark-standard-devices.png) |
| **Dark / Colored / Mica Alt**<br>[![Glass, Dark, Colored, Overview, Mica Alt](../screenshots/glass-dark-colored-overview.png)](../screenshots/glass-dark-colored-overview.png)<br>[![Glass, Dark, Colored, Devices, Mica Alt](../screenshots/glass-dark-colored-devices.png)](../screenshots/glass-dark-colored-devices.png) | **Dark / Colored / Solid**<br>[![Clay, Dark, Colored, Overview, Solid](../screenshots/clay-dark-colored-overview.png)](../screenshots/clay-dark-colored-overview.png)<br>[![Clay, Dark, Colored, Devices, Solid](../screenshots/clay-dark-colored-devices.png)](../screenshots/clay-dark-colored-devices.png) | **Dark / Colored / Solid**<br>[![Neumorphic, Dark, Colored, Overview, Solid](../screenshots/neumorphic-dark-colored-overview.png)](../screenshots/neumorphic-dark-colored-overview.png)<br>[![Neumorphic, Dark, Colored, Devices, Solid](../screenshots/neumorphic-dark-colored-devices.png)](../screenshots/neumorphic-dark-colored-devices.png) |

## Settings: all four appearance dropdowns

**Dark / Standard / Glass / Mica Alt.** Mode, Theme, Visual style, and
Window backdrop are visible simultaneously.

[![Settings, Dark, Standard, Glass, Mica Alt; all four appearance dropdowns](../screenshots/settings.png)](../screenshots/settings.png)

Neumorphic shows the existing implementation, **not** the later unimplemented
uniform-base / stronger paired-shadow / debossed-input refinement. Vivid and
Warm/OLED are not additional capture families.
