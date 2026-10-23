// Compass bearing and LED screen over BLE.
// Bearing characteristic E95D9715-251D-470A-A062-FA1922DFA9A8
// in Magnetometer Service E95DF2D8-251D-470A-A062-FA1922DFA9A8 (uint16 LE, degrees, read/notify).
// LED Service E95DD91D-251D-470A-A062-FA1922DFA9A8 lets a client set the screen:
// LED Matrix State E95D7B77-... (5 bytes, one per row, bit 4 = leftmost) or scroll LED Text E95D93EE-....
// No pairing required ("open" link).

bluetooth.startMagnetometerService()
bluetooth.startLEDService()

bluetooth.onBluetoothConnected(function () {
    basic.showIcon(IconNames.Yes)
})
bluetooth.onBluetoothDisconnected(function () {
    basic.showIcon(IconNames.No)
})

// Reading the heading here triggers compass calibration (tilt to fill the screen)
// on first boot, rather than waiting for the first BLE client.
input.compassHeading()
basic.showIcon(IconNames.No)
