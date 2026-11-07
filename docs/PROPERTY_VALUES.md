# Property values: wire value → display name

Display names for the enumerated Sony PTP ("SDIO") properties the app shows, keyed by the
**wire value** sent by `0x9209 GetAllExtDevicePropInfo` and accepted by `0x9205 SetExtDevicePropValue`.
Compiled 2026-11-01 for the A6700 (ILCE-6700, firmware 2.00).

**Wire values are not CrSDK enum values.** The Sony Camera Remote SDK renumbers most properties
(for example white balance Auto is `0x0002` on the wire and `0x0000` in `CrWhiteBalanceSetting`,
file format RAW is `1` on the wire and `CrFileType_Raw = 2`, JPEG quality is in reverse order, and drive
modes use a completely different layout). Use the SDK only for the _set_ of names. Wire numbers come from
libgphoto2 and the camera.

## Sources and confidence

| Key       | Source                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| --------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **HW**    | Observed on an A6700: `docs/HARDWARE_NOTES.md`, the fixture `Tests/CameraFixtures/Resources/a6700-all-properties.bin` (current values, decoded with `PropertyDescriptor.parseAll`), or test captures (ARW/JPG)                                                                                                                                                                                                                                                                                                                                                                     |
| **GP**    | libgphoto2 `camlibs/ptp2/config.c` (master, fetched 2026-11-01). Tables: `sony_exposure_program_32_modes`, `whitebalance` (Sony rows), `focusmodes` (Sony rows), `exposure_metering` (Sony rows, "taken from A7III"), `sony_focusarea`, `sony3_capturemode`, `sony_300_compression`, `sony_300_jpegcompression`, `sony_size`, `sony_aspectratio`, `sony_drange_optimizer`, `sony_capturetarget`, `sony_pc_save_image_format`, `sony_pc_save_image_size`, `sony_prioritymode`, `sony_liveviewsettingeffect`, plus `_stringify_Sony_ISO`, `_get_Sony_ShutterSpeed` and `ptp.h` names |
| **SDK**   | Sony CrSDK 2.02 `CrDeviceProperty.h` (read statically). Used for names, and for wire values only where they visibly match (lens compensation, aspect ratio, image size, compression file format)                                                                                                                                                                                                                                                                                                                                                                                   |
| **A6700** | Sony's A6700 menus and help guide wording, used to pick the label the camera itself shows                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |

Confidence levels:

- **Verified**: seen on this camera with a known meaning.
- **High**: libgphoto2 (and the SDK, where it applies) agree, and the value is in the A6700's own list.
- **Medium**: a single source or an inference. Confirm on hardware before relying on it.

"Kind" column: **Still** means keep it. **Movie** and **S&Q** mean hide it in a stills app.

---

## Exposure mode, `0x500E` (UINT32)

The A6700 lists 27 values. Each value has two parts. The high 16 bits are a category. The low 16 bits are the
code used by the older 16-bit property (`0x8000`-range Sony codes, `1`–`7` standard PTP).
Category nibble (bits 16–19): `0` M / standard PTP, `1` P, `2` A, `3` S, `4` auto, `5` scene, `6` panorama,
`7` movie, `8` HFR / old S&Q, `9` S&Q movie, `A` still/movie switch, `B` F mode, `C` interval-rec movie.
**Rule for hiding: categories `7`, `8`, `9`, `A`, `B` and `C` are movie modes. Everything else is a still mode.**
One libgphoto2 entry breaks this rule: `0x98060` "Intelligent Auto Flash Off" is a still mode. The A6700 does not list it.

| Wire      | Display                 | Kind  | Confidence  | Source                                                                                                                                        |
| --------- | ----------------------- | ----- | ----------- | --------------------------------------------------------------------------------------------------------------------------------------------- |
| `0x48000` | AUTO (Intelligent Auto) | Still | High        | GP, SDK `CrExposure_Auto`                                                                                                                     |
| `0x10002` | P                       | Still | Verified    | HW (fixture current value, README "exposure mode P"), GP                                                                                      |
| `0x20003` | A                       | Still | High        | GP, SDK                                                                                                                                       |
| `0x30004` | S                       | Still | High        | GP, SDK                                                                                                                                       |
| `0x1`     | M                       | Still | Verified    | HW (setting `0x1` made F/shutter/ISO/EV settable), GP                                                                                         |
| `0x7`     | SCN: Portrait           | Still | High        | GP (standard PTP `0x0007` Portrait), SDK `CrExposure_Portrait = 7`. The A6700 SCN dial has 7 scenes and this is the only one not in `0x58xxx` |
| `0x58011` | SCN: Sports Action      | Still | High        | GP, SDK                                                                                                                                       |
| `0x58012` | SCN: Sunset             | Still | High        | GP, SDK                                                                                                                                       |
| `0x58013` | SCN: Night Scene        | Still | High        | GP, SDK `CrExposure_Night`                                                                                                                    |
| `0x58014` | SCN: Landscape          | Still | High        | GP, SDK                                                                                                                                       |
| `0x58015` | SCN: Macro              | Still | High        | GP, SDK                                                                                                                                       |
| `0x58017` | SCN: Night Portrait     | Still | High        | GP, SDK                                                                                                                                       |
| `0x78050` | Movie P                 | Movie | High        | GP, SDK `CrExposure_Movie_P`                                                                                                                  |
| `0x78051` | Movie A                 | Movie | High        | GP, SDK                                                                                                                                       |
| `0x78052` | Movie S                 | Movie | High        | GP, SDK                                                                                                                                       |
| `0x78053` | Movie M                 | Movie | High        | GP, SDK                                                                                                                                       |
| `0x78054` | Movie AUTO              | Movie | High (name) | SDK `CrExposure_Movie_Auto`. libgphoto2 calls it "Movie (Scene)". The A6700 has Intelligent Auto in movie, not a movie scene mode             |
| `0x98059` | S&Q P                   | S&Q   | High        | GP "Movie S&Q Motion (P)", SDK                                                                                                                |
| `0x9805A` | S&Q A                   | S&Q   | High        | GP, SDK                                                                                                                                       |
| `0x9805B` | S&Q S                   | S&Q   | High        | GP, SDK                                                                                                                                       |
| `0x9805C` | S&Q M                   | S&Q   | High        | GP, SDK                                                                                                                                       |
| `0x9805D` | S&Q AUTO                | S&Q   | High (name) | SDK `CrExposure_Movie_SQMotion_AUTO`. GP calls it "(Scene)"                                                                                   |
| `0xC8093` | Interval Movie P        | Movie | High        | GP "Interval REC (Movie) (P)", SDK `CrExposure_Movie_IntervalRec_P`                                                                           |
| `0xC8094` | Interval Movie A        | Movie | High        | GP, SDK                                                                                                                                       |
| `0xC8095` | Interval Movie S        | Movie | High        | GP, SDK                                                                                                                                       |
| `0xC8096` | Interval Movie M        | Movie | High        | GP, SDK                                                                                                                                       |
| `0xC8097` | Interval Movie AUTO     | Movie | High        | GP, SDK                                                                                                                                       |

Not listed by this A6700, but useful as fallbacks: `0x48001` Superior Auto, `0x58016` Hand-held Twilight, `0x58018`
Anti Motion Blur, `0x68041` Sweep Panorama, `0x8020` Memory Recall, `0x88080`–`0x88083` HFR P/A/S/M (movie),
`0x88084`–`0x88087` S&Q P/A/S/M (older bodies, movie), `0xA8088` Movie, `0xA8089` Still, `0xB808A` F (movie/S&Q),
`0x78090` Movie F, `0x98091` S&Q F, `0xC8092` Interval F (GP).
The MR 1/2/3 dial positions do not appear in the list. The camera probably reports the recalled mode instead. This is unverified.

## White balance, `0x5005` (UINT16)

All 15 values are settable on the A6700. The current `WhiteBalanceMode` labels are correct.

| Wire     | Display (A6700 menu wording)              | Confidence | Source                                                  |
| -------- | ----------------------------------------- | ---------- | ------------------------------------------------------- |
| `0x0002` | Auto (AWB)                                | Verified   | HW (fixture current = 2), GP (standard PTP "Automatic") |
| `0x0004` | Daylight                                  | High       | GP (standard PTP)                                       |
| `0x8011` | Shade                                     | High       | GP                                                      |
| `0x8010` | Cloudy                                    | High       | GP                                                      |
| `0x0006` | Incandescent                              | High       | GP (standard PTP "Tungsten")                            |
| `0x8001` | Fluor.: Warm White                        | High       | GP                                                      |
| `0x8002` | Fluor.: Cool White                        | High       | GP ("Cold White"). Sony's menu says "Cool White"        |
| `0x8003` | Fluor.: Day White                         | High       | GP                                                      |
| `0x8004` | Fluor.: Daylight                          | High       | GP                                                      |
| `0x0007` | Flash                                     | High       | GP (standard PTP)                                       |
| `0x8030` | Underwater Auto                           | High       | GP                                                      |
| `0x8012` | Color Temp./Filter (kelvin from `0xD20F`) | High       | GP "Choose Color Temperature"                           |
| `0x8020` | Custom 1                                  | High       | GP "Preset 1"                                           |
| `0x8021` | Custom 2                                  | High       | GP                                                      |
| `0x8022` | Custom 3                                  | High       | GP                                                      |

Not on the A6700: `0x8023` Preset/Custom (GP).

## Focus mode, `0x500A` (UINT16)

| Wire     | Display | Confidence | Source                                        |
| -------- | ------- | ---------- | --------------------------------------------- |
| `0x0002` | AF-S    | High       | GP (standard PTP "Automatic"), Sony order     |
| `0x8005` | AF-A    | High       | GP                                            |
| `0x8004` | AF-C    | Verified   | HW (fixture current, README "focus AF-C"), GP |
| `0x8006` | DMF     | High       | GP                                            |
| `0x0001` | MF      | Verified   | HW                                            |

Also in GP, not on the A6700: `0x8007` Manual Reverse, `0x8008` AF-D, `0x8009` Preset Focus.

## Focus area, `0xD22C` (UINT16)

This property is not in the inspector yet. All 14 values are settable. The fixture's current value is `0x103`.
libgphoto2 uses older Sony names ("Flexible Spot", "Lock-on AF"). The A6700 menu calls them "Spot" and "Tracking".

| Wire    | Display (A6700)       | libgphoto2 name                  | Confidence |
| ------- | --------------------- | -------------------------------- | ---------- |
| `0x001` | Wide                  | Wide                             | High       |
| `0x002` | Zone                  | Zone                             | High       |
| `0x003` | Center Fix            | Center                           | High       |
| `0x101` | Spot: S               | Flexible Spot: S                 | High       |
| `0x102` | Spot: M               | Flexible Spot: M                 | High       |
| `0x103` | Spot: L               | Flexible Spot: L                 | High       |
| `0x104` | Expand Spot           | Expand Flexible Spot             | High       |
| `0x201` | Tracking: Wide        | Lock-on AF: Wide                 | High       |
| `0x202` | Tracking: Zone        | Lock-on AF: Zone                 | High       |
| `0x203` | Tracking: Center Fix  | Lock-on AF: Center               | High       |
| `0x204` | Tracking: Spot S      | Lock-on AF: Flexible Spot: S     | High       |
| `0x205` | Tracking: Spot M      | Lock-on AF: Flexible Spot: M     | High       |
| `0x206` | Tracking: Spot L      | Lock-on AF: Flexible Spot: L     | High       |
| `0x207` | Tracking: Expand Spot | Lock-on AF: Expand Flexible Spot | High       |

Source: GP `sony_focusarea`. The `ptp.h` comment on `PTP_DPC_SONY_FocusArea` shows the same list taken from a camera.

## Metering mode, `0x500B` (UINT16)

This property is not in `Codes.swift` or the inspector yet. All 6 values are settable. The fixture's current value is `0x8001`, which is Sony's default.

| Wire     | Display (A6700)    | Confidence | Source                       |
| -------- | ------------------ | ---------- | ---------------------------- |
| `0x8001` | Multi              | High       | GP (rows "taken from A7III") |
| `0x8002` | Center             | High       | GP                           |
| `0x8003` | Entire Screen Avg. | High       | GP                           |
| `0x8004` | Spot: Standard     | High       | GP                           |
| `0x8005` | Spot: Large        | High       | GP                           |
| `0x8006` | Highlight          | High       | GP                           |

The A6700 menu has exactly these six. The SDK's `CrMeteringMode` (1…10) uses different numbers. Don't use it.

## Drive mode, `0x5013` (UINT32)

The A6700 lists 139 values. **Every one has a name in GP `sony3_capturemode`.** The SDK's `CrDriveMode` numbers do not match the wire.
All values are still modes.

| Wire      | Display                                                | Confidence                 |
| --------- | ------------------------------------------------------ | -------------------------- |
| `0x1`     | Single Shooting                                        | Verified (fixture current) |
| `0x18010` | Continuous: Hi+                                        | High                       |
| `0x10002` | Continuous: Hi                                         | High                       |
| `0x18015` | Continuous: Mid                                        | High                       |
| `0x18012` | Continuous: Lo                                         | High                       |
| `0x38004` | Self-timer: 10 s                                       | High                       |
| `0x38003` | Self-timer: 5 s                                        | High                       |
| `0x38005` | Self-timer: 2 s                                        | High                       |
| `0x88008` | Self-timer (Cont.): 10 s, 3 img                        | High                       |
| `0x88009` | Self-timer (Cont.): 10 s, 5 img                        | High                       |
| `0x8800C` | Self-timer (Cont.): 5 s, 3 img                         | High                       |
| `0x8800D` | Self-timer (Cont.): 5 s, 5 img                         | High                       |
| `0x8800E` | Self-timer (Cont.): 2 s, 3 img                         | High                       |
| `0x8800F` | Self-timer (Cont.): 2 s, 5 img                         | High                       |
| `0x68018` | WB Bracket: Lo                                         | High                       |
| `0x68028` | WB Bracket: Hi                                         | High                       |
| `0x78019` | DRO Bracket: Lo                                        | High                       |
| `0x78029` | DRO Bracket: Hi                                        | High                       |
| `0xA8040` | Focus Bracket                                          | High                       |
| `0x4xxxx` | Cont. Bracket (decoded as described below; 60 values)  | High                       |
| `0x5xxxx` | Single Bracket (decoded as described below; 60 values) | High                       |

**Exposure bracket encoding.** These rules match every entry in GP's table, so the app can decode brackets instead of listing 120 names.

- Bits 16–19: `4` = Continuous Bracket, `5` = Single Bracket.
- Bits 8–15: `0x83` / `0x85` / `0x87` / `0x89` = 3 / 5 / 7 / 9 images. `0xC2` = 2 images.
- Bits 0–7: step code. For a 2-image bracket, bit 3 set (`| 0x08`) means "−" direction and clear means "+".

| Step   | Continuous code | Single code |
| ------ | --------------- | ----------- |
| 0.3 EV | `0x37`          | `0x36`      |
| 0.5 EV | `0x57`          | `0x56`      |
| 0.7 EV | `0x77`          | `0x76`      |
| 1.0 EV | `0x11`          | `0x10`      |
| 1.3 EV | `0x41`          | `0x40`      |
| 1.5 EV | `0x61`          | `0x60`      |
| 1.7 EV | `0x81`          | `0x80`      |
| 2.0 EV | `0x21`          | `0x20`      |
| 2.3 EV | `0x51`          | `0x50`      |
| 2.5 EV | `0x71`          | `0x70`      |
| 2.7 EV | `0x91`          | `0x90`      |
| 3.0 EV | `0x31`          | `0x30`      |

Examples: `0x48537` = Cont. Bracket 0.3 EV × 5. `0x5C23E` = Single Bracket 0.3 EV × 2 (−).
Display format: "BRK C 0.3EV 5" or "Cont. Bracket 0.3 EV · 5 img".

Other GP drive values, not on this body: `0x18011` Hi-Live, `0x18013` Continuous, `0x18014` Speed Priority, `0x18016`
Mid-Live, `0x18017` Lo-Live, `0x20003` Timelapse, `0x7800A` Remote Commander, `0x7800B` Mirror Up, `0x7801A` LPF
Bracket, `0x98030`–`0x98032` Spot Burst Lo/Mid/Hi.

## File format, `0xD253` (UINT8)

| Wire | Display                               | Confidence | Source                                                  |
| ---- | ------------------------------------- | ---------- | ------------------------------------------------------- |
| `1`  | RAW                                   | High       | GP `sony_300_compression`                               |
| `2`  | RAW+JPEG (RAW+HEIF when `0xD287` ≠ 1) | Verified   | HW (fixture current = 2, captures gave .ARW + .JPG), GP |
| `3`  | JPEG (HEIF when `0xD287` ≠ 1)         | High       | GP                                                      |

The A6700 records HEIF too. The second format is picked by `0xD287`. To match what the camera shows, label values 2 and 3 using `0xD287`.
The SDK numbering (`CrFileType`: Jpeg=1, Raw=2, RawJpeg=3) is **different**. Don't use it.

## JPEG/HEIF format, `0xD287` CompressionFileFormat (UINT8)

| Wire | Display      | Confidence | Source                                                                                        |
| ---- | ------------ | ---------- | --------------------------------------------------------------------------------------------- |
| `1`  | JPEG         | Verified   | HW (a .JPG arrived with value 1)                                                              |
| `2`  | HEIF (4:2:2) | Medium     | SDK `CrCompressionFileFormat_HEIF_422 = 2`. Wire value inferred to match the SDK, as `1` does |
| `3`  | HEIF (4:2:0) | Medium     | SDK `_HEIF_420 = 3`. Same inference                                                           |

## JPEG quality, `0xD252` (UINT8)

| Wire | Display    | Confidence           | Source                                                                                                   |
| ---- | ---------- | -------------------- | -------------------------------------------------------------------------------------------------------- |
| `1`  | Extra Fine | High (HW-consistent) | GP "X.Fine". Fixture current = 1, and the captured JPEGs are 15.7–18 MB for 26 MP, which fits Extra Fine |
| `2`  | Fine       | High                 | GP                                                                                                       |
| `3`  | Standard   | High                 | GP "Std"                                                                                                 |
| `4`  | Light      | High                 | GP                                                                                                       |

The SDK `CrJpegQuality` order is reversed (Light=1 … ExFine=4). Don't use it. The same quality setting applies to HEIF.

## Image size, `0xD203` (UINT8)

| Wire | Display        | Confidence | Source                                            |
| ---- | -------------- | ---------- | ------------------------------------------------- |
| `1`  | L (26M at 3:2) | Verified   | HW (fixture current = 1, JPEG 6192×4128), GP, SDK |
| `2`  | M (13M)        | High       | GP, SDK                                           |
| `3`  | S (6.5M)       | High       | GP, SDK                                           |

The megapixel figures are Sony's A6700 specs at 3:2 and change with aspect ratio. Use plain "L / M / S" if you'd rather not compute them.

## Aspect ratio, `0xD211` (UINT8)

| Wire | Display | Confidence | Source                                             |
| ---- | ------- | ---------- | -------------------------------------------------- |
| `1`  | 3:2     | Verified   | HW (fixture current = 1, image 6192×4128), GP, SDK |
| `2`  | 16:9    | High       | GP, SDK                                            |
| `3`  | 4:3     | High       | GP, SDK                                            |
| `4`  | 1:1     | High       | GP, SDK                                            |

## Dynamic range optimizer, `0xD201` (UINT8)

| Wire          | Display       | Confidence | Source                              |
| ------------- | ------------- | ---------- | ----------------------------------- |
| `0x01`        | Off           | High       | GP                                  |
| `0x1F`        | DRO Auto      | High       | GP. Fixture current; Sony's default |
| `0x11`–`0x15` | DRO Lv1 … Lv5 | High       | GP                                  |

Not on the A6700: `0x02` DRO, `0x10` DRO+, `0x20` HDR Auto, `0x21`–`0x26` HDR 1.0–6.0 EV (GP).
The current `DynamicRangeOptimizer` labels are correct.

## Lens compensation, `0xD1A2` shading / `0xD1A3` chromatic aberration / `0xD1A4` distortion (UINT8)

| Wire | Display | Applies to   | Confidence            | Source                                                                                                                                       |
| ---- | ------- | ------------ | --------------------- | -------------------------------------------------------------------------------------------------------------------------------------------- |
| `1`  | Off     | all three    | High                  | SDK `CrLensCompensation*_Off = 1` (wire = SDK here)                                                                                          |
| `2`  | Auto    | all three    | Verified (distortion) | SDK. On the fixture, distortion is display-only and stuck at `2`. That fits Sony forcing distortion correction to Auto for the E PZ 18-105 G |
| `3`  | Low     | shading only | High                  | SDK `CrLensCompensationShading_Low`. Only shading lists it: {2, 3, 1}                                                                        |

## RAW compression, `0xD288` RAWFileType (UINT8)

| Wire | Display             | Confidence   | Source                                                                                                                                                                                                                                                                                                                                                                              |
| ---- | ------------------- | ------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `1`  | Compressed          | **Verified** | HW: TEST1 captures recorded `rawCompression` = `0x1`. The ARW's raw IFD has Compression = 32767 (Sony lossy) and SonyRawFileType (`0x7000`) = 2 ("Compressed RAW"). The files are a constant 29.2 MB; lossless files would vary in size                                                                                                                                             |
| `6`  | Lossless Compressed | Medium       | By elimination. The A6700 offers only Compressed and Lossless Compressed, and has no Uncompressed option (Sony spec, user reports). SDK numbering doesn't match the wire: `CrRAWFileCompressionType` has Uncompressed=0, Compression=1, LossLess=2, LossLessS/M/L=3–5 and Compressed_HQ=6. Check with one capture: SonyRawFileType should read 3 or 4 and the file size should vary |

No libgphoto2 entry exists for this property.

## Shutter speed, `0xD20D` (UINT32): special values only

Ordinary values are numerator<<16 | denominator, and `ShutterSpeed` already decodes them (30″ = `0x012C000A` … 1/4000 = `0x00010FA0`).

| Wire         | Display                | Confidence | Source                                               |
| ------------ | ---------------------- | ---------- | ---------------------------------------------------- |
| `0x00000000` | BULB                   | Verified   | HW (in M mode's list), GP, SDK `CrShutterSpeed_Bulb` |
| `0xFFFFFFFF` | — (nothing to display) | High       | SDK `CrShutterSpeed_Nothing`                         |

## ISO, `0xD21E` (UINT32): special values only

Bits 0–23 hold the ISO value. Bits 24–27 hold the mode (1 = multi-frame NR, 2 = MFNR High). Bits 28–31 flag an extended value. `ISOSensitivity` already decodes these.

| Wire                                       | Display                                           | Confidence | Source                                                                   |
| ------------------------------------------ | ------------------------------------------------- | ---------- | ------------------------------------------------------------------------ |
| `0x00FFFFFF`                               | ISO AUTO                                          | Verified   | HW (fixture current), GP, SDK `CrISO_AUTO`                               |
| `0x10000032` / `0x10000040` / `0x10000050` | 50 / 64 / 80 (extended)                           | High       | SDK bit layout, A6700 range (expandable down to ISO 50)                  |
| `0x10009C40` … `0x10019000`                | 40000 / 51200 / 64000 / 80000 / 102400 (extended) | High       | Same                                                                     |
| `0x01xxxxxx` / `0x02xxxxxx`                | MFNR / MFNR High + value                          | High       | GP `_stringify_Sony_ISO`, SDK. **Not offered** by the A6700 in this list |

Our formatter shows the low extended values as "L50". The A6700 menu shows them as "50", "64" and "80", marked as extended rather than with an "L" prefix. Either label works.

## Exposure compensation, `0x5010` (INT16)

The value is EV × 1000, ±5.0 in 1/3 steps. 300 is +0.3 and 700 is +0.7. There are no special values. Related: `0xD200` (GP name `DPCCompensation`) is flash compensation, ±3.0.

## Other enumerated properties the app sets or may show

| Code                                | Wire → display                                                                                                                            | Confidence      | Source                                                            |
| ----------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------- | --------------- | ----------------------------------------------------------------- |
| `0xD25A` PriorityKey                | `0` Camera, `1` PC Remote                                                                                                                 | Verified        | HW, GP `sony_prioritymode`. SDK numbers it 1/2. Don't use them    |
| `0xD222` StillImageStoreDestination | `0x01` PC only, `0x10` Camera (card) only, `0x11` PC + Camera                                                                             | Verified (0x11) | HW, GP `sony_capturetarget`. SDK numbers it 1/2/3. Don't use them |
| `0xD269` PCSaveImage                | `1` RAW+JPEG, `2` JPEG only, `3` RAW only (`4` RAW+HEIF, `5` HEIF only on other bodies)                                                   | Verified (1, 2) | HW, GP `sony_pc_save_image_format`                                |
| `0xD268` PCSaveImageSize            | `1` Original, `2` Small (2 MP)                                                                                                            | Verified (1)    | HW, GP                                                            |
| `0xD26A` LiveViewQuality            | `1` Standard (Low), `2` High                                                                                                              | Verified (2)    | HW, SDK names                                                     |
| `0xD150` USBPowerSupply             | `1` Off, `2` On                                                                                                                           | Verified (2)    | HW, SDK `CrUSBPowerSupply` (wire = SDK)                           |
| `0xD231` LiveViewSettingEffect      | `1` On, `2` Off                                                                                                                           | High            | GP                                                                |
| `0xD213` FocusIndication            | `1` Unlocked, `2` Focused, `3` No focus (low contrast), `5` Tracking, `6` Tracking focused, `7` Tracking no focus, `8` Unpause, `9` Pause | High            | GP `sony_focus_indication`                                        |
| `0xD255` AF tracking sensitivity    | `1`…`5` = 1 (Locked on) … 5 (Responsive)                                                                                                  | Medium          | GP name, A6700 menu                                               |

These codes are in the dataset but undecoded and not shown: `0xD241`, `0xD242` (movie file format and recording setting; movie only), `0xD23F` (picture profile;
movie-oriented), `0xD24F` (interval rec; movie), `0xD283`, `0xD286`, `0xD299`, `0xD2B5`, `0xD202`, `0xD207`, `0xD262`, `0xD263`.
