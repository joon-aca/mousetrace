MouseTrace
==========

A read-only macOS mouse diagnostic. Every physical button press gets an id (#n)
and is traced through each layer of the input pipeline:

1. HID      raw button value from IOKit, with the device it came from
2. CG-HID   Quartz tap at the HID location (the event entering WindowServer)
3. CG-HEAD  Quartz session stream, before pre-existing session taps
4. CG-TAIL  Quartz session stream, after pre-existing session taps

Each CG line shows +latency from the HID press. If any layer misses a press
within 500ms, a "✗✗✗ SWALLOWED between X and Y" verdict is printed, followed by a
DIAGNOSTICS dump.

Run:
  ./run.command

If macOS blocks monitoring, enable Terminal under:
  System Settings > Privacy & Security > Accessibility
  System Settings > Privacy & Security > Input Monitoring
Then quit/reopen Terminal and rerun.

WHAT IT LOGS
------------
Startup / hot-plug:
  DEVICE   every pointing device, its open result, and every process holding a
           user client on it. "kIOReturnExclusiveAccess" means another process
           SEIZED that device (Karabiner does this to keyboards it remaps).
  TAPS     every event tap on the system that receives mouse buttons: owner,
           location, listen-only vs ⚠ ACTIVE (can drop events), latency.
Continuously:
  TAP+/TAP-/TAP~  a tap appeared, disappeared, or was enabled/disabled.
  STATUS   every 30s (only when changed): movement counts per layer and click
           totals. If HID moves climb but CG moves stay 0, the Quartz taps are
           blind, so their silence doesn't mean clicks were dropped.
Per click:
  HID line: device, held duration, and ⚠ flags for switch bounce/chatter
            (press < 20ms, re-press < 30ms after release, DOWN without UP).
  CG lines: position, clickState, target app, source process, ⚠ if posted by
            software, frontmost app and the window under the cursor (flags
            invisible overlays).

WHEN THE BUG HAPPENS
--------------------
Do not reboot or unplug anything.

1. Click the physical mouse 5 times.
2. Click the Mac's trackpad 5 times.
3. Quit suspect apps (Grok Bot, Karabiner-Elements) completely.
4. Click 5 more times.
5. Press Ctrl-C in Terminal.
6. Save mouse-trace.log.

Reading a SWALLOWED verdict:
- HID → CG-HID:      device reported it, WindowServer never got it. Most common
                     cause: ANOTHER device is stuck holding that button (macOS
                     merges button state across devices, so your press is absorbed
                     into the stuck one). Look for "⚠ CAUSE" / "⚠ HOLDING" and
                     "system buttons held: LEFT". Fix: click once on the holding
                     device, or power-cycle it. Otherwise: seized device or a
                     wedged HID event system.
- CG-HID → CG-HEAD:  an ACTIVE tap at the HID location dropped it.
- CG-HEAD → CG-TAIL: an ACTIVE session tap dropped it.
- All layers present but the app does nothing: problem is downstream (app/UI,
  invisible overlay window: check window= on the CG-HEAD line).
- No HID line at all: the press never reached IOKit (hardware, Bluetooth, or a
  device seized by another process, which hides it from MouseTrace too).

All Quartz taps are listen-only and return every event unchanged.
