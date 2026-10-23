# micro:bit compass over BLE

A MakeCode program for the BBC micro:bit (V1 and V2) that exposes its compass bearing over Bluetooth Low Energy, plus a one-click WebUSB flasher page.

## Flashing

Open the flasher page (published by GitHub Pages from this repo) in Chrome or Edge, plug in a micro:bit over USB and click **Flash micro:bit**. Or download `binary.hex` from the page, or from the latest workflow run, and drag it onto the `MICROBIT` drive.

On first boot the micro:bit scrolls "TILT TO FILL SCREEN": tilt it until every LED is lit to calibrate the compass. While waiting for a connection, a single pixel races across the screen towards north, wrapping round from the south side; it shows ✓ when connected.

## Viewing bearings

`compass.html` (linked from the flasher page) uses Web Bluetooth to connect to any number of micro:bits and show each one's live bearing on a dial. Under each dial, a 5×5 grid of buttons draws on that board's LED screen, and a text box scrolls up to 20 characters across it (a single character is drawn still, using the micro:bit font, rather than scrolled). Chrome can't scan in the background, so add each board through Chrome's device picker; boards already allowed reconnect automatically where Chrome supports `getDevices()`.

## Bluetooth

- Advertises as `BBC micro:bit [xxxxx]`; no pairing required (open link)
- Magnetometer Service `E95DF2D8-251D-470A-A062-FA1922DFA9A8`
- Bearing characteristic `E95D9715-251D-470A-A062-FA1922DFA9A8`: uint16 little-endian, degrees (0–359), read and notify
- LED Service `E95DD91D-251D-470A-A062-FA1922DFA9A8`
  - LED Matrix State `E95D7B77-251D-470A-A062-FA1922DFA9A8`: 5 bytes, one per row (top first), bit 4 = leftmost LED; read and write
  - LED Text `E95D93EE-251D-470A-A062-FA1922DFA9A8`: write up to 20 bytes of text to scroll

## Hardware notes

Tested boards (board ID is the first four digits of `Unique ID` in the drive's `DETAILS.TXT`):

| Board | Board ID | Chip | DAPLink interface | Status |
|---|---|---|---|---|
| micro:bit V1.5 | 9901 | nRF51822, 16 KB RAM | 0249 | Works: compass, BLE, LED service and animation |
| micro:bit V2.2 | 9904 | nRF52833, 128 KB RAM | 0255 | Works: compass, BLE, LED service and animation |
| micro:bit V1.3 | 9900 | nRF51822, 16 KB RAM | 0234 | Works: compass, BLE, LED service and animation (flashed by drag and drop) |

DAPLink older than 0249 (like the V1.3's 0234) has no WebUSB, so the flasher page can't reach it: drag `binary.hex` onto the `MICROBIT` drive instead, or [update the interface firmware](https://microbit.org/get-started/user-guide/firmware/). Old DAPLink also writes `DETAILS.TXT` in an older format, without the `Unique ID` line; the board ID is still the first four digits of the USB serial number.

`binary.hex` is a universal hex holding both a V1 (DAL) and a V2 (CODAL) build; each board picks its own section.

**V1 memory.** With Bluetooth running, the V1 has very little RAM left for the program, and running out shows a sad face followed by `020`. A build with two `forever` loops (one for the compass, one for the animation) failed this way. The animation therefore uses a single `forever` loop and whole-number positions (hundredths of a cell), and only does floating-point maths when reading the compass every 5th frame. Keep new features to the same budget and test them on a V1.

**Bluetooth settings** (`pxt.json`). These match MakeCode's "No Pairing Required" option (`open: 1`, `whitelist: 0`, `security_level: null`). They also turn off the Event Service and Eddystone beacons (`event_service: 0`, `eddystone_url: 0`, `eddystone_uid: 0`) and set `gatt_table_size: 0x700`. Without these, a V1 with both the Magnetometer and LED services showed a blank screen or advertised no services. The DFU and Device Information services are still on, and are what to remove next if a V1 needs more memory.

**Compass.** `input.compassHeading()` is called once at boot so calibration ("TILT TO FILL SCREEN") happens before any client connects. The bearing service reads the compass itself; the animation reads it about every 110 ms. Magnets and nearby metal skew the reading.

**Web Bluetooth with V1 on Android.** According to the `@microbit/microbit-connection` docs, the V1 firmware declares a display-only pairing capability even in open-link mode. So on Android, anything that asks to bond with a V1 may get a PIN prompt. The compass page doesn't bond, so it shouldn't hit this.

Built with pxt-microbit 9.1.1 and pxt-core 13.0.1.

## Building locally

```sh
npm ci
npm run build   # main.ts -> built/binary.hex (MakeCode cloud compiler, needs internet), then _site/
npm run serve   # WebUSB needs localhost or HTTPS
```

Pushing to `main` runs the same build in GitHub Actions and deploys `_site/` to GitHub Pages.
