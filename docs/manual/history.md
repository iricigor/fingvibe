# History and usage categories

FingVibe saves scan evidence. Evidence describes what a scan observed, not
uninterrupted device availability or human presence.

## First seen, last seen, and last observed

Open a device's details and find its **Scan history** summary.
The summary uses the selected Windows network identity and subnet.

| Value | Meaning |
| --- | --- |
| First seen | Earliest suitable saved local presence observation. |
| Last seen | Latest suitable saved local presence observation. Missing responses do not advance it. |
| Last observed: Present/Absent | The state in the relevant recorded scan, not live status. |
| Observed online/offline since | The first recorded scan in the latest sequence of that state. Gaps between scans are not continuous evidence. |

Times are displayed in local time. Full timestamps include the UTC offset
where available. A restart preserves history but does not make it current.
Imported Fing times do not create local presence or invented scan rows.

Changing networks does not substitute another network's history.
An unavailable value may mean the selected context has no suitable evidence.
The [Devices Last seen column](devices.md#last-seen) uses the same scope.

## Temporarily unavailable controls

In release **v1.1.107**, the **Activity** grid and
**Completed Scan Observations** expander/table are hidden.
They have no user-facing enable switch.

The app still retains scan evidence and displays the summary.
This manual does not give steps for controls you cannot use.
Their restoration is tracked separately in
[#273](https://github.com/iricigor/fingvibe/issues/273) and
[#274](https://github.com/iricigor/fingvibe/issues/274).
Check your release notes before following instructions for a later version.

## Usage categories

The **Usage category** column can show:

| Category | Automatic rule |
| --- | --- |
| Permanent | The device responded in at least 80% of eligible scans. |
| Guest | The device responded in at most 10% of eligible scans. |
| Personal | Other devices may qualify when overnight/weekend response is at least 60% and at least 20 percentage points above weekday daytime, with evidence in both groups. |
| Unclassified | No eligible evidence, or none of the other rules applies. |

Rules run in that order. They use today and the previous six local dates on
the selected network, bounded by the device's first reliable sighting.
Overnight is 18:00-06:00; weekends also belong to that comparison group.

**Limited evidence** means the result is based on too few dates or scans to
meet the app's evidence thresholds. The category may still appear.
For example, 12 responses out of 14 eligible scans can suggest Permanent,
but with limited evidence.

In Devices, the category stays on one line. A small information indicator
provides the provisional estimate's explanation; a pin identifies a manual
override. Hover or use keyboard focus and Enter/Space to read the counts and
observation period. Unclassified is muted, while loading and unavailable
evidence remain distinguishable. See [the Devices column](devices.md#usage-category).

Incomplete scans, imported totals, unknown gaps, and unrelated networks do not
become nonresponses. The time of day you scan affects the recommendation.
**Guest does not prove a visitor, and Personal does not prove ownership.**

## Set a category yourself

1. Open the device's details.
2. Find **Usage category** in **Assignments**.
3. Choose the category you want.
4. Choose **Save category**.
5. Use **Cancel** to discard an unsaved category change.

Choose **Automatic** and save to remove your override.
The recommendation and its counts remain visible for comparison.

This save is independent of Person and Room, which save when changed.
A save error retains the category draft.
If another app instance changed the data, **Reload saved category** discards
the draft and loads the saved value before you try again.

There is no screenshot of the hidden Activity/table controls in this manual.
This avoids illustrating unavailable features as usable.
