# micro:bit compass over BLE

A MakeCode program for the BBC micro:bit (V1 and V2) that exposes its compass bearing over Bluetooth Low Energy, plus a one-click WebUSB flasher page.

## Flashing

Open the flasher page (published by GitHub Pages from this repo) in Chrome or Edge, plug in a micro:bit over USB and click **Flash micro:bit**. Or download `binary.hex` from the page, or from the latest workflow run, and drag it onto the `MICROBIT` drive.

On first boot the micro:bit scrolls "TILT TO FILL SCREEN": tilt it until every LED is lit to calibrate the compass. It shows ✗ while waiting for a connection and ✓ when connected.

## Viewing bearings

`compass.html` (linked from the flasher page) uses Web Bluetooth to connect to any number of micro:bits and show each one's live bearing on a dial. Chrome can't scan in the background, so add each board through Chrome's device picker; boards already allowed reconnect automatically where Chrome supports `getDevices()`.

## Bluetooth

- Advertises as `BBC micro:bit [xxxxx]`; no pairing required (open link)
- Magnetometer Service `E95DF2D8-251D-470A-A062-FA1922DFA9A8`
- Bearing characteristic `E95D9715-251D-470A-A062-FA1922DFA9A8`: uint16 little-endian, degrees (0–359), read and notify

## Building locally

```sh
npm ci
npm run build   # main.ts -> built/binary.hex (MakeCode cloud compiler, needs internet), then _site/
npm run serve   # WebUSB needs localhost or HTTPS
```

Pushing to `main` runs the same build in GitHub Actions and deploys `_site/` to GitHub Pages.
