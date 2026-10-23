// Compass bearing and LED screen over BLE.
// Bearing characteristic E95D9715-251D-470A-A062-FA1922DFA9A8
// in Magnetometer Service E95DF2D8-251D-470A-A062-FA1922DFA9A8 (uint16 LE, degrees, read/notify).
// LED Service E95DD91D-251D-470A-A062-FA1922DFA9A8 lets a client set the screen:
// LED Matrix State E95D7B77-... (5 bytes, one per row, bit 4 = leftmost) or scroll LED Text E95D93EE-....
// No pairing required ("open" link).

bluetooth.startMagnetometerService()
bluetooth.startLEDService()

// The handlers only set a flag: anything that pauses (like showIcon) would make the
// handler run in its own fiber, and on a V1 that extra memory at connection time
// causes error 020. The main loop shows the tick instead.
let connected = false
let tickShown = false

bluetooth.onBluetoothConnected(function () {
    connected = true
})
bluetooth.onBluetoothDisconnected(function () {
    connected = false
    tickShown = false
})

// Reading the heading here triggers compass calibration (tilt to fill the screen)
// on first boot, rather than waiting for the first BLE client.
input.compassHeading()

// While nothing is connected, a single pixel races across the screen towards north.
// It moves round a virtual 7x7 grid that wraps at its edges: the 5x5 screen (cells 1-5)
// plus a hidden one-pixel border, so a pixel leaving the screen comes back in from the
// opposite (south) side, at a random spot across its direction of travel.
// Positions are whole numbers in hundredths of a cell.
let x = 300
let y = 300
let dx = 0
let dy = -100
let frame = 0
let lastSpot = -1

// The centre of a random screen cell (never the same one twice running), as a position.
function randomSpot() {
    let spot = randint(0, 4)
    while (spot == lastSpot) spot = randint(0, 4)
    lastSpot = spot
    return (spot + 1) * 100 + 50
}

basic.forever(function () {
    if (connected) {
        if (!tickShown) {
            tickShown = true
            basic.showIcon(IconNames.Yes)
        }
        basic.pause(100)
        return
    }
    // The compass changes slowly, so only read it every 5th frame (about every 110 ms).
    if (frame % 5 == 0) {
        const heading = input.compassHeading() * Math.PI / 180
        // North relative to the board, in screen coordinates (x right, y down).
        dx = Math.round(-Math.sin(heading) * 100)
        dy = Math.round(-Math.cos(heading) * 100)
    }
    frame++
    let nx = (x + dx + 700) % 700
    let ny = (y + dy + 700) % 700
    // A big jump means it just wrapped round through the hidden border.
    if (Math.abs(ny - y) > 350) nx = randomSpot()
    else if (Math.abs(nx - x) > 350) ny = randomSpot()
    x = nx
    y = ny
    basic.clearScreen()
    led.plot(Math.idiv(x, 100) - 1, Math.idiv(y, 100) - 1) // ignored while in the hidden border
    basic.pause(22)
})
