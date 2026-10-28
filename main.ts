// Compass bearing, LED screen and buttons over BLE.
// Bearing characteristic E95D9715-251D-470A-A062-FA1922DFA9A8
// in Magnetometer Service E95DF2D8-251D-470A-A062-FA1922DFA9A8 (uint16 LE, degrees, read/notify).
// LED Service E95DD91D-251D-470A-A062-FA1922DFA9A8 lets a client set the screen:
// LED Matrix State E95D7B77-... (5 bytes, one per row, bit 4 = leftmost) or scroll LED Text E95D93EE-....
// Button Service E95D9882-251D-470A-A062-FA1922DFA9A8: Button A State E95DDA90-... and
// Button B State E95DDA91-... (uint8: 0 released, 1 pressed, 2 long press; read/notify).
// No pairing required ("open" link).
//
// While nothing is connected the screen shows a single pixel in the middle; once something
// connects (a Points North hub) the screen is the client's to draw, over the LED Service.

bluetooth.startMagnetometerService()
bluetooth.startLEDService()
bluetooth.startButtonService()

// The handlers only set a flag: anything that pauses would make the handler run in its own
// fiber, and on a V1 that extra memory at connection time causes error 020. The main loop
// draws the waiting pixel instead.
let connected = false
let waitingShown = false

bluetooth.onBluetoothConnected(function () {
    connected = true
})
bluetooth.onBluetoothDisconnected(function () {
    connected = false
    waitingShown = false
})

// Reading the heading here triggers compass calibration (tilt to fill the screen)
// on first boot, rather than waiting for the first BLE client.
input.compassHeading()

basic.forever(function () {
    if (!connected && !waitingShown) {
        waitingShown = true
        basic.clearScreen()
        led.plot(2, 2)
    }
    basic.pause(100)
})
