// Points North over BLE: github.com/davidchatting/pointsnorth for iPhone and iPad, sharing
// compass bearings between nearby devices over Bluetooth instead of through a server.
// Every device round the table shows a ring with each device (its own at the bottom) drawn as
// an outline of its screen at its real-world position, found by comparing compass bearings.
// Tap a device to flash its screen; swipe left or right to flash the device next to you.
//
// Each app is both a BLE peripheral and a central. It advertises its bearing with the micro:bit's
// Magnetometer Service (so the micro:bit compass page can add it too) plus a Points North
// Service holding its screen size and a message inbox, and it connects to every device it finds
// advertising the Magnetometer Service that also has the Points North Service. Being nearby
// takes the place of the web version's session and QR code.
//
// The AtomS3R version (atoms3r-pointsnorth/) can't use a link that another device opened to read
// from it, as iOS does, so when this app connects to an Atom it writes its own details to the
// Atom's Report characteristic, and listens on its Outbox for messages from the Atom.
//
// Setup as for CompassBLE.swift: an iOS App (SwiftUI) project with this as its only Swift file,
// and "Privacy - Bluetooth Always Usage Description" in the target's Info tab.
// iOS only advertises while the app is open on screen, so it keeps the screen awake.

import Combine
import CoreBluetooth
import CoreLocation
import SwiftUI

// Magnetometer Service: Bearing (uint16 LE, degrees, read/notify).
let magnetometerService = CBUUID(string: "E95DF2D8-251D-470A-A062-FA1922DFA9A8")
let bearingCharacteristic = CBUUID(string: "E95D9715-251D-470A-A062-FA1922DFA9A8")
// Points North Service: Info (read/notify: 8-byte client ID, then uint16 LE screen width and
// height in points) and Message (write: the sender's 8-byte client ID, then UTF-8 text).
let pointsNorthService = CBUUID(string: "00E43092-366D-46DA-8323-42BF39B7078E")
let infoCharacteristic = CBUUID(string: "ECC93172-718C-4A86-8459-9CB1D893E71A")
let messageCharacteristic = CBUUID(string: "02BA1FE3-F825-486B-9B9B-417D31D6DEBC")
// Only on Atoms: Report (write: our client ID, uint16 LE width, height and bearing) and Outbox
// (notify: the target's 8-byte client ID, the sender's, then UTF-8 text).
let reportCharacteristic = CBUUID(string: "80D91D31-5AEF-4697-B843-1C28EA1CB4ED")
let outboxCharacteristic = CBUUID(string: "68CAAC8D-DF0B-4D7D-9AC5-7201064754FE")
// The compass page's device picker filters on the "BBC micro:bit" prefix.
let advertisedName = UIDevice.current.userInterfaceIdiom == .pad ? "BBC micro:bit [ipad]" : "BBC micro:bit [iphone]"

// A device round the table, this one included.
struct Device {
    let id: String // client ID
    let bearing: Int
    let width: Double
    let height: Double
    let isSelf: Bool
}

final class PointsNorth: NSObject, ObservableObject, CBPeripheralManagerDelegate, CBCentralManagerDelegate,
    CBPeripheralDelegate, CLLocationManagerDelegate {
    @Published var bearing: Int?
    @Published var flash = false
    @Published var status = "Starting Bluetooth…"
    @Published private var peers: [UUID: Peer] = [:]

    let clientId = String((0..<8).map { _ in "abcdefghijklmnopqrstuvwxyz0123456789".randomElement()! })
    private var size = CGSize(width: 100, height: 100)

    // A device found nearby, and what it has told us so far.
    private struct Peer {
        let peripheral: CBPeripheral
        var clientId: String?
        var width = 100.0, height = 100.0
        var bearing: Int?
        var message: CBCharacteristic?
        var report: CBCharacteristic?
        var ignored = false // no Points North Service, e.g. the CompassBLE app
    }

    private var peripheral: CBPeripheralManager!
    private var central: CBCentralManager!
    private let location = CLLocationManager()
    private var bearingChar: CBMutableCharacteristic?
    private var infoChar: CBMutableCharacteristic?
    private var pending: [(CBMutableCharacteristic, Data)] = [] // notifications waiting for room

    override init() {
        super.init()
        peripheral = CBPeripheralManager(delegate: self, queue: nil)
        central = CBCentralManager(delegate: self, queue: nil)
        location.delegate = self
        location.startUpdatingHeading()
    }

    // Every device with a known bearing, this one included, in bearing order.
    var devices: [Device] {
        var list = peers.values.compactMap { peer -> Device? in
            guard let id = peer.clientId, let bearing = peer.bearing else { return nil }
            return Device(id: id, bearing: bearing, width: peer.width, height: peer.height, isSelf: false)
        }
        if let bearing {
            list.append(Device(id: clientId, bearing: bearing, width: size.width, height: size.height, isSelf: true))
        }
        return list.sorted { $0.bearing < $1.bearing }
    }

    // MARK: Messages

    func send(_ text: String, to id: String) {
        guard id != clientId, let peer = peers.values.first(where: { $0.clientId == id }), let message = peer.message else { return }
        peer.peripheral.writeValue(Data(clientId.utf8) + Data(text.utf8), for: message, type: .withResponse)
    }

    // Message the device `offset` places round the circle (in bearing order) from this one.
    func sendToNeighbour(_ text: String, offset: Int) {
        let ordered = devices
        guard ordered.count > 1, let i = ordered.firstIndex(where: { $0.isSelf }) else { return }
        send(text, to: ordered[((i + offset) % ordered.count + ordered.count) % ordered.count].id)
    }

    private func showMessage() {
        flash = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) { self.flash = false }
    }

    // MARK: This device

    // Measure the heading from the top of the screen as it's currently shown. (A device rotated
    // to the right shows its interface rotated to the left, hence the swapped landscape cases.)
    func setSize(_ newSize: CGSize) {
        let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
        switch scene?.interfaceOrientation {
        case .portraitUpsideDown: location.headingOrientation = .portraitUpsideDown
        case .landscapeLeft: location.headingOrientation = .landscapeRight
        case .landscapeRight: location.headingOrientation = .landscapeLeft
        default: location.headingOrientation = .portrait
        }
        size = newSize
        objectWillChange.send()
        if let infoChar { notify(infoData(), infoChar) }
        sendReports()
    }

    private func infoData() -> Data {
        Data(clientId.utf8) + uint16(Int(size.width)) + uint16(Int(size.height))
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading heading: CLHeading) {
        guard heading.headingAccuracy >= 0 else { return }
        let value = Int(heading.magneticHeading.rounded()) % 360
        guard value != bearing else { return }
        bearing = value
        if let bearingChar { notify(uint16(value), bearingChar) }
        sendReports()
    }

    func locationManagerShouldDisplayHeadingCalibration(_ manager: CLLocationManager) -> Bool { true }

    // MARK: Peripheral: sharing this device

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        switch peripheral.state {
        case .poweredOn: status = "Starting to advertise…"
        case .poweredOff: status = "Bluetooth is off"
        case .unauthorized: status = "Bluetooth not allowed: see Settings → Privacy → Bluetooth"
        case .unsupported: status = "No Bluetooth LE on this device"
        default: status = "Bluetooth unavailable"
        }
        guard peripheral.state == .poweredOn else { return }
        let bearing = CBMutableCharacteristic(type: bearingCharacteristic, properties: [.read, .notify], value: nil, permissions: .readable)
        let magnetometer = CBMutableService(type: magnetometerService, primary: true)
        magnetometer.characteristics = [bearing]

        let info = CBMutableCharacteristic(type: infoCharacteristic, properties: [.read, .notify], value: nil, permissions: .readable)
        let message = CBMutableCharacteristic(type: messageCharacteristic, properties: [.write], value: nil, permissions: .writeable)
        let pointsNorth = CBMutableService(type: pointsNorthService, primary: true)
        pointsNorth.characteristics = [info, message]

        bearingChar = bearing
        infoChar = info
        peripheral.removeAllServices()
        peripheral.add(magnetometer)
        peripheral.add(pointsNorth)
        // Only the Magnetometer Service is advertised: there's no room for a second 128-bit UUID.
        peripheral.startAdvertising([CBAdvertisementDataLocalNameKey: advertisedName,
                                     CBAdvertisementDataServiceUUIDsKey: [magnetometerService]])
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        status = error.map { "Couldn't advertise: \($0.localizedDescription)" } ?? "Looking for devices nearby…"
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        let data: Data
        switch request.characteristic.uuid {
        case bearingCharacteristic: data = uint16(bearing ?? 0)
        case infoCharacteristic: data = infoData()
        default:
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

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        if requests.contains(where: { $0.characteristic.uuid == messageCharacteristic }) { showMessage() }
        if let first = requests.first { peripheral.respond(to: first, withResult: .success) }
    }

    // iOS drops a notification when its send queue is full, so queue the latest value for each
    // characteristic and send it when there's room.
    private func notify(_ data: Data, _ characteristic: CBMutableCharacteristic) {
        pending.removeAll { $0.0 === characteristic }
        pending.append((characteristic, data))
        sendPending()
    }

    private func sendPending() {
        while let (characteristic, data) = pending.first {
            guard peripheral.updateValue(data, for: characteristic, onSubscribedCentrals: nil) else { return }
            pending.removeFirst()
        }
    }

    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) { sendPending() }

    // MARK: Central: finding the other devices

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else { return }
        // Duplicates, so a device that disconnected is found again when it comes back.
        central.scanForPeripherals(withServices: [magnetometerService], options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard peers[peripheral.identifier] == nil else { return }
        peers[peripheral.identifier] = Peer(peripheral: peripheral)
        peripheral.delegate = self
        central.connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([magnetometerService, pointsNorthService])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        peers[peripheral.identifier] = nil
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        if peers[peripheral.identifier]?.ignored != true { peers[peripheral.identifier] = nil }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        let services = peripheral.services ?? []
        guard services.contains(where: { $0.uuid == pointsNorthService }) else {
            // Not playing (e.g. the CompassBLE app): remember it so it isn't connected to again.
            peers[peripheral.identifier]?.ignored = true
            central.cancelPeripheralConnection(peripheral)
            return
        }
        for service in services { peripheral.discoverCharacteristics(nil, for: service) }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for characteristic in service.characteristics ?? [] {
            switch characteristic.uuid {
            case bearingCharacteristic, infoCharacteristic:
                peripheral.readValue(for: characteristic)
                peripheral.setNotifyValue(true, for: characteristic)
            case messageCharacteristic:
                peers[peripheral.identifier]?.message = characteristic
            case reportCharacteristic:
                peers[peripheral.identifier]?.report = characteristic
                sendReports()
            case outboxCharacteristic:
                peripheral.setNotifyValue(true, for: characteristic)
            default: break
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value else { return }
        let id = peripheral.identifier
        if characteristic.uuid == bearingCharacteristic, data.count >= 2 {
            peers[id]?.bearing = uint16(data, at: 0)
        } else if characteristic.uuid == infoCharacteristic, data.count >= 12 {
            peers[id]?.clientId = String(decoding: data.prefix(8), as: UTF8.self)
            peers[id]?.width = Double(uint16(data, at: 8))
            peers[id]?.height = Double(uint16(data, at: 10))
        } else if characteristic.uuid == outboxCharacteristic, data.count >= 16,
                  String(decoding: data.prefix(8), as: UTF8.self) == clientId {
            showMessage()
        }
    }

    // Tell each Atom this device's details (iOS devices read them instead).
    private func sendReports() {
        let report = infoData() + uint16(bearing ?? 0)
        for peer in peers.values {
            if let characteristic = peer.report {
                peer.peripheral.writeValue(report, for: characteristic, type: .withoutResponse)
            }
        }
    }

    private func uint16(_ value: Int) -> Data { Data([UInt8(value & 0xff), UInt8((value >> 8) & 0xff)]) }
    private func uint16(_ data: Data, at offset: Int) -> Int {
        Int(data[data.startIndex + offset]) | Int(data[data.startIndex + offset + 1]) << 8
    }
}

// MARK: Views

// The compass ring's geometry, shared by drawing and hit-testing. Angles are in degrees,
// clockwise from the top of the screen.
struct Ring {
    let center: CGPoint
    let inner: CGFloat
    let outer: CGFloat

    init(_ size: CGSize) {
        center = CGPoint(x: size.width / 2, y: size.height / 2)
        inner = min(size.width, size.height) * 0.3 / sqrt(2)
        outer = inner * 2
    }

    // A device's position round the ring, seen from a device with this bearing: devices sit on
    // the opposite side of the table from the direction they point.
    func angle(of device: Device, from bearing: Int) -> Double { Double(device.bearing - bearing + 180) }

    // The outline of a device's screen in its own rotated frame: on the upward axis, between
    // the ring's inner circle and its edge, scaled to fit.
    func outline(of device: Device) -> (rect: CGRect, cornerRadius: CGFloat) {
        let margin = outer - inner
        let scale = min(0.15, margin * 0.9 / max(device.width, device.height))
        let w = device.width * scale, h = device.height * scale
        let radialCenter = inner + margin * 0.25 + h / 2
        return (CGRect(x: -w / 2, y: -radialCenter - h / 2, width: w, height: h), 80 * scale)
    }
}

struct ContentView: View {
    @StateObject private var model = PointsNorth()
    @State private var touchStart: Date?

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Canvas { context, size in draw(&context, size) }
                    .contentShape(Rectangle())
                    .gesture(touches(geometry.size))
                VStack {
                    Spacer()
                    Text(model.status)
                        .font(.footnote)
                        .foregroundColor(.gray)
                        .padding()
                }
                .allowsHitTesting(false)
                Color.white
                    .opacity(model.flash ? 1 : 0)
                    .animation(.easeOut(duration: 0.22), value: model.flash)
                    .allowsHitTesting(false)
            }
            .onAppear { model.setSize(geometry.size) }
            .onChange(of: geometry.size) { model.setSize(geometry.size) }
        }
        .ignoresSafeArea()
        .background(Color.black)
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
    }

    private func draw(_ context: inout GraphicsContext, _ size: CGSize) {
        let ring = Ring(size)
        context.translateBy(x: ring.center.x, y: ring.center.y)
        let edge = CGRect(x: -ring.outer, y: -ring.outer, width: ring.outer * 2, height: ring.outer * 2)
        context.stroke(Path(ellipseIn: edge), with: .color(.white), lineWidth: 2)
        guard let bearing = model.bearing else { return }

        // Dotted north line between the inner circle and the edge.
        var north = context
        north.rotate(by: .degrees(Double(-bearing)))
        var line = Path()
        line.move(to: CGPoint(x: 0, y: -ring.inner))
        line.addLine(to: CGPoint(x: 0, y: -ring.outer))
        north.stroke(line, with: .color(.white), style: StrokeStyle(lineWidth: 2, dash: [3, 6]))

        for device in model.devices {
            var frame = context
            frame.rotate(by: .degrees(ring.angle(of: device, from: bearing)))
            let outline = ring.outline(of: device)
            let path = Path(roundedRect: outline.rect, cornerRadius: outline.cornerRadius)
            frame.fill(path, with: .color(.black))
            frame.stroke(path, with: .color(.white), lineWidth: 2)
        }
    }

    // The other device whose outline is under a point, if any.
    private func device(at point: CGPoint, _ size: CGSize) -> Device? {
        guard let bearing = model.bearing else { return nil }
        let ring = Ring(size)
        let x = point.x - ring.center.x, y = point.y - ring.center.y
        return model.devices.first { device in
            guard !device.isSelf else { return false }
            // Undo the device's rotation to get the point in its frame.
            let t = ring.angle(of: device, from: bearing) * .pi / 180
            let p = CGPoint(x: x * cos(t) + y * sin(t), y: -x * sin(t) + y * cos(t))
            return ring.outline(of: device).rect.contains(p)
        }
    }

    // Tap a device to message it; swipe to message the device next to you. As in the web
    // version, swiping right messages the device to your left and vice versa.
    private func touches(_ size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if touchStart == nil || value.translation == .zero { touchStart = value.time }
            }
            .onEnded { value in
                let quick = value.time.timeIntervalSince(touchStart ?? value.time) <= 0.5
                touchStart = nil
                let dx = value.translation.width, dy = value.translation.height
                if quick && abs(dy) <= 80 && abs(dx) >= 50 {
                    model.sendToNeighbour("Swiped!", offset: dx > 0 ? -1 : 1)
                } else if quick && hypot(dx, dy) <= 12, let target = device(at: value.location, size) {
                    model.send("Tapped!", to: target.id)
                }
            }
    }
}

@main
struct PointsNorthApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
