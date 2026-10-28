# Points North

[Points North](https://github.com/davidchatting/pointsnorth-old) is for games around tables: each device shows a ring with every device in its session (its own at the bottom) drawn as an outline of its screen at its real-world position, found by comparing compass bearings. This repo takes it beyond phones in a browser, to a native iOS app, the M5Stack AtomS3R and BBC micro:bits.

Every device joins a session through the original's WebSocket relay (`wss://api.davidchatting.com/pubgames`). Devices that can't reach it themselves are bridged by one that can:

| Device | Folder | How it joins |
|---|---|---|
| Phone, tablet or laptop browser | `web/` | Over the internet, by scanning a session's QR code |
| iPhone or iPad | `ios/PointsNorth.swift` | Over the internet, by scanning a QR code; as a **hub**, it also bridges micro:bits |
| AtomS3R | `atoms3r/` | Over WiFi, joining the session iOS apps nearby advertise over Bluetooth |
| micro:bit V1 or V2 | `main.ts` | Over Bluetooth, through an iOS hub |
| The relay | `server/` | |

**Play:** https://davidchatting-bot.github.io/pointsnorth/ · **Flash a micro:bit:** https://davidchatting-bot.github.io/pointsnorth/flasher/

## Playing

The first device makes a session, shown as a QR code in the middle of its ring; scan it to join. Then:

- **Tap** a device's outline to flash its screen (a micro:bit lights all its LEDs).
- **Swipe** left or right to flash the device next to you on that side.
- The Atom has no touch screen: **click** its button for the device on your right, **hold** for your left.
- A micro:bit's **A** and **B** buttons send the same message as a swipe, A to its left neighbour and B to its right.

Lay devices flat, pointing into the middle of the table: a device's position round the ring comes from the direction it points.

## Web app

`web/` is the original web app with hubs added: it's served at the root of the site. `?server=ws://host:port/pubgames` points it at another relay.

## iOS app

`ios/PointsNorth.swift` is a single-file SwiftUI app for iPhone and iPad. To build it, make a new iOS App (SwiftUI) project in Xcode, replace its two Swift files with this one, and add "Privacy - Bluetooth Always Usage Description" and "Privacy - Camera Usage Description" in the target's Info tab.

It starts a session of its own, with its QR code in the middle; **JOIN** scans another device's QR code (the web app's too), and **SERVER:** shows whether it can reach the relay (connecting, online or offline). **SPOKE | HUB** at the top picks its role:

- **SPOKE**: a device in the session like any other.
- **HUB**: also bridges micro:bits, which only speak Bluetooth. It connects to every micro:bit nearby and gives each its own WebSocket, so to everyone else a micro:bit is just another device (drawn to the micro:bit's size). It smooths each micro:bit's bearing (settling in about a second, passed on in steps of 2° or more, at most five times a second), turns its A and B presses into swipes, and lights its LEDs when it's messaged.

As a hub or a spoke, it advertises its session over Bluetooth for the Atom. iOS only advertises while the app is open on screen, so it keeps the screen awake.

## AtomS3R

`atoms3r/` is a PlatformIO project for the M5Stack AtomS3R, a spoke over WiFi. Build and flash with `pio run -t upload` from that folder.

- **WiFi:** the first time it starts (or if you hold its button while it starts), it opens a WiFi network of its own, `PN-Atom-xxxx`, named on its screen: join it from a phone and pick your network in the page that opens.
- **Session:** it has no camera, so it joins the session the iOS apps nearby advertise over Bluetooth, staying in its session while anything nearby still advertises it and otherwise moving to the strongest. Until then the middle of its ring says what it's waiting for (`WiFi`, `session?` or `server?`).
- **Compass:** tilt-compensated, smoothed (it settles in about a second) and only changes in steps of 2° or more. It uses M5Unified's magnetometer calibration, saved to flash once a minute when it changes: turn it slowly through every direction once, then leave it running for a minute.
- **Serial:** it prints a status line every 2 seconds, plus each message it receives.
- **Another relay:** see the commented-out build flags in `platformio.ini`.

## micro:bit firmware

`main.ts` is a [MakeCode](https://makecode.microbit.org) program for the BBC micro:bit (V1 and V2) that exposes its compass bearing, LED screen and buttons over Bluetooth Low Energy, with no pairing. On its own it does nothing for Points North: it plays through an iOS hub.

### Flashing

Open the [flasher page](https://davidchatting-bot.github.io/pointsnorth/flasher/) in Chrome or Edge, plug in a micro:bit over USB and click **Flash micro:bit**. Or download `binary.hex` from the page, or from the latest workflow run, and drag it onto the `MICROBIT` drive.

On first boot the micro:bit scrolls "TILT TO FILL SCREEN": tilt it until every LED is lit to calibrate the compass. While waiting for a connection, a single pixel races across the screen towards north, wrapping round from the south side; it shows ✓ when connected.

### Bluetooth services

- Advertises as `BBC micro:bit [xxxxx]`; no pairing required (open link)
- Magnetometer Service `E95DF2D8-251D-470A-A062-FA1922DFA9A8`
  - Bearing `E95D9715-251D-470A-A062-FA1922DFA9A8`: uint16 little-endian, degrees (0–359), read and notify
- LED Service `E95DD91D-251D-470A-A062-FA1922DFA9A8`
  - LED Matrix State `E95D7B77-251D-470A-A062-FA1922DFA9A8`: 5 bytes, one per row (top first), bit 4 = leftmost LED; read and write
  - LED Text `E95D93EE-251D-470A-A062-FA1922DFA9A8`: write up to 20 bytes of text to scroll
- Button Service `E95D9882-251D-470A-A062-FA1922DFA9A8`
  - Button A State `E95DDA90-251D-470A-A062-FA1922DFA9A8` and Button B State `E95DDA91-251D-470A-A062-FA1922DFA9A8`: uint8, 0 released, 1 pressed, 2 long press; read and notify

### Hardware notes

Tested boards (board ID is the first four digits of `Unique ID` in the drive's `DETAILS.TXT`):

| Board | Board ID | Chip | DAPLink interface | Status |
|---|---|---|---|---|
| micro:bit V1.5 | 9901 | nRF51822, 16 KB RAM | 0249 | Works: compass, BLE, LED service and animation; hangs on button presses while bridged ([#1](https://github.com/davidchatting-bot/pointsnorth/issues/1)) |
| micro:bit V2.2 | 9904 | nRF52833, 128 KB RAM | 0255 | Works: compass, BLE, LED and Button services, animation |
| micro:bit V1.3 | 9900 | nRF51822, 16 KB RAM | 0234 | Works: compass, BLE, LED service and animation (flashed by drag and drop) |

DAPLink older than 0249 (like the V1.3's 0234) has no WebUSB, so the flasher page can't reach it: drag `binary.hex` onto the `MICROBIT` drive instead, or [update the interface firmware](https://microbit.org/get-started/user-guide/firmware/). Old DAPLink also writes `DETAILS.TXT` in an older format, without the `Unique ID` line; the board ID is still the first four digits of the USB serial number.

`binary.hex` is a universal hex holding both a V1 (DAL) and a V2 (CODAL) build; each board picks its own section.

**V1 memory.** With Bluetooth running, the V1 has very little RAM left for the program, and running out shows a sad face followed by `020`. A build with two `forever` loops (one for the compass, one for the animation) failed this way. The animation therefore uses a single `forever` loop and whole-number positions (hundredths of a cell), and only does floating-point maths when reading the compass every 5th frame. Connecting is the tightest moment: the Bluetooth stack allocates the connection then, so the connect/disconnect handlers only set a flag (a handler that pauses, as `showIcon` does, gets its own fiber and caused `020` on connect) and the main loop shows the ✓. Keep new features to the same budget and test them on a V1, including connecting to it.

**Bluetooth settings** (`pxt.json`). These match MakeCode's "No Pairing Required" option (`open: 1`, `whitelist: 0`, `security_level: null`). They also turn off the Event Service and Eddystone beacons (`event_service: 0`, `eddystone_url: 0`, `eddystone_uid: 0`) and set `gatt_table_size: 0x700`. Without these, a V1 with both the Magnetometer and LED services showed a blank screen or advertised no services. The DFU, partial flashing and Device Information services are also off (`dfu_service`, `partial_flashing`, `device_info_service`) to free RAM on the V1; this doesn't affect flashing over USB or WebUSB.

**Compass.** `input.compassHeading()` is called once at boot so calibration ("TILT TO FILL SCREEN") happens before any client connects. The bearing service reads the compass itself; the animation reads it about every 110 ms. Magnets and nearby metal skew the reading.

**Web Bluetooth with V1 on Android.** According to the `@microbit/microbit-connection` docs, the V1 firmware declares a display-only pairing capability even in open-link mode. So on Android, anything that asks to bond with a V1 may get a PIN prompt. The compass page doesn't bond, so it shouldn't hit this.

Built with pxt-microbit 9.1.1 and pxt-core 13.0.1.

## Relay

`server/` is a copy of the original's `server.js`, unchanged: hubs and roles are all in the clients. Run `npm install` then `node server.js` in that folder; it listens on port 3000 at `/pubgames`. It relays JSON between the members of each session and has no game logic of its own.

## Protocol

### Messages

The original's JSON messages, each with `clientId` and `sessionId`: `client_info` (`width`, `height`, `bearing`, and now `role`; answered by everyone with their own, sent to the newcomer's `targetClientId`), `compass` (the same fields, whenever the bearing changes), `message` (`text`, to a `targetClientId`) and `disconnect` (sent by the relay when a socket closes). The relay remembers the last client ID each socket used, and delivers a message with a `targetClientId` to the first socket in the session with that ID; a message without one goes to everyone else in the session. That's why each bridged micro:bit needs a socket of its own.

### Hubs

A hub says so in its `client_info` and `compass` messages (`"role": "hub"`; everyone else sends `"spoke"`), and every ring draws hubs in the middle, turned to their bearing, with the session's QR code upright on the hub. Neighbours are the devices round the ring with a bearing, in bearing order: devices sit opposite where they point, so the next lower bearing is on your right. Hubs have no neighbours. Nothing stops a session having more than one hub, but they share the middle, and a micro:bit can only be connected to one of them.

### Session over Bluetooth

The iOS app, as hub or spoke, advertises the name `PN <session ID>` with the Points North Service `00E43092-366D-46DA-8323-42BF39B7078E`, whose Session characteristic `7513CE11-F0CA-49FC-A8BF-E9D4F8021FA3` holds the session ID as UTF-8, in case a scanner doesn't get the name.

## Other tools

From before Points North, for the micro:bit firmware on its own:

- **Compass page** (`web/compass/`, at [`/compass/`](https://davidchatting-bot.github.io/pointsnorth/compass/)): a p5.js sketch that fills the screen with a micro:bit-style LED screen running the firmware's animation, steered by the compass of the phone or tablet it's running on. Tap **Start** to grant compass access (iOS asks; Android Chrome doesn't need to); on a device without a compass, drag to set north. **Add micro:bit** (Chrome or Edge with Web Bluetooth, including Android) connects to micro:bits running the firmware: each appears as a smaller LED screen below, animated from its own live bearing, with its A and B buttons either side lit while pressed; tap a screen to disconnect it. Chrome can't scan in the background, so add each board through Chrome's device picker; boards already allowed reconnect automatically where Chrome supports `getDevices()`. iOS browsers don't support Web Bluetooth, so on an iPhone the page shows the phone's own compass only.
- **`ios/CompassBLE.swift`**: a single-file SwiftUI app that makes an iPhone or iPad act like a micro:bit running the firmware. It advertises its compass bearing and on-screen A/B buttons with the same services, named `BBC micro:bit [iphone]` or `[ipad]`, measured from the top of the screen however it's rotated, and shows the same racing pixel. Set up in Xcode like the iOS app above, with just the Bluetooth key. The compass page's picker also accepts any device advertising the Magnetometer Service, since Chrome may know the iPhone by its own name.

## Building

```sh
npm ci
npm run build   # main.ts -> built/binary.hex (MakeCode cloud compiler, needs internet), then web/ -> _site/
npm run serve   # WebUSB needs localhost or HTTPS
```

Pushing to `main` runs the same build in GitHub Actions and deploys `_site/` to GitHub Pages: Points North at the root, the flasher at `flasher/` and the compass page at `compass/`. The iOS apps build in Xcode, the Atom project with PlatformIO, and the relay needs only Node.

## Credits

Based on an idea co-developed with [Edward Jenkins](https://edjenkins.co.uk).

## License

This code is licensed under the [MIT License](LICENSE).
