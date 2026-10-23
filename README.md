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

## Building locally

```sh
npm ci
npm run build   # main.ts -> built/binary.hex (MakeCode cloud compiler, needs internet), then _site/
npm run serve   # WebUSB needs localhost or HTTPS
```

Pushing to `main` runs the same build in GitHub Actions and deploys `_site/` to GitHub Pages.
