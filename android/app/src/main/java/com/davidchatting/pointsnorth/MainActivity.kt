// Points North for Android: the iOS app (ios/PointsNorth.swift) ported to Kotlin and Jetpack
// Compose, joining the same sessions as the web app (web/) through the same WebSocket relay.
// Every device round the table shows a ring with each device (its own at the bottom) drawn as
// an outline of its screen at its real-world position, found by comparing compass bearings.
// Tap a device to flash its screen; swipe left or right to flash the device next to you.
//
// SPOKE | HUB at the top picks this device's role, and SERVER: under it shows whether it can
// reach the relay. Every device starts as a spoke: it makes a session of its own (its QR code is
// in the middle of the ring), or joins one with JOIN, which scans another device's QR code. A hub
// is a spoke that also bridges micro:bits, which can't reach the server themselves: it connects
// to each one over Bluetooth and gives it its own WebSocket, so the rest of the session sees it
// as a device like any other. Tapping a micro:bit lights its screen, and its A and B buttons
// message its left and right neighbours. Hubs say so in their messages ("role": "hub") and are
// drawn in the middle of the ring, not round it.
//
// Whether a hub or a spoke, the app offers its session over Bluetooth, for devices without a
// camera (the AtomS3R, atoms3r/) to join: it advertises the Points North Service, whose Session
// characteristic holds the session ID as UTF-8. Android can't choose the name it advertises, so
// unlike iOS it can't advertise "PN <session ID>"; the Atom reads the characteristic instead.
// The session ID is also in the scan response, as the service's data.
//
// Untested.

package com.davidchatting.pointsnorth

import android.Manifest
import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothGattServer
import android.bluetooth.BluetoothGattServerCallback
import android.bluetooth.BluetoothGattService
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.BluetoothStatusCodes
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.graphics.Bitmap
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import android.view.Surface
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.FilterQuality
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.rotate
import androidx.compose.ui.graphics.drawscope.translate
import androidx.compose.ui.graphics.drawscope.withTransform
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.codescanner.GmsBarcodeScannerOptions
import com.google.mlkit.vision.codescanner.GmsBarcodeScanning
import com.google.zxing.BarcodeFormat
import com.google.zxing.EncodeHintType
import com.google.zxing.qrcode.QRCodeWriter
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID
import java.util.concurrent.TimeUnit
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.exp
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.sin
import kotlin.math.sqrt

const val WEB_APP = "https://davidchatting-bot.github.io/pointsnorth/"
const val DEFAULT_SERVER = "wss://api.davidchatting.com/pubgames"

// Points North Service: Session (read: the session ID, UTF-8).
val POINTS_NORTH_SERVICE: UUID = UUID.fromString("00E43092-366D-46DA-8323-42BF39B7078E")
val SESSION_CHARACTERISTIC: UUID = UUID.fromString("7513CE11-F0CA-49FC-A8BF-E9D4F8021FA3")
// The micro:bit services (see main.ts).
val MAGNETOMETER_SERVICE: UUID = UUID.fromString("E95DF2D8-251D-470A-A062-FA1922DFA9A8")
val BEARING_CHARACTERISTIC: UUID = UUID.fromString("E95D9715-251D-470A-A062-FA1922DFA9A8")
val BUTTON_A_CHARACTERISTIC: UUID = UUID.fromString("E95DDA90-251D-470A-A062-FA1922DFA9A8")
val BUTTON_B_CHARACTERISTIC: UUID = UUID.fromString("E95DDA91-251D-470A-A062-FA1922DFA9A8")
val LED_MATRIX_CHARACTERISTIC: UUID = UUID.fromString("E95D7B77-251D-470A-A062-FA1922DFA9A8")
// The descriptor a central writes to turn a characteristic's notifications on.
val CLIENT_CONFIGURATION: UUID = UUID.fromString("00002902-0000-1000-8000-00805F9B34FB")
// A micro:bit's 52 × 42 mm board at roughly the scale of a phone's screen in dp.
const val MICROBIT_WIDTH = 290.0
const val MICROBIT_HEIGHT = 235.0
// LED Matrix State rows (bit 4 = leftmost): all on for a flash, then the tick it shows when connected.
val LEDS_ON = byteArrayOf(31, 31, 31, 31, 31)
val LEDS_TICK = byteArrayOf(0, 1, 2, 20, 8)

enum class Role(val wire: String) { SPOKE("spoke"), HUB("hub") }

// This device's link to the relay: connecting at first, then online or offline (while it
// keeps retrying).
enum class Connection { CONNECTING, ONLINE, OFFLINE }

// A device in the session, this one included.
data class Device(
    val id: String, // client ID
    val bearing: Double? = null,
    val width: Double = 100.0,
    val height: Double = 100.0,
    val role: Role = Role.SPOKE,
    val isSelf: Boolean = false,
)

fun randomId() = (1..8).map { "abcdefghijklmnopqrstuvwxyz0123456789".random() }.joinToString("")

// Everything below runs on the main thread: Bluetooth and WebSocket callbacks are posted here.
val mainThread = Handler(Looper.getMainLooper())

val http: OkHttpClient = OkHttpClient.Builder().pingInterval(20, TimeUnit.SECONDS).build()

// One WebSocket to the relay, for one client ID: this device, or a micro:bit it bridges. Every
// message carries the client and session IDs, and the relay delivers it to its targetClientId,
// or to the rest of the session. Reconnects until closed.
class Relay(val clientId: String, var server: String, var sessionId: String) {
    var info: () -> JSONObject = { JSONObject() } // client_info fields: width, height, bearing, role
    var onMessage: (JSONObject) -> Unit = {}
    var onState: (Boolean) -> Unit = {}
    private var socket: WebSocket? = null
    private var closed = false

    fun open() {
        if (closed || socket != null) return
        val request = try { Request.Builder().url(server).build() } catch (e: IllegalArgumentException) { return }
        socket = http.newWebSocket(request, object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) {
                mainThread.post { if (webSocket === socket) onState(true) }
            }

            override fun onMessage(webSocket: WebSocket, text: String) {
                mainThread.post { if (webSocket === socket) receive(text) }
            }

            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                mainThread.post { if (webSocket === socket) dropped() }
            }

            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                mainThread.post { if (webSocket === socket) dropped() }
            }
        })
        send(info().put("type", "client_info")) // OkHttp queues it until the socket opens
    }

    // Rejoin, e.g. after the session changes: the relay tells the old session we've gone.
    fun reopen() {
        socket?.close(1000, null)
        socket = null
        open()
    }

    fun close() {
        closed = true
        socket?.close(1000, null)
        socket = null
    }

    fun send(message: JSONObject) {
        message.put("clientId", clientId).put("sessionId", sessionId)
        socket?.send(message.toString())
    }

    // Answer a newcomer's client_info with ours, as the web app does.
    fun replyToClientInfo(message: JSONObject) {
        val from = message.optString("clientId")
        if (!message.isNull("targetClientId") || from.isEmpty() || from == clientId) return
        send(info().put("type", "client_info").put("targetClientId", from))
    }

    private fun dropped() {
        onState(false)
        socket = null
        mainThread.postDelayed({ open() }, 3000)
    }

    private fun receive(text: String) {
        val trimmed = text.trimStart()
        try {
            if (trimmed.startsWith("[")) {
                val items = JSONArray(trimmed)
                for (i in 0 until items.length()) items.optJSONObject(i)?.let(onMessage)
            } else {
                onMessage(JSONObject(trimmed))
            }
        } catch (e: org.json.JSONException) {
            // not JSON: ignored, as in the web app
        }
    }
}

// A micro:bit bridged by this device in hub mode.
class Bridge(val device: BluetoothDevice, val relay: Relay) {
    var gatt: BluetoothGatt? = null
    var bearing: Int? = null // as passed on to the session
    var leds: BluetoothGattCharacteristic? = null

    // Android runs one GATT operation at a time, so they wait here for the one before to finish.
    // Each returns whether it started; one that didn't won't get a callback.
    private val operations = ArrayDeque<() -> Boolean>()
    private var busy = false

    fun queue(operation: () -> Boolean) {
        operations.addLast(operation)
        if (!busy) next()
    }

    fun next() {
        while (true) {
            val operation = operations.removeFirstOrNull()
            busy = operation != null
            if (operation == null || operation()) return
        }
    }

    // The readings smoothed as a direction (so 359 to 0 doesn't swing round), settling in about
    // a second, as on the Atom.
    private var x = 0.0
    private var y = 0.0
    private var lastReading: Long? = null
    var smoothed: Int? = null
        private set

    fun add(reading: Int) {
        val now = System.nanoTime()
        val angle = reading * PI / 180
        // Weighted by the time since the last reading, so it settles at the same rate however
        // often the micro:bit sends them.
        val weight = lastReading?.let { 1 - exp(-(now - it) / 1e9 / 0.3) } ?: 1.0
        lastReading = now
        x += weight * (sin(angle) - x)
        y += weight * (cos(angle) - y)
        smoothed = ((atan2(x, y) * 180 / PI).roundToInt() + 360) % 360
    }

    // Pass the smoothed bearing on when it has moved by 2 degrees or more, so it doesn't flicker
    // between two values.
    fun update(): Boolean {
        val smoothed = smoothed ?: return false
        val bearing = bearing
        if (bearing != null && abs((smoothed - bearing + 540) % 360 - 180) < 2) return false
        this.bearing = smoothed
        return true
    }
}

@SuppressLint("MissingPermission") // only called once the permissions are granted
class PointsNorth(private val context: Context) : SensorEventListener {
    var role by mutableStateOf(Role.SPOKE)
        private set
    var bearing by mutableStateOf<Int?>(null)
        private set
    var flash by mutableStateOf(false)
        private set
    var sessionId by mutableStateOf(randomId())
        private set
    var connection by mutableStateOf(Connection.CONNECTING)
        private set
    private var bluetooth by mutableStateOf("Starting Bluetooth…")
    private var bridgeCount by mutableStateOf(0)
    private val peers = mutableStateMapOf<String, Device>()

    val clientId = randomId()
    var server = DEFAULT_SERVER
        private set
    private var width = 100.0
    private var height = 100.0
    var displayRotation = Surface.ROTATION_0

    private val relay = Relay(clientId, server, sessionId)
    private val bridges = HashMap<String, Bridge>() // by Bluetooth address
    private var adapter: BluetoothAdapter? = null
    private var gattServer: BluetoothGattServer? = null
    private val sensors = context.getSystemService(Context.SENSOR_SERVICE) as SensorManager

    init {
        relay.info = {
            JSONObject().put("width", width).put("height", height)
                .put("bearing", bearing?.toDouble() ?: JSONObject.NULL).put("role", role.wire)
        }
        relay.onMessage = { receive(it) }
        relay.onState = { connection = if (it) Connection.ONLINE else Connection.OFFLINE }
        relay.open()
        sensors.getDefaultSensor(Sensor.TYPE_ROTATION_VECTOR)?.let {
            sensors.registerListener(this, it, SensorManager.SENSOR_DELAY_UI)
        }
    }

    val joinUrl: String
        get() = WEB_APP + "?session=" + sessionId +
            if (server != DEFAULT_SERVER) "&server=" + Uri.encode(server) else ""

    val status: String
        get() {
            val parts = mutableListOf("Session $sessionId")
            if (role == Role.HUB) parts.add(if (bridgeCount == 1) "1 micro:bit" else "$bridgeCount micro:bits")
            if (bluetooth.isNotEmpty()) parts.add(bluetooth)
            return parts.joinToString(" · ")
        }

    // Every device with a known bearing, this one included.
    val devices: List<Device>
        get() {
            val list = peers.values.filter { it.bearing != null }.toMutableList()
            bearing?.let { list.add(Device(clientId, it.toDouble(), width, height, role, isSelf = true)) }
            return list
        }

    // MARK: The session

    // Join the session in a scanned QR code: a Points North link with ?session= (and ?server=).
    fun join(link: String): Boolean {
        val uri = Uri.parse(link)
        val session = uri.getQueryParameter("session")
        if (session.isNullOrEmpty()) return false
        sessionId = session
        connection = Connection.CONNECTING
        server = uri.getQueryParameter("server") ?: DEFAULT_SERVER
        peers.clear()
        for (r in listOf(relay) + bridges.values.map { it.relay }) {
            r.sessionId = sessionId
            r.server = server
            r.reopen()
        }
        advertise()
        return true
    }

    fun changeRole(newRole: Role) {
        if (newRole == role) return
        role = newRole
        relay.send(relay.info().put("type", "client_info")) // tell everyone
        if (role == Role.HUB) {
            startScanning()
            mainThread.post(bridgeTimer)
        } else {
            adapter?.bluetoothLeScanner?.stopScan(scanCallback)
            mainThread.removeCallbacks(bridgeTimer)
            for (bridge in bridges.values.toList()) dropBridge(bridge)
        }
    }

    private fun receive(message: JSONObject) {
        val type = message.optString("type")
        val id = message.optString("clientId")
        if (id.isEmpty() || id == clientId) return
        when (type) {
            "client_info", "compass" -> {
                var device = peers[id] ?: Device(id)
                if (message.has("bearing") && !message.isNull("bearing")) device = device.copy(bearing = message.getDouble("bearing"))
                if (message.has("width") && !message.isNull("width")) device = device.copy(width = message.getDouble("width"))
                if (message.has("height") && !message.isNull("height")) device = device.copy(height = message.getDouble("height"))
                Role.entries.firstOrNull { it.wire == message.optString("role") }?.let { device = device.copy(role = it) }
                peers[id] = device
                if (type == "client_info") relay.replyToClientInfo(message)
            }
            "message" -> showMessage()
            "disconnect" -> peers.remove(id)
        }
    }

    // MARK: Messages

    fun send(text: String, to: String, from: Relay = relay) {
        from.send(JSONObject().put("type", "message").put("text", text).put("targetClientId", to))
    }

    // The device `offset` places round the circle (in bearing order) from the one with this ID:
    // devices sit opposite where they point, so -1 is on its right and +1 on its left. Hubs sit
    // in the middle, so they have no neighbours.
    fun neighbour(of: String, offset: Int): String? {
        val ordered = devices.filter { it.role != Role.HUB }.sortedBy { it.bearing }
        val i = ordered.indexOfFirst { it.id == of }
        if (ordered.size < 2 || i == -1) return null
        return ordered[((i + offset) % ordered.size + ordered.size) % ordered.size].id
    }

    fun sendToNeighbour(text: String, offset: Int) {
        neighbour(clientId, offset)?.let { send(text, it) }
    }

    private fun showMessage() {
        flash = true
        mainThread.postDelayed({ flash = false }, 140)
    }

    // MARK: This device

    fun setSize(newWidth: Double, newHeight: Double) {
        width = newWidth
        height = newHeight
        sendCompass()
    }

    // The bearing of the top of the screen as it's currently shown, from the rotation vector
    // (compass, accelerometer and gyroscope combined).
    override fun onSensorChanged(event: SensorEvent) {
        val rotation = FloatArray(9)
        SensorManager.getRotationMatrixFromVector(rotation, event.values)
        val (axisX, axisY) = when (displayRotation) {
            Surface.ROTATION_90 -> SensorManager.AXIS_Y to SensorManager.AXIS_MINUS_X
            Surface.ROTATION_180 -> SensorManager.AXIS_MINUS_X to SensorManager.AXIS_MINUS_Y
            Surface.ROTATION_270 -> SensorManager.AXIS_MINUS_Y to SensorManager.AXIS_X
            else -> SensorManager.AXIS_X to SensorManager.AXIS_Y
        }
        val remapped = FloatArray(9)
        SensorManager.remapCoordinateSystem(rotation, axisX, axisY, remapped)
        val orientation = FloatArray(3)
        SensorManager.getOrientation(remapped, orientation)
        val value = (Math.toDegrees(orientation[0].toDouble()).roundToInt() % 360 + 360) % 360
        if (value == bearing) return
        bearing = value
        sendCompass()
    }

    override fun onAccuracyChanged(sensor: Sensor, accuracy: Int) {}

    private fun sendCompass() {
        val bearing = bearing ?: return
        relay.send(JSONObject().put("type", "compass").put("bearing", bearing.toDouble())
            .put("width", width).put("height", height).put("role", role.wire))
    }

    // MARK: Bluetooth

    fun startBluetooth() {
        val manager = context.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
        val adapter = manager.adapter
        this.adapter = adapter
        bluetooth = when {
            adapter == null -> "No Bluetooth on this device"
            !adapter.isEnabled -> "Bluetooth is off"
            else -> ""
        }
        if (adapter == null || !adapter.isEnabled) return

        val service = BluetoothGattService(POINTS_NORTH_SERVICE, BluetoothGattService.SERVICE_TYPE_PRIMARY)
        service.addCharacteristic(BluetoothGattCharacteristic(SESSION_CHARACTERISTIC,
            BluetoothGattCharacteristic.PROPERTY_READ, BluetoothGattCharacteristic.PERMISSION_READ))
        gattServer = manager.openGattServer(context, serverCallback)?.also { it.addService(service) }
        advertise()
        if (role == Role.HUB) startScanning()
    }

    fun stop() {
        sensors.unregisterListener(this)
        mainThread.removeCallbacks(bridgeTimer)
        adapter?.bluetoothLeAdvertiser?.stopAdvertising(advertiseCallback)
        adapter?.bluetoothLeScanner?.stopScan(scanCallback)
        for (bridge in bridges.values.toList()) dropBridge(bridge)
        gattServer?.close()
        relay.close()
    }

    // MARK: Peripheral: offering the session

    private val advertiseCallback = object : AdvertiseCallback() {
        override fun onStartFailure(errorCode: Int) {
            mainThread.post { bluetooth = "Couldn't advertise (error $errorCode)" }
        }
    }

    private fun advertise() {
        val advertiser = adapter?.bluetoothLeAdvertiser ?: return
        advertiser.stopAdvertising(advertiseCallback)
        val settings = AdvertiseSettings.Builder()
            .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
            .setConnectable(true)
            .build()
        val data = AdvertiseData.Builder().addServiceUuid(ParcelUuid(POINTS_NORTH_SERVICE)).build()
        val response = AdvertiseData.Builder()
            .addServiceData(ParcelUuid(POINTS_NORTH_SERVICE), sessionId.toByteArray())
            .build()
        advertiser.startAdvertising(settings, data, response, advertiseCallback)
    }

    private val serverCallback = object : BluetoothGattServerCallback() {
        override fun onCharacteristicReadRequest(
            device: BluetoothDevice, requestId: Int, offset: Int, characteristic: BluetoothGattCharacteristic,
        ) {
            val data = sessionId.toByteArray()
            val server = gattServer ?: return
            when {
                characteristic.uuid != SESSION_CHARACTERISTIC ->
                    server.sendResponse(device, requestId, BluetoothGatt.GATT_READ_NOT_PERMITTED, offset, null)
                offset > data.size ->
                    server.sendResponse(device, requestId, BluetoothGatt.GATT_INVALID_OFFSET, offset, null)
                else ->
                    server.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, data.copyOfRange(offset, data.size))
            }
        }
    }

    // MARK: Central: bridging micro:bits (hub mode)

    private fun startScanning() {
        val scanner = adapter?.bluetoothLeScanner ?: return
        // micro:bits don't advertise their services, only their name, so nothing to filter on.
        val settings = ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build()
        scanner.startScan(null, settings, scanCallback)
    }

    private val scanCallback = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult) {
            val name = result.scanRecord?.deviceName ?: result.device.name ?: ""
            mainThread.post { found(result.device, name) }
        }
    }

    private fun found(device: BluetoothDevice, name: String) {
        if (role != Role.HUB || !name.startsWith("BBC micro:bit") || bridges.containsKey(device.address)) return
        // A client ID that stays the same each time this micro:bit is bridged.
        val id = "mb-" + device.address.replace(":", "").takeLast(8).lowercase()
        val bridge = Bridge(device, Relay(id, server, sessionId))
        bridge.relay.info = {
            JSONObject().put("width", MICROBIT_WIDTH).put("height", MICROBIT_HEIGHT)
                .put("bearing", bridge.bearing?.toDouble() ?: JSONObject.NULL).put("role", Role.SPOKE.wire)
        }
        bridge.relay.onMessage = { message ->
            when (message.optString("type")) {
                "client_info" -> bridge.relay.replyToClientInfo(message)
                "message" -> flashLeds(bridge)
            }
        }
        bridges[device.address] = bridge
        bridgeCount = bridges.size
        bridge.gatt = device.connectGatt(context, false, gattCallback(bridge), BluetoothDevice.TRANSPORT_LE)
    }

    // The relay tells the session the micro:bit has gone when its WebSocket closes.
    private fun dropBridge(bridge: Bridge) {
        bridge.gatt?.disconnect()
        bridge.gatt?.close()
        bridge.relay.close()
        bridges.remove(bridge.device.address)
        bridgeCount = bridges.size
    }

    private fun gattCallback(bridge: Bridge) = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
            mainThread.post {
                if (newState == BluetoothProfile.STATE_CONNECTED) {
                    bridge.relay.open()
                    gatt.discoverServices()
                } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                    dropBridge(bridge)
                }
            }
        }

        override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
            mainThread.post {
                for (service in gatt.services) for (characteristic in service.characteristics) {
                    when (characteristic.uuid) {
                        BEARING_CHARACTERISTIC -> {
                            bridge.queue { gatt.readCharacteristic(characteristic) }
                            bridge.queue { subscribe(gatt, characteristic) }
                        }
                        BUTTON_A_CHARACTERISTIC, BUTTON_B_CHARACTERISTIC -> bridge.queue { subscribe(gatt, characteristic) }
                        LED_MATRIX_CHARACTERISTIC -> bridge.leds = characteristic
                    }
                }
            }
        }

        override fun onCharacteristicRead(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, value: ByteArray, status: Int) {
            mainThread.post {
                changed(bridge, characteristic.uuid, value)
                bridge.next()
            }
        }

        @Deprecated("Before Android 13")
        override fun onCharacteristicRead(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, status: Int) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) return
            @Suppress("DEPRECATION") val value = characteristic.value ?: ByteArray(0)
            mainThread.post {
                changed(bridge, characteristic.uuid, value)
                bridge.next()
            }
        }

        override fun onCharacteristicChanged(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, value: ByteArray) {
            mainThread.post { changed(bridge, characteristic.uuid, value) }
        }

        @Deprecated("Before Android 13")
        override fun onCharacteristicChanged(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) return
            @Suppress("DEPRECATION") val value = characteristic.value ?: ByteArray(0)
            mainThread.post { changed(bridge, characteristic.uuid, value) }
        }

        override fun onCharacteristicWrite(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, status: Int) {
            mainThread.post { bridge.next() }
        }

        override fun onDescriptorWrite(gatt: BluetoothGatt, descriptor: BluetoothGattDescriptor, status: Int) {
            mainThread.post { bridge.next() }
        }
    }

    // Turn a characteristic's notifications on: locally, then by writing its descriptor.
    private fun subscribe(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic): Boolean {
        gatt.setCharacteristicNotification(characteristic, true)
        val descriptor = characteristic.getDescriptor(CLIENT_CONFIGURATION) ?: return false
        val value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            gatt.writeDescriptor(descriptor, value) == BluetoothStatusCodes.SUCCESS
        } else {
            @Suppress("DEPRECATION")
            descriptor.value = value
            @Suppress("DEPRECATION")
            gatt.writeDescriptor(descriptor)
        }
    }

    private fun write(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, value: ByteArray): Boolean {
        val type = BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            gatt.writeCharacteristic(characteristic, value, type) == BluetoothStatusCodes.SUCCESS
        } else {
            @Suppress("DEPRECATION")
            characteristic.value = value
            characteristic.writeType = type
            @Suppress("DEPRECATION")
            gatt.writeCharacteristic(characteristic)
        }
    }

    private fun changed(bridge: Bridge, uuid: UUID, value: ByteArray) {
        if (value.isEmpty()) return
        val first = value[0].toInt() and 0xff
        when (uuid) {
            BEARING_CHARACTERISTIC -> if (value.size >= 2) bridge.add(first or ((value[1].toInt() and 0xff) shl 8))
            // A (on the left) messages the micro:bit's left neighbour, B its right, when pressed: the
            // same messages as swiping on a screen.
            BUTTON_A_CHARACTERISTIC -> if (first == 1) neighbour(bridge.relay.clientId, 1)?.let { send("Swiped!", it, bridge.relay) }
            BUTTON_B_CHARACTERISTIC -> if (first == 1) neighbour(bridge.relay.clientId, -1)?.let { send("Swiped!", it, bridge.relay) }
        }
    }

    // micro:bits notify their bearing every 20 ms, so pass changes on at most five times a second.
    private val bridgeTimer = object : Runnable {
        override fun run() {
            for (bridge in bridges.values) {
                if (bridge.update()) bridge.relay.send(bridge.relay.info().put("type", "compass"))
            }
            mainThread.postDelayed(this, 200)
        }
    }

    private fun flashLeds(bridge: Bridge) {
        val gatt = bridge.gatt ?: return
        val leds = bridge.leds ?: return
        bridge.queue { write(gatt, leds, LEDS_ON) }
        mainThread.postDelayed({ bridge.queue { write(gatt, leds, LEDS_TICK) } }, 150)
    }
}

// MARK: Views

// The ring's geometry, as in the web app, in dp and shared by drawing and hit-testing. Angles are
// in degrees, clockwise from the top of the screen.
class Ring(width: Double, height: Double, val bearing: Double) {
    val center = Offset((width / 2).toFloat(), (height / 2).toFloat())
    val qrSize = min(width, height) * 0.3
    val inner = qrSize / sqrt(2.0)
    val outer = inner * 2

    // Devices round the ring sit on the opposite side of the table from the direction they
    // point; hubs in the middle just point.
    fun angle(device: Device) = device.bearing!! - bearing + if (device.role == Role.HUB) 0.0 else 180.0

    // The outline of a device's screen in its own rotated frame. Round the ring: on the upward
    // axis, between the inner circle and the edge. A hub: in the middle, inside the inner circle.
    fun outline(device: Device): Pair<Rect, Float> {
        if (device.role == Role.HUB) {
            val scale = inner * 2 * 0.95 / hypot(device.width, device.height)
            val w = device.width * scale
            val h = device.height * scale
            return Rect((-w / 2).toFloat(), (-h / 2).toFloat(), (w / 2).toFloat(), (h / 2).toFloat()) to (80 * scale).toFloat()
        }
        val margin = outer - inner
        val scale = min(0.15, margin * 0.9 / max(device.width, device.height))
        val w = device.width * scale
        val h = device.height * scale
        val radialCenter = inner + margin * 0.25 + h / 2
        return Rect((-w / 2).toFloat(), (-radialCenter - h / 2).toFloat(), (w / 2).toFloat(), (-radialCenter + h / 2).toFloat()) to
            (80 * scale).toFloat()
    }
}

// The join link as a QR code: black on white, one pixel per module.
private var qrCache: Pair<String, ImageBitmap>? = null

fun qrCode(text: String): ImageBitmap {
    qrCache?.let { if (it.first == text) return it.second }
    val matrix = QRCodeWriter().encode(text, BarcodeFormat.QR_CODE, 0, 0, mapOf(EncodeHintType.MARGIN to 1))
    val bitmap = Bitmap.createBitmap(matrix.width, matrix.height, Bitmap.Config.ARGB_8888)
    for (x in 0 until matrix.width) for (y in 0 until matrix.height) {
        bitmap.setPixel(x, y, if (matrix[x, y]) android.graphics.Color.BLACK else android.graphics.Color.WHITE)
    }
    return bitmap.asImageBitmap().also { qrCache = text to it }
}

@Composable
fun PointsNorthScreen(model: PointsNorth, onJoin: () -> Unit) {
    val style = TextStyle(fontFamily = FontFamily.Monospace, fontSize = 20.sp)
    BoxWithConstraints(Modifier.fillMaxSize().background(Color.Black)) {
        val width = maxWidth.value.toDouble()
        val height = maxHeight.value.toDouble()
        LaunchedEffect(width, height) { model.setSize(width, height) }

        Canvas(Modifier.fillMaxSize().pointerInput(Unit) { touches(model, width, height) }) {
            withTransform({ scale(density, density, Offset.Zero) }) { drawRing(model, width, height) }
        }

        Column(
            Modifier.fillMaxSize().padding(top = 48.dp, bottom = 32.dp, start = 16.dp, end = 16.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            // SPOKE | HUB: the selected role is white and bold.
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                for ((i, role) in Role.entries.withIndex()) {
                    if (i > 0) Text("|", style = style, color = Color.Gray)
                    Text(
                        role.wire.uppercase(), style = style,
                        fontWeight = if (model.role == role) FontWeight.Bold else FontWeight.Normal,
                        color = if (model.role == role) Color.White else Color.Gray,
                        modifier = Modifier.clickable { model.changeRole(role) },
                    )
                }
            }
            // SERVER: CONNECTING, ONLINE or OFFLINE, white when online.
            Text(
                "SERVER: " + model.connection.name, style = style,
                color = if (model.connection == Connection.ONLINE) Color.White else Color.Gray,
                modifier = Modifier.padding(top = 4.dp),
            )
            Spacer(Modifier.weight(1f))
            Text("JOIN", style = style, color = Color.White, modifier = Modifier.clickable { onJoin() })
            Text(model.status, color = Color.Gray, fontSize = 13.sp)
        }

        val flash by animateFloatAsState(if (model.flash) 1f else 0f, tween(if (model.flash) 0 else 220), label = "flash")
        Box(Modifier.fillMaxSize().background(Color.White.copy(alpha = flash)))
    }
}

private fun DrawScope.drawRing(model: PointsNorth, width: Double, height: Double) {
    val ring = Ring(width, height, (model.bearing ?: 0).toDouble())
    translate(ring.center.x, ring.center.y) {
        drawCircle(Color.White, ring.outer.toFloat(), Offset.Zero, style = Stroke(2f))
        val devices = if (model.bearing == null) emptyList() else model.devices
        if (model.bearing != null) {
            // Dotted north line between the inner circle and the edge.
            rotate((-ring.bearing).toFloat(), Offset.Zero) {
                drawLine(Color.White, Offset(0f, -ring.inner.toFloat()), Offset(0f, -ring.outer.toFloat()), 2f,
                    pathEffect = PathEffect.dashPathEffect(floatArrayOf(3f, 6f)))
            }
        }

        for (device in devices) {
            val (rect, corner) = ring.outline(device)
            rotate(ring.angle(device).toFloat(), Offset.Zero) {
                drawRoundRect(Color.Black, rect.topLeft, rect.size, CornerRadius(corner))
                drawRoundRect(Color.White, rect.topLeft, rect.size, CornerRadius(corner), style = Stroke(2f))
            }
        }

        // The QR code for joining, on a hub's screen if there is one: upright, and as big as fits
        // inside the hub's outline at its current angle.
        var side = ring.qrSize
        devices.firstOrNull { it.role == Role.HUB }?.let { hub ->
            val (rect, _) = ring.outline(hub)
            val t = ring.angle(hub) * PI / 180
            side = min(rect.width, rect.height) * 0.8 / (abs(cos(t)) + abs(sin(t)))
        }
        val s = side.roundToInt()
        drawImage(qrCode(model.joinUrl), dstOffset = IntOffset(-s / 2, -s / 2), dstSize = IntSize(s, s),
            filterQuality = FilterQuality.None)
    }
}

// The other device whose outline is under a point (in dp), if any.
private fun deviceAt(model: PointsNorth, point: Offset, width: Double, height: Double): Device? {
    val bearing = model.bearing ?: return null
    val ring = Ring(width, height, bearing.toDouble())
    val x = point.x - ring.center.x
    val y = point.y - ring.center.y
    return model.devices.firstOrNull { device ->
        if (device.isSelf) return@firstOrNull false
        // Undo the device's rotation to get the point in its frame.
        val t = ring.angle(device) * PI / 180
        val c = cos(t).toFloat()
        val s = sin(t).toFloat()
        ring.outline(device).first.contains(Offset(x * c + y * s, y * c - x * s))
    }
}

// Tap a device to message it; swipe to message the device next to you on that side.
private suspend fun androidx.compose.ui.input.pointer.PointerInputScope.touches(model: PointsNorth, width: Double, height: Double) {
    awaitEachGesture {
        val down = awaitFirstDown()
        var last = down
        do {
            val event = awaitPointerEvent()
            event.changes.firstOrNull { it.id == down.id }?.let { last = it }
        } while (event.changes.any { it.pressed })
        val quick = last.uptimeMillis - down.uptimeMillis <= 500
        val dx = (last.position.x - down.position.x) / density
        val dy = (last.position.y - down.position.y) / density
        if (quick && abs(dy) <= 80 && abs(dx) >= 50) {
            model.sendToNeighbour("Swiped!", if (dx > 0) -1 else 1)
        } else if (quick && hypot(dx, dy) <= 12) {
            deviceAt(model, last.position / density, width, height)?.let { model.send("Tapped!", it.id) }
        }
    }
}

class MainActivity : ComponentActivity() {
    private lateinit var model: PointsNorth

    private val permissions = registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { granted ->
        if (granted.values.all { it }) model.startBluetooth()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Advertising only lasts while the app is open, so keep the screen awake.
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        model = PointsNorth(applicationContext)
        model.displayRotation = currentRotation()
        setContent { PointsNorthScreen(model, ::scan) }
        permissions.launch(
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                arrayOf(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT, Manifest.permission.BLUETOOTH_ADVERTISE)
            } else {
                arrayOf(Manifest.permission.ACCESS_FINE_LOCATION)
            },
        )
    }

    override fun onConfigurationChanged(newConfig: android.content.res.Configuration) {
        super.onConfigurationChanged(newConfig)
        model.displayRotation = currentRotation()
    }

    override fun onDestroy() {
        model.stop()
        super.onDestroy()
    }

    @Suppress("DEPRECATION")
    private fun currentRotation(): Int =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) display?.rotation ?: Surface.ROTATION_0
        else windowManager.defaultDisplay.rotation

    // Google's code scanner: it runs in Play services, so the app needs no camera permission.
    private fun scan() {
        val options = GmsBarcodeScannerOptions.Builder().setBarcodeFormats(Barcode.FORMAT_QR_CODE).build()
        GmsBarcodeScanning.getClient(this, options).startScan()
            .addOnSuccessListener { barcode -> barcode.rawValue?.let { model.join(it) } }
    }
}
