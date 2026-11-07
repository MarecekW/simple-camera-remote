# Fixtures

Real responses captured from a Sony A6700 through ImageCaptureCore on
2026-11-01 (`camera-remote-cli dump`, and `GetObject 0xFFFFC002` for live view):

- Body: Sony ILCE-6700 (A6700), firmware 2.00, USB PC Remote mode,
  priority key = camera, exposure mode P, focus AF-C.
- Lens: E PZ 18-105mm F4 G OSS at 37 mm.

| File                        | Operation                                                    |
| --------------------------- | ------------------------------------------------------------ |
| `a6700-ext-device-info.bin` | `0x9202 SDIOGetExtDeviceInfo(0x12C)` data phase              |
| `a6700-all-properties.bin`  | `0x9209 GetAllExtDevicePropInfo` data phase (351 properties) |
| `a6700-live-view.bin`       | `0x1009 GetObject(0xFFFFC002)` data phase                    |

The live-view object's focus-info block carried leftover camera memory
(network headers); bytes `0x490`–`0x7F3` were zeroed before committing.
