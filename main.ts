// Compass bearing and LED screen over BLE.
// Bearing characteristic E95D9715-251D-470A-A062-FA1922DFA9A8
// in Magnetometer Service E95DF2D8-251D-470A-A062-FA1922DFA9A8 (uint16 LE, degrees, read/notify).
// LED Service E95DD91D-251D-470A-A062-FA1922DFA9A8 lets a client set the screen:
// LED Matrix State E95D7B77-... (5 bytes, one per row, bit 4 = leftmost) or scroll LED Text E95D93EE-....
// No pairing required ("open" link).

bluetooth.startMagnetometerService()
bluetooth.startLEDService()

let connected = false
// The V1 runs out of memory (error 020) with the animation alongside Bluetooth, so it
// shows a plain cross while waiting instead.
const animate = control.hardwareVersion() != "1"

bluetooth.onBluetoothConnected(function () {
    connected = true
    basic.showIcon(IconNames.Yes)
})
bluetooth.onBluetoothDisconnected(function () {
    connected = false
    if (!animate) basic.showIcon(IconNames.No)
})

// Reading the heading here triggers compass calibration (tilt to fill the screen)
// on first boot, rather than waiting for the first BLE client.
input.compassHeading()
if (!animate) basic.showIcon(IconNames.No)

// While nothing is connected, a single pixel races across the screen towards north.
// It moves round a virtual 7x7 grid that wraps at its edges: the 5x5 screen (cells 1-5)
// plus a hidden one-pixel border, so a pixel leaving the screen comes back in from the
// opposite (south) side.
// Positions are whole numbers in hundredths of a cell.
let x = 300
let y = 300
let dx = 0
let dy = -100
let frame = 0

if (animate) basic.forever(function () {
    if (connected) return
    // The compass changes slowly, so only read it every 7th frame (about every 100 ms).
    if (frame % 7 == 0) {
        const heading = input.compassHeading() * Math.PI / 180
        // North relative to the board, in screen coordinates (x right, y down).
        dx = Math.round(-Math.sin(heading) * 100)
        dy = Math.round(-Math.cos(heading) * 100)
    }
    frame++
    x = (x + dx + 700) % 700
    y = (y + dy + 700) % 700
    basic.clearScreen()
    led.plot(Math.idiv(x, 100) - 1, Math.idiv(y, 100) - 1) // ignored while in the hidden border
    basic.pause(15)
})
