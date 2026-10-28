// Points North for iPhone and iPad: github.com/davidchatting/pointsnorth-old as a native app, joining
// the same sessions as the web app (web/) through the same WebSocket relay.
// Every device round the table shows a ring with each device (its own at the bottom) drawn as
// an outline of its screen at its real-world position, found by comparing compass bearings.
// Tap a device to flash its screen; swipe left or right to flash the device next to you.
//
// SPOKE | HUB at the top picks this device's role. Every device starts as a spoke: it makes a
// session of its own (its QR code is in the middle of the ring), or joins one with JOIN, which
// scans another device's QR code. A hub is a spoke that also bridges micro:bits, which can't
// reach the server themselves: it connects to each one over Bluetooth and gives it its own
// WebSocket, so the rest of the session sees it as a device like any other. Tapping a micro:bit
// lights its screen, and its A and B buttons message its left and right neighbours. Hubs say so
// in their messages ("role": "hub") and are drawn in the middle of the ring, not round it.
//
// Whether a hub or a spoke, the app advertises its session over Bluetooth, for devices without a
// camera (the AtomS3R, atoms3r/) to join: the name "PN <session ID>" and the Points
// North Service, whose Session characteristic holds the session ID as UTF-8.
//
// Setup: an iOS App (SwiftUI) project with this as its only Swift file, and in the target's Info
// tab "Privacy - Bluetooth Always Usage Description" and "Privacy - Camera Usage Description".
// Under SPOKE | HUB, SERVER: shows whether it can reach the relay.
// iOS only advertises while the app is open on screen, so it keeps the screen awake.

import AVFoundation
import Combine
import CoreBluetooth
import CoreImage.CIFilterBuiltins
import CoreLocation
import SwiftUI

let webApp = "https://davidchatting-bot.github.io/pointsnorth/"
let defaultServer = "wss://api.davidchatting.com/pubgames"

// Points North Service: Session (read: the session ID, UTF-8).
let pointsNorthService = CBUUID(string: "00E43092-366D-46DA-8323-42BF39B7078E")
let sessionCharacteristic = CBUUID(string: "7513CE11-F0CA-49FC-A8BF-E9D4F8021FA3")
// The micro:bit services (see main.ts).
let magnetometerService = CBUUID(string: "E95DF2D8-251D-470A-A062-FA1922DFA9A8")
let bearingCharacteristic = CBUUID(string: "E95D9715-251D-470A-A062-FA1922DFA9A8")
let buttonService = CBUUID(string: "E95D9882-251D-470A-A062-FA1922DFA9A8")
let buttonACharacteristic = CBUUID(string: "E95DDA90-251D-470A-A062-FA1922DFA9A8")
let buttonBCharacteristic = CBUUID(string: "E95DDA91-251D-470A-A062-FA1922DFA9A8")
let ledService = CBUUID(string: "E95DD91D-251D-470A-A062-FA1922DFA9A8")
let ledMatrixCharacteristic = CBUUID(string: "E95D7B77-251D-470A-A062-FA1922DFA9A8")
// A micro:bit's 52 × 42 mm board at roughly the scale of a phone's screen in points.
let microbitSize = CGSize(width: 290, height: 235)
// LED Matrix State rows (bit 4 = leftmost): all on for a flash, and the tick a bridged micro:bit
// shows. The micro:bit leaves its screen to the hub once connected.
let ledsOn = Data([31, 31, 31, 31, 31])
let ledsTick = Data([0, 1, 2, 20, 8])

enum Role: String { case spoke, hub }

// This device's link to the relay: connecting at first, then online or offline (while it
// keeps retrying).
enum Connection: String { case connecting, online, offline }

// A device in the session, this one included.
struct Device {
    let id: String // client ID
    var bearing: Double?
    var width = 100.0, height = 100.0
    var role = Role.spoke
    var isSelf = false
}

func randomId() -> String { String((0..<8).map { _ in "abcdefghijklmnopqrstuvwxyz0123456789".randomElement()! }) }

// One WebSocket to the relay, for one client ID: this device, or a micro:bit it bridges. Every
// message carries the client and session IDs, and the relay delivers it to its targetClientId,
// or to the rest of the session. Reconnects until closed.
final class Relay: NSObject, URLSessionWebSocketDelegate {
    let clientId: String
    var server: String
    var sessionId: String
    var info: () -> [String: Any] = { [:] } // client_info fields: width, height, bearing, role
    var onMessage: ([String: Any]) -> Void = { _ in }
    var onState: (Bool) -> Void = { _ in }
    private var task: URLSessionWebSocketTask?
    private var closed = false
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)

    init(clientId: String, server: String, sessionId: String) {
        self.clientId = clientId
        self.server = server
        self.sessionId = sessionId
    }

    func open() {
        guard !closed, task == nil, let url = URL(string: server) else { return }
        let task = session.webSocketTask(with: url)
        self.task = task
        task.resume()
        send(info().merging(["type": "client_info"]) { $1 })
        receive(task)
    }

    // Rejoin, e.g. after the session changes: the relay tells the old session we've gone.
    func reopen() {
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        open()
    }

    func close() {
        closed = true
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        session.finishTasksAndInvalidate()
    }

    func send(_ message: [String: Any]) {
        var message = message
        message["clientId"] = clientId
        message["sessionId"] = sessionId
        guard let task, let data = try? JSONSerialization.data(withJSONObject: message) else { return }
        task.send(.string(String(decoding: data, as: UTF8.self))) { _ in }
    }

    // Answer a newcomer's client_info with ours, as the web app does.
    func replyToClientInfo(_ message: [String: Any]) {
        guard message["targetClientId"] == nil || message["targetClientId"] is NSNull,
              let from = message["clientId"] as? String, from != clientId else { return }
        send(info().merging(["type": "client_info", "targetClientId": from]) { $1 })
    }

    private func receive(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            DispatchQueue.main.async {
                guard let self, task === self.task else { return }
                switch result {
                case .success(let message):
                    var data: Data?
                    switch message {
                    case .string(let text): data = Data(text.utf8)
                    case .data(let bytes): data = bytes
                    @unknown default: break
                    }
                    let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) }
                    for item in (json as? [[String: Any]]) ?? [json as? [String: Any]].compactMap({ $0 }) {
                        self.onMessage(item)
                    }
                    self.receive(task)
                case .failure:
                    self.onState(false)
                    self.task = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.open() }
                }
            }
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        if webSocketTask === task { onState(true) }
    }
}

// A micro:bit bridged by this device in hub mode.
final class Bridge {
    let peripheral: CBPeripheral
    let relay: Relay
    var bearing: Int? // as passed on to the session
    var leds: CBCharacteristic?
    // The readings smoothed as a direction (so 359 to 0 doesn't swing round), settling in
    // about a second, as on the Atom.
    private var x = 0.0, y = 0.0
    private var lastReading: Date?
    private(set) var smoothed: Int?

    init(peripheral: CBPeripheral, relay: Relay) {
        self.peripheral = peripheral
        self.relay = relay
    }

    func add(_ reading: Int) {
        let now = Date()
        let angle = Double(reading) * .pi / 180
        // Weighted by the time since the last reading, so it settles at the same rate however
        // often the micro:bit sends them.
        let weight = lastReading.map { 1 - exp(-now.timeIntervalSince($0) / 0.3) } ?? 1
        lastReading = now
        x += weight * (sin(angle) - x)
        y += weight * (cos(angle) - y)
        smoothed = (Int((atan2(x, y) * 180 / .pi).rounded()) + 360) % 360
    }

    // Pass the smoothed bearing on when it has moved by 2 degrees or more, so it doesn't flicker
    // between two values.
    func update() -> Bool {
        guard let smoothed else { return false }
        if let bearing, abs((smoothed - bearing + 540) % 360 - 180) < 2 { return false }
        bearing = smoothed
        return true
    }
}

final class PointsNorth: NSObject, ObservableObject, CBPeripheralManagerDelegate, CBCentralManagerDelegate,
    CBPeripheralDelegate, CLLocationManagerDelegate {
    @Published var role = Role.spoke
    @Published var bearing: Int?
    @Published var flash = false
    @Published private(set) var sessionId = randomId()
    @Published private(set) var connection = Connection.connecting
    @Published private var peers: [String: Device] = [:]
    @Published private var bridges: [UUID: Bridge] = [:]
    @Published private var bluetooth = "Starting Bluetooth…"

    let clientId = randomId()
    private(set) var server = defaultServer
    private var size = CGSize(width: 100, height: 100)
    private var relay: Relay!
    private var peripheral: CBPeripheralManager!
    private var central: CBCentralManager!
    private let location = CLLocationManager()
    private var bridgeTimer: Timer?
    private var qr: (text: String, image: CGImage)?

    override init() {
        super.init()
        relay = Relay(clientId: clientId, server: server, sessionId: sessionId)
        relay.info = { [unowned self] in
            ["width": Double(self.size.width), "height": Double(self.size.height),
             "bearing": self.bearing.map { Double($0) as Any } ?? NSNull(), "role": self.role.rawValue]
        }
        relay.onMessage = { [unowned self] in self.receive($0) }
        relay.onState = { [unowned self] in self.connection = $0 ? .online : .offline }
        relay.open()
        peripheral = CBPeripheralManager(delegate: self, queue: nil)
        central = CBCentralManager(delegate: self, queue: nil)
        location.delegate = self
        location.headingFilter = 1
        location.startUpdatingHeading()
    }

    var joinURL: String {
        var url = webApp + "?session=" + sessionId
        if server != defaultServer { url += "&server=" + (server.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? server) }
        return url
    }

    // The join link as a QR code, as the web app draws it: grey (#999) on transparent, the lowest
    // error correction, a one-module margin, one pixel per module.
    var qrCode: CGImage? {
        let text = joinURL
        if let qr, qr.text == text { return qr.image }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "L"
        let colours = CIFilter.falseColor()
        colours.inputImage = filter.outputImage
        colours.color0 = CIColor(red: 0.6, green: 0.6, blue: 0.6) // dark modules
        colours.color1 = CIColor.clear                           // light ones
        guard let output = colours.outputImage,
              let image = CIContext().createCGImage(output, from: output.extent) else { return nil }
        qr = (text, image)
        return image
    }

    var status: String {
        var parts = ["Session \(sessionId)"]
        if role == .hub { parts.append(bridges.count == 1 ? "1 micro:bit" : "\(bridges.count) micro:bits") }
        if !bluetooth.isEmpty { parts.append(bluetooth) }
        return parts.joined(separator: " · ")
    }

    // Every device with a known bearing, this one included.
    var devices: [Device] {
        var list = peers.values.filter { $0.bearing != nil }
        if let bearing {
            list.append(Device(id: clientId, bearing: Double(bearing), width: size.width, height: size.height, role: role, isSelf: true))
        }
        return list
    }

    // MARK: The session

    // Join the session in a scanned QR code: a Points North link with ?session= (and ?server=).
    func join(_ link: String) -> Bool {
        guard let query = URLComponents(string: link)?.queryItems,
              let session = query.first(where: { $0.name == "session" })?.value, !session.isEmpty else { return false }
        sessionId = session
        connection = .connecting
        server = query.first(where: { $0.name == "server" })?.value ?? defaultServer
        peers = [:]
        for relay in [relay!] + bridges.values.map(\.relay) {
            relay.sessionId = sessionId
            relay.server = server
            relay.reopen()
        }
        advertise()
        return true
    }

    func setRole(_ newRole: Role) {
        guard newRole != role else { return }
        role = newRole
        relay.send(relay.info().merging(["type": "client_info"]) { $1 }) // tell everyone
        if role == .hub {
            startScanning()
            bridgeTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [unowned self] _ in self.sendBridgeBearings() }
        } else {
            central.stopScan()
            bridgeTimer?.invalidate()
            for bridge in bridges.values { central.cancelPeripheralConnection(bridge.peripheral) }
        }
    }

    private func receive(_ message: [String: Any]) {
        guard let type = message["type"] as? String, let id = message["clientId"] as? String, id != clientId else { return }
        switch type {
        case "client_info", "compass":
            var device = peers[id] ?? Device(id: id)
            if let bearing = message["bearing"] as? NSNumber { device.bearing = bearing.doubleValue }
            if let width = message["width"] as? NSNumber { device.width = width.doubleValue }
            if let height = message["height"] as? NSNumber { device.height = height.doubleValue }
            if let role = (message["role"] as? String).flatMap(Role.init) { device.role = role }
            peers[id] = device
            if type == "client_info" { relay.replyToClientInfo(message) }
        case "message":
            showMessage()
        case "disconnect":
            peers[id] = nil
        default: break
        }
    }

    // MARK: Messages

    func send(_ text: String, to id: String, from relay: Relay? = nil) {
        (relay ?? self.relay).send(["type": "message", "text": text, "targetClientId": id])
    }

    // The device `offset` places round the circle (in bearing order) from the one with this ID:
    // devices sit opposite where they point, so -1 is on its right and +1 on its left. Hubs sit
    // in the middle, so they have no neighbours.
    func neighbour(of id: String, offset: Int) -> String? {
        let ordered = devices.filter { $0.role != .hub }.sorted { $0.bearing! < $1.bearing! }
        guard ordered.count > 1, let i = ordered.firstIndex(where: { $0.id == id }) else { return nil }
        return ordered[((i + offset) % ordered.count + ordered.count) % ordered.count].id
    }

    func sendToNeighbour(_ text: String, offset: Int) {
        if let id = neighbour(of: clientId, offset: offset) { send(text, to: id) }
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
        sendCompass()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading heading: CLHeading) {
        guard heading.headingAccuracy >= 0 else { return }
        let value = Int(heading.magneticHeading.rounded()) % 360
        guard value != bearing else { return }
        bearing = value
        sendCompass()
    }

    func locationManagerShouldDisplayHeadingCalibration(_ manager: CLLocationManager) -> Bool { true }

    private func sendCompass() {
        guard let bearing else { return }
        relay.send(["type": "compass", "bearing": Double(bearing), "width": Double(size.width), "height": Double(size.height),
                    "role": role.rawValue])
    }

    // MARK: Peripheral: advertising the session

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        switch peripheral.state {
        case .poweredOn: bluetooth = ""
        case .poweredOff: bluetooth = "Bluetooth is off"
        case .unauthorized: bluetooth = "Bluetooth not allowed: see Settings → Privacy → Bluetooth"
        case .unsupported: bluetooth = "No Bluetooth LE on this device"
        default: bluetooth = "Bluetooth unavailable"
        }
        guard peripheral.state == .poweredOn else { return }
        let session = CBMutableCharacteristic(type: sessionCharacteristic, properties: [.read], value: nil, permissions: .readable)
        let service = CBMutableService(type: pointsNorthService, primary: true)
        service.characteristics = [session]
        peripheral.removeAllServices()
        peripheral.add(service)
        advertise()
    }

    private func advertise() {
        guard peripheral?.state == .poweredOn else { return }
        peripheral.stopAdvertising()
        peripheral.startAdvertising([CBAdvertisementDataLocalNameKey: "PN \(sessionId)",
                                     CBAdvertisementDataServiceUUIDsKey: [pointsNorthService]])
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        if let error { bluetooth = "Couldn't advertise: \(error.localizedDescription)" }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        let data = Data(sessionId.utf8)
        guard request.characteristic.uuid == sessionCharacteristic else {
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

    // MARK: Central: bridging micro:bits (hub mode)

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if role == .hub { startScanning() }
    }

    private func startScanning() {
        guard central.state == .poweredOn else { return }
        // micro:bits don't advertise their services, only their name. Duplicates, so a micro:bit
        // that disconnected is found again when it comes back.
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name ?? ""
        guard role == .hub, name.hasPrefix("BBC micro:bit"), bridges[peripheral.identifier] == nil else { return }
        // A client ID that stays the same each time this micro:bit is bridged.
        let id = "mb-" + peripheral.identifier.uuidString.prefix(8).lowercased()
        let bridge = Bridge(peripheral: peripheral, relay: Relay(clientId: id, server: server, sessionId: sessionId))
        bridge.relay.info = { [unowned bridge] in
            ["width": Double(microbitSize.width), "height": Double(microbitSize.height),
             "bearing": bridge.bearing.map { Double($0) as Any } ?? NSNull(), "role": Role.spoke.rawValue]
        }
        bridge.relay.onMessage = { [unowned self, unowned bridge] message in
            switch message["type"] as? String {
            case "client_info": bridge.relay.replyToClientInfo(message)
            case "message": self.flashLEDs(bridge)
            default: break
            }
        }
        bridges[peripheral.identifier] = bridge
        peripheral.delegate = self
        central.connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        bridges[peripheral.identifier]?.relay.open()
        peripheral.discoverServices([magnetometerService, buttonService, ledService])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        dropBridge(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        dropBridge(peripheral)
    }

    // The relay tells the session the micro:bit has gone when its WebSocket closes.
    private func dropBridge(_ peripheral: CBPeripheral) {
        bridges[peripheral.identifier]?.relay.close()
        bridges[peripheral.identifier] = nil
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        for service in peripheral.services ?? [] { peripheral.discoverCharacteristics(nil, for: service) }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for characteristic in service.characteristics ?? [] {
            switch characteristic.uuid {
            case bearingCharacteristic, buttonACharacteristic, buttonBCharacteristic:
                if characteristic.uuid == bearingCharacteristic { peripheral.readValue(for: characteristic) }
                peripheral.setNotifyValue(true, for: characteristic)
            case ledMatrixCharacteristic:
                bridges[peripheral.identifier]?.leds = characteristic
                peripheral.writeValue(ledsTick, for: characteristic, type: .withResponse)
            default: break
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let bridge = bridges[peripheral.identifier], let data = characteristic.value, !data.isEmpty else { return }
        let first = data[data.startIndex]
        switch characteristic.uuid {
        case bearingCharacteristic where data.count >= 2:
            bridge.add(Int(first) | Int(data[data.startIndex + 1]) << 8)
        // A (on the left) messages the micro:bit's left neighbour, B its right, when pressed: the
        // same messages as swiping on a screen.
        case buttonACharacteristic where first == 1:
            if let id = neighbour(of: bridge.relay.clientId, offset: 1) { send("Swiped!", to: id, from: bridge.relay) }
        case buttonBCharacteristic where first == 1:
            if let id = neighbour(of: bridge.relay.clientId, offset: -1) { send("Swiped!", to: id, from: bridge.relay) }
        default: break
        }
    }

    // micro:bits notify their bearing every 20 ms, so pass changes on at most five times a second.
    private func sendBridgeBearings() {
        for bridge in bridges.values where bridge.update() {
            bridge.relay.send(bridge.relay.info().merging(["type": "compass"]) { $1 })
        }
    }

    private func flashLEDs(_ bridge: Bridge) {
        guard let leds = bridge.leds else { return }
        bridge.peripheral.writeValue(ledsOn, for: leds, type: .withResponse)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            bridge.peripheral.writeValue(ledsTick, for: leds, type: .withResponse)
        }
    }
}

// MARK: Views

// The ring's geometry, as in the web app, shared by drawing and hit-testing. Angles are in
// degrees, clockwise from the top of the screen.
struct Ring {
    let center: CGPoint
    let qrSize: CGFloat
    let inner: CGFloat
    let outer: CGFloat
    let bearing: Double // this device's

    init(_ size: CGSize, bearing: Double) {
        center = CGPoint(x: size.width / 2, y: size.height / 2)
        qrSize = min(size.width, size.height) * 0.3
        inner = qrSize / CGFloat(2).squareRoot()
        outer = inner * 2
        self.bearing = bearing
    }

    // Devices round the ring sit on the opposite side of the table from the direction they
    // point; hubs in the middle just point.
    func angle(of device: Device) -> Double {
        device.bearing! - bearing + (device.role == .hub ? 0 : 180)
    }

    // The outline of a device's screen in its own rotated frame. Round the ring: on the upward
    // axis, between the inner circle and the edge. A hub: in the middle, inside the inner circle.
    func outline(of device: Device) -> (rect: CGRect, cornerRadius: CGFloat) {
        let width = CGFloat(device.width), height = CGFloat(device.height)
        if device.role == .hub {
            let scale: CGFloat = inner * 2 * 0.95 / hypot(width, height)
            let w = width * scale, h = height * scale
            return (CGRect(x: -w / 2, y: -h / 2, width: w, height: h), 80 * scale)
        }
        let margin: CGFloat = outer - inner
        let scale: CGFloat = min(0.15, margin * 0.9 / max(width, height))
        let w = width * scale, h = height * scale
        let radialCenter: CGFloat = inner + margin * 0.25 + h / 2
        return (CGRect(x: -w / 2, y: -radialCenter - h / 2, width: w, height: h), 80 * scale)
    }
}

struct ContentView: View {
    @StateObject private var model = PointsNorth()
    @State private var touchStart: Date?
    @State private var scanning = false

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Canvas { context, size in draw(&context, size) }
                    .contentShape(Rectangle())
                    .gesture(touches(geometry.size))
                VStack {
                    HStack(spacing: 12) {
                        roleButton(.spoke)
                        Text("|").foregroundColor(.gray)
                        roleButton(.hub)
                    }
                    .padding(.top, 60)
                    // SERVER: CONNECTING, ONLINE or OFFLINE, white when online.
                    Text("SERVER: " + model.connection.rawValue.uppercased())
                        .foregroundColor(model.connection == .online ? .white : .gray)
                        .padding(.top, 4)
                    Spacer()
                    Text("JOIN")
                        .foregroundColor(.white)
                        .onTapGesture { scanning = true }
                    Text(model.status)
                        .font(.footnote)
                        .foregroundColor(.gray)
                        .padding(.bottom, 40)
                }
                .font(.system(.title3, design: .monospaced))
                .padding(.horizontal)
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
        .sheet(isPresented: $scanning) {
            ZStack(alignment: .bottom) {
                Scanner { code in if model.join(code) { scanning = false } }
                    .ignoresSafeArea()
                Text("Scan a Points North QR code").foregroundColor(.white).padding(40)
            }
        }
    }

    // SPOKE | HUB: the selected role is white and bold.
    private func roleButton(_ role: Role) -> some View {
        Text(role.rawValue.uppercased())
            .fontWeight(model.role == role ? .bold : .regular)
            .foregroundColor(model.role == role ? .white : .gray)
            .onTapGesture { model.setRole(role) }
    }

    private func draw(_ context: inout GraphicsContext, _ size: CGSize) {
        let ring = Ring(size, bearing: Double(model.bearing ?? 0))
        context.translateBy(x: ring.center.x, y: ring.center.y)
        let edge = CGRect(x: -ring.outer, y: -ring.outer, width: ring.outer * 2, height: ring.outer * 2)
        context.stroke(Path(ellipseIn: edge), with: .color(.white), lineWidth: 2)

        let devices = model.bearing == nil ? [] : model.devices
        if model.bearing != nil {
            // Dotted north line between the inner circle and the edge.
            var north = context
            north.rotate(by: .degrees(-ring.bearing))
            var line = Path()
            line.move(to: CGPoint(x: 0, y: -ring.inner))
            line.addLine(to: CGPoint(x: 0, y: -ring.outer))
            north.stroke(line, with: .color(.white), style: StrokeStyle(lineWidth: 2, dash: [3, 6]))
        }

        for device in devices {
            var frame = context
            frame.rotate(by: .degrees(ring.angle(of: device)))
            let outline = ring.outline(of: device)
            let path = Path(roundedRect: outline.rect, cornerRadius: outline.cornerRadius)
            frame.fill(path, with: .color(.black))
            frame.stroke(path, with: .color(.white), lineWidth: 2)
        }

        // The QR code for joining, on a hub's screen if there is one: upright, and as big as fits
        // inside the hub's outline at its current angle.
        guard let qr = model.qrCode else { return }
        var side = ring.qrSize
        if let hub = devices.first(where: { $0.role == .hub }) {
            let rect = ring.outline(of: hub).rect
            let t = CGFloat(ring.angle(of: hub) * .pi / 180)
            let turn: CGFloat = abs(cos(t)) + abs(sin(t))
            side = min(rect.width, rect.height) * 0.8 / turn
        }
        context.draw(Image(decorative: qr, scale: 1).interpolation(.none),
                     in: CGRect(x: -side / 2, y: -side / 2, width: side, height: side))
    }

    // The other device whose outline is under a point, if any.
    private func device(at point: CGPoint, _ size: CGSize) -> Device? {
        guard let bearing = model.bearing else { return nil }
        let ring = Ring(size, bearing: Double(bearing))
        let x = point.x - ring.center.x, y = point.y - ring.center.y
        return model.devices.first { (device: Device) -> Bool in
            guard !device.isSelf else { return false }
            // Undo the device's rotation to get the point in its frame.
            let t = CGFloat(ring.angle(of: device) * .pi / 180)
            let c: CGFloat = cos(t), s: CGFloat = sin(t)
            let p = CGPoint(x: x * c + y * s, y: y * c - x * s)
            return ring.outline(of: device).rect.contains(p)
        }
    }

    // Tap a device to message it; swipe to message the device next to you on that side.
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

// A camera view that reports each QR code it sees.
struct Scanner: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerController {
        let controller = ScannerController()
        controller.onCode = onCode
        return controller
    }

    func updateUIViewController(_ controller: ScannerController, context: Context) {}
}

final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: (String) -> Void = { _ in }
    private let session = AVCaptureSession()
    private var preview: AVCaptureVideoPreviewLayer?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        guard let camera = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: camera), session.canAddInput(input) else { return }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        view.layer.addSublayer(preview)
        self.preview = preview
        DispatchQueue.global(qos: .userInitiated).async { self.session.startRunning() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        session.stopRunning()
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
        if let code = (objects.first as? AVMetadataMachineReadableCodeObject)?.stringValue { onCode(code) }
    }
}

@main
struct PointsNorthApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
