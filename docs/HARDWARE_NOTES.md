# Hardware notes (Sony A6700)

Findings from driving an A6700 directly over USB, November 2026. Everything here was observed on
hardware unless marked otherwise; the app's protocol code is built on these facts.

**Setup**: Sony ILCE-6700 (A6700), firmware 2.00, USB, PC Remote mode · E PZ 18-105mm F4 G OSS ·
MacBook (Apple Silicon), macOS 27.2 · `camera-remote-cli` (ImageCaptureCore raw PTP).

## Why ImageCaptureCore, not the Sony SDK

| Attempt                                                               | Result                                                                                        |
| --------------------------------------------------------------------- | --------------------------------------------------------------------------------------------- |
| Sony Camera Remote SDK 2.02 (libusb)                                  | enumerates the camera, but `Connect` fails with `0x8210 CrError_Connect_SessionAlreadyOpened` |
| …after killing `ptpcamerad` in a loop                                 | same                                                                                          |
| …after freezing `ptpcamerad` (SIGSTOP) and power-cycling the camera   | the daemon grabs the interface within ~1 s of the camera appearing; Imaging Edge fails too    |
| ImageCaptureCore + Sony vendor PTP (as Sony's Monitor & Control does) | works first time, no interference                                                             |

## Transport (ImageCaptureCore)

- Devices are reported only to processes with a bundle identity. A bare executable sees none;
  the same executable with an `Info.plist` embedded via `-sectcreate __TEXT __info_plist` works.
- No permission prompt, entitlement or usage-description key needed.
- Camera found ~0.03–1.8 s after `ICDeviceBrowser.start()`; session open + handshake + full
  property read ≈ 20–30 ms.
- `requestSendPTPCommand` completion: (data-in, response container). Transaction IDs are assigned by
  the system (responses carried 0x0D, 0x0E, … while we sent 0).
- **PTP events arrive on a background thread**, despite the header's main-thread note — the
  delegate's `@MainActor` isolation check fired. Delegate callbacks are now `nonisolated`.
- Killing the client mid-session (`kill -9`) does not wedge anything: the next run connects normally.

## Handshake and properties

- `SDIOConnect(1)`, `(2)`, `GetExtDeviceInfo(0x12C)`, `SDIOConnect(3)` → all `0x2001`. Protocol 300,
  351 property codes, 57 control codes.
- `GetAllExtDevicePropInfo` (9.4 KB) parses byte-exactly. Every enumeration entry carries **two
  lists**: settable now, then all supported. While the mode dial owns a property, the first is empty
  and availability = 2 (display only).
- `SetExtDevicePropValue` with the value in the property's own width works; the camera confirms with
  one or more `0xC203` events within ~100–600 ms.

| Setting            | Code              | Observed                                                                                                                                                                                                                                      |
| ------------------ | ----------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Priority key       | `0xD25A`          | {0, 1}; **1 = PC**. With 1, exposure mode becomes settable and the camera's mode dial and wheels stop working for exposure. Stayed 1 across sessions — so the app hands the dials back (0) when it quits, and "Set by: Camera dials" keeps 0. |
| Exposure mode      | `0x500E`          | set to `0x1` (M) → F-number, shutter, ISO, EV all settable                                                                                                                                                                                    |
| F-number           | `0x5007`          | 16 values (f/4 … f/22), f×100                                                                                                                                                                                                                 |
| Shutter            | `0xD20D`          | 53 values in M incl. `0x0` (bulb)                                                                                                                                                                                                             |
| Focus mode         | `0x500A`          | {2, 0x8005, 0x8004, 0x8006, 1}; `0x1` = MF                                                                                                                                                                                                    |
| PC save image      | `0xD269`          | {1, 2, 3}; was 2 (JPEG only); **1 = RAW+JPEG** (verified by capture)                                                                                                                                                                          |
| PC save image size | `0xD268`          | 1 = original (6192×4128 received)                                                                                                                                                                                                             |
| File format        | `0xD253`          | 2 = RAW+JPEG                                                                                                                                                                                                                                  |
| Secondary format   | `0xD287`          | {1, 3, 2}; 1 = JPEG (a .JPG arrived)                                                                                                                                                                                                          |
| RAW compression    | `0xD288`          | {6, 1}; 1 gave a 28 MB ARW (compressed) — exact meaning to confirm                                                                                                                                                                            |
| Store destination  | `0xD222`          | {1, 0x11, 0x10}; 0x11 = PC + card                                                                                                                                                                                                             |
| Live-view quality  | `0xD26A`          | {1, 2}; 2 = High (1024 px)                                                                                                                                                                                                                    |
| USB power supply   | `0xD150`          | {2, 1}; **2 = on** (camera shows the plug icon); the battery indicator `0xD20E` read `0x0E` — not decodable, unused                                                                                                                           |
| Card status        | `0xD248`          | **1 while a card is in and 1099 shots remain** — SDK numbering doesn't apply                                                                                                                                                                  |
| Focal length       | `0xD00B`          | range 18000–105000 step 100, but reports **whole millimetres**                                                                                                                                                                                |
| Zoom position      | `0xE040`/`0xE041` | **not offered**, even with PC priority                                                                                                                                                                                                        |

## Live view

`GetObject(0xFFFFC002)` in a tight loop: **30.2 fps**, 1024×680 JPEG, ~96 KB/frame (~3 MB/s);
"not ready" answers (`0x2009`/`0x200F`) in between are normal — retry after ~10 ms.

## Power zoom

- `ControlDevice(0xD2DD)` with an INT8 speed (−8…8, from `0xD25E`), 0 = stop.
- Speed 4: ~7 mm/s, coasts ~2 mm after stop. Speed 1: ~2.5 mm/s, no coast.
- Focal length updates within ~250 ms of movement.
- Presets: `ControlDevice(0xD2E9)` save / `(0xD2EA)` load with a UINT8 slot. Saved at 45 mm,
  zoomed to 101 mm, load returned to 45.0 mm in ~1.6 s.
- **Slots 1–3 only.** Saving to slot 20 (2026-11-01) got a truncated reply and crashed the camera
  (garbled display, full power cycle). The firmware doesn't reject out-of-range slots cleanly, so
  `SonyCamera` refuses anything outside `zoomAndFocusPresetSlots` before sending.

## Capture

In **MF**, `S1 down → S2 down → 100 ms → S2 up → S1 up` (UINT16 2/1 via `ControlDevice`):

| t      | Event                                                     |
| ------ | --------------------------------------------------------- |
| 0.24 s | `0xC206` captured                                         |
| 0.73 s | `0xC201 ObjectAdded(0xFFFFC001)`; `0xD215` = `0x8001`     |
| 0.93 s | `DSC01134.ARW` 28 MB downloaded (0.11 s, ~240 MB/s)       |
| 1.05 s | `DSC01134.JPG` 15.7 MB downloaded; `0xC202 ObjectRemoved` |

- `0xD215` read `0x8001` with **two** files pending (RAW + JPEG): the count can't be trusted to say
  how many files remain — keep downloading while it is ≥ `0x8001`, expect the number of files the
  format settings imply.
- Polling `GetObjectInfo(0xFFFFC001)` right after the release instead of waiting for `0xD215`:
  ARW at 0.27 s, JPEG at 0.36 s after the shutter (the `0xC206` event arrived after the ARW).
- `GetObjectInfo(0xFFFFC001)` while nothing is waiting answers **OK with an empty dataset** (not
  "invalid handle") — treated as "nothing yet".
- `ObjectInfo` gives the camera's filename (`DSC01134.ARW`) and format (`0xB101` ARW, `0x3801`
  JPEG); width/height read 0.
- In **AF-C without focus** the camera does not release with a 100 ms press: no capture, events
  `0xC223` (5, then 1). So in any AF mode the app half-presses, polls the focus indication `0xD213`
  until it reads focused (2, or 6 while tracking) and only then fully presses; AF-S reporting no
  focus (3) or 4 s without focus aborts the capture with "couldn't focus".
- The AF button holds the half press (it can't overlap a capture's own), in every focus mode and
  without changing it — as on the camera: in AF modes it focuses; in MF it doesn't focus but wakes
  the stabiliser. Sony's `0xD30D` "Tracking On + AF On" control does nothing in MF either (held for
  2.5 s: focus indication stayed 1, mode stayed MF), so there's no remote autofocus in MF.

## Focus

Verified with `camera-remote-cli frames`, `focus-at` and `magnify`.

- **AF point** `0xD2DC` (control, UINT32 `x<<16 | y` on a 640×480 grid over the live-view image):
  asking for (0.25, 0.30) and (0.75, 0.70) of the image put the live view's AF frame centre at exactly
  (160, 144) and (480, 336). It moves the frame only; a half press then focuses there (AF-S: 0.6 s,
  focus indication 2, the frame turns type 8 / state 2 = focused).
- **Live-view AF frames** (focus-info block of `GetObject 0xFFFFC002`): one frame in Spot modes;
  sizes in grid units, height first: Spot S 38 × 38, Spot L 82 × 98, Zone 238 × 302 (centred) — the
  camera draws these frames wider than tall, so the 4th word is the width (confirmed visually).
- **Focus magnifier** `0xD254`: entering with `ratio | 0xFFFFFFFF`, then `ratio | x<<16 | y`, worked:
  ×6.1 at (0.3, 0.4) read back `0x3D_00C0_00C0` = (192, 192). While magnified the live view is the
  **magnified crop at 1024×680** with real sensor detail and no AF frames; `0xFFFFFFFF` exits.
  Not yet checked: a click at the edge of the magnified view lands on that spot (the app
  assumes the view spans 1/ratio of the image). Captures end magnification first, so shooting while
  magnified is never asked of the camera.
- **Manual focus** `0xD2D1` (control, INT16 ±1/±3/±7): accepted in MF; 40 × +7 moved focus visibly
  from the tripod to the background.

## Not yet tested

Stale images left in camera memory after an interrupted transfer; unplug during transfer; card full
or missing; camera auto power-off while tethered; two clients at once (Image Capture / Monitor &
Control open); `0xD288` value meanings.
