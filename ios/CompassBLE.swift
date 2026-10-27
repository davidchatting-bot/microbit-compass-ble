// Compass BLE for iPhone: does what the micro:bit firmware does. It advertises the phone's
// compass bearing and A/B buttons over BLE with the micro:bit's services, so the compass app
// can add it like a micro:bit, and shows a single LED racing towards north (✓ once connected).
//
// Setup: in Xcode make a new iOS App (SwiftUI) project, delete its two Swift files, add this
// one, and in the target's Info tab add "Privacy - Bluetooth Always Usage Description".
// iOS only advertises while the app is open on screen, so it keeps the screen awake.

import Combine
import CoreBluetooth
import CoreLocation
import SwiftUI

// Magnetometer Service: Bearing (uint16 LE, degrees, read/notify).
let magnetometerService = CBUUID(string: "E95DF2D8-251D-470A-A062-FA1922DFA9A8")
let bearingCharacteristic = CBUUID(string: "E95D9715-251D-470A-A062-FA1922DFA9A8")
// Button Service: Button A and B State (uint8: 0 released, 1 pressed, 2 long press; read/notify).
let buttonService = CBUUID(string: "E95D9882-251D-470A-A062-FA1922DFA9A8")
let buttonCharacteristics = [CBUUID(string: "E95DDA90-251D-470A-A062-FA1922DFA9A8"),
                             CBUUID(string: "E95DDA91-251D-470A-A062-FA1922DFA9A8")]
// The compass app's device picker filters on the "BBC micro:bit" prefix.
let advertisedName = "BBC micro:bit [iphone]"
let longPressSeconds = 1.0

// One byte per row (top first), bit 4 = leftmost LED, like the LED Matrix State.
let tick: [UInt8] = [0b00000, 0b00001, 0b00010, 0b10100, 0b01000]

final class Compass: NSObject, ObservableObject, CBPeripheralManagerDelegate, CLLocationManagerDelegate {
    @Published var rows: [UInt8] = Array(repeating: 0, count: 5)
    @Published var bearing: Int?
    @Published var buttons = [0, 0]
    @Published var connected = false
    @Published var status = "Starting Bluetooth…"

    private var peripheral: CBPeripheralManager!
    private let location = CLLocationManager()
    private var bearingChar: CBMutableCharacteristic?
    private var buttonChars: [CBMutableCharacteristic] = []
    private var subscriptions = Set<String>() // "central/characteristic"
    private var longPresses: [DispatchWorkItem?] = [nil, nil]
    private var timer: Timer?

    // While nothing is connected, a single pixel races across the screen towards north.
    // It moves round a virtual 7x7 grid that wraps at its edges: the 5x5 screen (cells 1-5)
    // plus a hidden one-pixel border, so a pixel leaving the screen comes back in from the
    // opposite side, at a random spot across its direction of travel.
    // Positions are in hundredths of a cell.
    private var x = 300, y = 300, lastSpot = -1

    override init() {
        super.init()
        peripheral = CBPeripheralManager(delegate: self, queue: nil)
        location.delegate = self
        location.headingOrientation = .portrait
        location.startUpdatingHeading()
        timer = Timer.scheduledTimer(withTimeInterval: 0.022, repeats: true) { [weak self] _ in self?.step() }
    }

    // The centre of a random screen cell (never the same one twice running), as a position.
    private func randomSpot() -> Int {
        var spot = Int.random(in: 0..<5)
        while spot == lastSpot { spot = Int.random(in: 0..<5) }
        lastSpot = spot
        return (spot + 1) * 100 + 50
    }

    private func step() {
        if connected {
            rows = tick
            return
        }
        guard let bearing else { return }
        // North relative to the phone, in screen coordinates (x right, y down).
        let heading = Double(bearing) * .pi / 180
        let dx = Int((-sin(heading) * 100).rounded()), dy = Int((-cos(heading) * 100).rounded())
        var nx = (x + dx + 700) % 700, ny = (y + dy + 700) % 700
        // A big jump means it just wrapped round through the hidden border.
        if abs(ny - y) > 350 { nx = randomSpot() } else if abs(nx - x) > 350 { ny = randomSpot() }
        x = nx
        y = ny
        var lit: [UInt8] = Array(repeating: 0, count: 5)
        let col = x / 100 - 1, row = y / 100 - 1
        if (0..<5).contains(col) && (0..<5).contains(row) { lit[row] = 1 << (4 - col) } // hidden in the border
        rows = lit
    }

    // MARK: Buttons

    func press(_ i: Int) {
        guard buttons[i] == 0 else { return }
        setButton(i, 1)
        let long = DispatchWorkItem { [weak self] in self?.setButton(i, 2) }
        longPresses[i] = long
        DispatchQueue.main.asyncAfter(deadline: .now() + longPressSeconds, execute: long)
    }

    func release(_ i: Int) {
        longPresses[i]?.cancel()
        setButton(i, 0)
    }

    private func setButton(_ i: Int, _ state: Int) {
        buttons[i] = state
        if i < buttonChars.count {
            peripheral.updateValue(Data([UInt8(state)]), for: buttonChars[i], onSubscribedCentrals: nil)
        }
    }

    // MARK: Compass

    func locationManager(_ manager: CLLocationManager, didUpdateHeading heading: CLHeading) {
        guard heading.headingAccuracy >= 0 else { return }
        let value = Int(heading.magneticHeading.rounded()) % 360
        guard value != bearing else { return }
        bearing = value
        if let bearingChar { peripheral.updateValue(uint16(value), for: bearingChar, onSubscribedCentrals: nil) }
    }

    func locationManagerShouldDisplayHeadingCalibration(_ manager: CLLocationManager) -> Bool { true }

    // MARK: Bluetooth

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        switch peripheral.state {
        case .poweredOn: status = "Starting to advertise…"
        case .poweredOff: status = "Bluetooth is off"
        case .unauthorized: status = "Bluetooth not allowed: see Settings → Privacy → Bluetooth"
        case .unsupported: status = "No Bluetooth LE on this device"
        default: status = "Bluetooth unavailable"
        }
        guard peripheral.state == .poweredOn else { return }
        let props: CBCharacteristicProperties = [.read, .notify]
        let bearing = CBMutableCharacteristic(type: bearingCharacteristic, properties: props, value: nil, permissions: .readable)
        let magnetometer = CBMutableService(type: magnetometerService, primary: true)
        magnetometer.characteristics = [bearing]

        buttonChars = buttonCharacteristics.map {
            CBMutableCharacteristic(type: $0, properties: props, value: nil, permissions: .readable)
        }
        let buttons = CBMutableService(type: buttonService, primary: true)
        buttons.characteristics = buttonChars

        bearingChar = bearing
        peripheral.removeAllServices()
        peripheral.add(magnetometer)
        peripheral.add(buttons)
        peripheral.startAdvertising([CBAdvertisementDataLocalNameKey: advertisedName,
                                     CBAdvertisementDataServiceUUIDsKey: [magnetometerService]])
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        status = error.map { "Couldn't advertise: \($0.localizedDescription)" } ?? "Advertising as \(advertisedName)"
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if let error { status = "Couldn't add service: \(error.localizedDescription)" }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        let data: Data
        if request.characteristic.uuid == bearingCharacteristic {
            data = uint16(bearing ?? 0)
        } else if let i = buttonCharacteristics.firstIndex(of: request.characteristic.uuid) {
            data = Data([UInt8(buttons[i])])
        } else {
            peripheral.respond(to: request, withResult: .attributeNotFound)
            return
        }
        guard request.offset <= data.count else {
            peripheral.respond(to: request, withResult: .invalidOffset)
            return
        }
        request.value = data.subdata(in: request.offset..<data.count)
        peripheral.respond(to: request, withResult: .success)
    }

    // iOS doesn't report connections, so "connected" means something is subscribed.
    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        subscriptions.insert("\(central.identifier)/\(characteristic.uuid)")
        connected = true
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        subscriptions.remove("\(central.identifier)/\(characteristic.uuid)")
        connected = !subscriptions.isEmpty
    }

    private func uint16(_ value: Int) -> Data { Data([UInt8(value & 0xff), UInt8(value >> 8)]) }
}

// MARK: Views

let ledOn = Color(red: 1, green: 0x3b / 255, blue: 0x30 / 255)
let ledOff = Color(red: 0x2a / 255, green: 0x13 / 255, blue: 0x12 / 255)
let boardColor = Color(red: 0x15 / 255, green: 0x15 / 255, blue: 0x18 / 255)
let textColor = Color(red: 0xc9 / 255, green: 0xc9 / 255, blue: 0xd1 / 255)

struct LedScreen: View {
    let rows: [UInt8]
    let size: CGFloat

    var body: some View {
        let pitch = size / 5
        VStack(spacing: 0) {
            ForEach(0..<5, id: \.self) { y in
                HStack(spacing: 0) {
                    ForEach(0..<5, id: \.self) { x in
                        let on = (rows[y] >> (4 - x)) & 1 == 1
                        RoundedRectangle(cornerRadius: pitch * 0.06)
                            .fill(on ? ledOn : ledOff)
                            .frame(width: pitch * 0.25, height: pitch * 0.42)
                            .shadow(color: on ? ledOn : .clear, radius: pitch * 0.3)
                            .frame(width: pitch, height: pitch)
                    }
                }
            }
        }
        .padding(pitch * 0.3)
        .background(RoundedRectangle(cornerRadius: pitch * 0.35).fill(boardColor))
    }
}

struct ButtonView: View {
    let label: String
    let state: Int
    let press: () -> Void
    let release: () -> Void

    var body: some View {
        Text(label)
            .font(.title2.bold())
            .foregroundColor(state > 0 ? .white : textColor)
            .frame(width: 56, height: 56)
            .background(Circle().fill(state > 0 ? ledOn : boardColor))
            .gesture(DragGesture(minimumDistance: 0).onChanged { _ in press() }.onEnded { _ in release() })
    }
}

struct ContentView: View {
    @StateObject private var compass = Compass()

    var body: some View {
        VStack(spacing: 24) {
            HStack(spacing: 16) {
                ButtonView(label: "A", state: compass.buttons[0], press: { compass.press(0) }, release: { compass.release(0) })
                LedScreen(rows: compass.rows, size: 200)
                ButtonView(label: "B", state: compass.buttons[1], press: { compass.press(1) }, release: { compass.release(1) })
            }
            Text(compass.bearing.map { "\($0)°" } ?? "Waiting for compass…")
                .font(.title3)
                .foregroundColor(textColor)
            Text(compass.connected ? "Connected" : compass.status)
                .font(.footnote)
                .foregroundColor(textColor)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 0x0b / 255, green: 0x0b / 255, blue: 0x0d / 255).ignoresSafeArea())
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
    }
}

@main
struct CompassBLEApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
