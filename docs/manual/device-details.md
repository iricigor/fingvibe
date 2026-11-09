# Identify and inspect a device

Select a row on **Devices** to open its details.
Use the **Devices** return action when finished.

[![Device details with a sample address, MAC, hostname, and independent Person and Room assignments](../screenshots/manual/device-details.png)](../screenshots/manual/device-details.png)

*Native test-build screenshot. The hostname belongs to the disposable CI runner;
addresses and metadata are safe review data. Lower sections require scrolling.
[Screenshot sources](screenshots.md).*

## Understand identification

**Network overview** shows the observed address, MAC address, hostname, vendor,
and available response measurements. **Device identification** shows the type,
operating system, brand, family, model, and selected icon.

FingVibe gathers local name and service evidence. It can also use a MAC prefix
to find the registered vendor. This does not reliably identify every device.

**(likely)** means the evidence suggests a classification but does not prove it.
**Unknown** is an intentional result when evidence is absent or conflicting.
Open **How this device was identified** to see why a value was selected.
Running a web server or file-sharing service alone does not identify the OS.

## Rename

1. Choose **Rename** near the device name.
2. Enter your preferred name.
3. Choose **Save**.
4. Check the save feedback.
5. Choose **Done** to close the editor.

A saved name is separate from the discovered hostname.
Choose **Use imported / discovered name** to remove your custom name.
Closing the editor is not a substitute for checking whether a save succeeded.

## Correct identification

1. Find **Device identification**.
2. Choose **Edit**.
3. Change the type, OS, brand, family, model, or icon.
4. Choose **Save changes**, or **Cancel** to discard the draft.

Your saved corrections take precedence over imported values and automatic
evidence. Blank brand/family/model fields inherit their original/default values.
**Automatic** uses automatic evidence when there is no mapped Fing value;
an imported option explicitly says it uses imported Fing OS/type.

**Reset saved identification** clears the six identification overrides.
It does not remove the device name, assignments, or original imported evidence.
An error leaves the draft visible so you can review it.

Names and corrections normally follow the device's MAC address, not its IP.
A changing MAC can break that association.

## Inspect services

The normal LAN scan checks ten common TCP ports.
For a currently responding address, **Scan additional ports** checks a curated
set of 100 additional TCP ports.

1. Confirm the device responded in the current local scan.
2. If several current addresses exist, select **Current address to inspect / probe**.
3. Review **Ports & services**.
4. Optionally select **Include UDP service checks**.
5. Choose **Scan additional ports**.
6. Read the outcome and endpoint details.

UDP service checks cover a small supported set, not every UDP port.
**No response** is inconclusive; it is not proof that a UDP port is open or closed.
Do not run probes against historical imported addresses.
The app prevents conflicting network measurements from running together.

Copy controls appear beside populated values on hover or keyboard focus.
Copy only information you intend to share; MACs, names, and addresses can be private.

## Assign equipment

Choose a **Person** and **Room** in **Assignments**.
Each selection saves when changed; the categories are independent.
See [People and rooms](people-rooms.md).

**Usage category** has a separate draft and save action.
Changing that draft does not save it through the Person/Room controls.
See [Usage categories](history.md#usage-categories).

## Virtual-device details

For an inferred virtual identity, names, corrections, and assignments belong
to that identity and can follow its associated MAC changes.

Expand **MAC and address history** for the member addresses, times, and preserved
evidence. Do not treat this association as proof of a physical device.
Fing import still matches full MAC addresses, not virtual names or prefixes.

## History availability

First/last-seen and last-observed summaries are available.
Activity grids and the Completed Scan Observations table are temporarily
hidden in the initial manual's release. There is no setting to enable them.
See [History and usage categories](history.md).
