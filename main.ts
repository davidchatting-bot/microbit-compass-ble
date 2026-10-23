// Compass bearing and LED screen over BLE.
// Bearing characteristic E95D9715-251D-470A-A062-FA1922DFA9A8
// in Magnetometer Service E95DF2D8-251D-470A-A062-FA1922DFA9A8 (uint16 LE, degrees, read/notify).
// LED Service E95DD91D-251D-470A-A062-FA1922DFA9A8 lets a client set the screen:
// LED Matrix State E95D7B77-... (5 bytes, one per row, bit 4 = leftmost) or scroll LED Text E95D93EE-....
// No pairing required ("open" link).

bluetooth.startMagnetometerService()
bluetooth.startLEDService()

let connected = false

bluetooth.onBluetoothConnected(function () {
    connected = true
    basic.showIcon(IconNames.Yes)
})
bluetooth.onBluetoothDisconnected(function () {
    connected = false
})

// Reading the heading here triggers compass calibration (tilt to fill the screen)
// on first boot, rather than waiting for the first BLE client.
input.compassHeading()

// While nothing is connected, a single pixel races across the screen towards north.
// It moves round a virtual 7x7 grid that wraps at its edges: the 5x5 screen (cells 1-5)
// plus a hidden one-pixel border, so a pixel leaving the screen comes back in from the
// opposite (south) side.
let x = 3
let y = 3
let dx = 0
let dy = -1

// The compass changes slowly, so read it on its own loop rather than every frame.
basic.forever(function () {
    const heading = input.compassHeading() * Math.PI / 180
    // North relative to the board, in screen coordinates (x right, y down).
    dx = -Math.sin(heading)
    dy = -Math.cos(heading)
    basic.pause(100)
})

basic.forever(function () {
    if (connected) return
    x = (x + dx + 7) % 7
    y = (y + dy + 7) % 7
    basic.clearScreen()
    led.plot(Math.floor(x) - 1, Math.floor(y) - 1) // ignored while in the hidden border
    basic.pause(15)
})
