// Points North for the M5Stack AtomS3R: a spoke in the same sessions as the web app
// (web/) and the iOS app (ios/PointsNorth.swift), through the same WebSocket
// relay, over WiFi. The screen shows a ring with each device (this one at the bottom) drawn as
// an outline of its screen at its real-world position, found by comparing compass bearings,
// with hubs in the middle, and flashes white when another device messages it. The Atom has no
// touch screen, so its button messages a neighbour instead: click for the device to your
// right, hold for your left.
//
// The Atom has no camera to scan a session's QR code, so it joins the session that the iOS
// apps nearby advertise over Bluetooth: the name "PN <session ID>" with the Points North
// Service (or, if the name is missing, its Session characteristic). It keeps to its session
// while any device nearby still advertises it, and otherwise moves to the strongest one.
//
// The first time (or when held down while it starts), it can't join a WiFi network, so it opens
// its own, named on screen: join that from a phone and pick the network in the page that opens.
#include <ArduinoJson.h>
#include <M5Unified.h>
#include <NimBLEDevice.h>
#include <WebSocketsClient.h>
#include <WiFi.h>
#include <WiFiManager.h>
#include <vector>

#ifndef PN_SERVER_HOST  // the relay, as in the web app; build flags can point it at another one
#define PN_SERVER_HOST "api.davidchatting.com"
#define PN_SERVER_PORT 443
#define PN_SERVER_PATH "/pubgames"
#define PN_SERVER_SSL true
#endif

#define POINTS_NORTH_SERVICE   "00e43092-366d-46da-8323-42bf39b7078e"
#define SESSION_CHARACTERISTIC "7513ce11-f0ca-49fc-a8bf-e9d4f8021fa3"  // the session ID, UTF-8

// The 24 mm Atom at roughly the scale of a phone's screen in points, so its outline is to scale.
const int SIZE_POINTS = 135;
const int MAX_PEERS = 16;

char clientId[9];
M5Canvas canvas(&M5.Display);
WebSocketsClient socket;
WiFiManager wifi;
char portalName[16];
bool online = false;
String sessionId;
int bearing = -1;
uint32_t flashUntil = 0;

// Another device in the session, and what it has told us so far.
struct Peer {
  bool used = false;
  char id[33] = "";
  float bearing = -1;
  float width = 100, height = 100;
  bool hub = false;
};
Peer peers[MAX_PEERS];

Peer* peerFor(const char* id, bool add) {
  for (auto& p : peers)
    if (p.used && strcmp(p.id, id) == 0) return &p;
  if (!add) return nullptr;
  for (auto& p : peers)
    if (!p.used) {
      p = Peer();
      p.used = true;
      strlcpy(p.id, id, sizeof(p.id));
      return &p;
    }
  return nullptr;
}

// MARK: The relay

void send(JsonDocument& message) {
  message["clientId"] = clientId;
  message["sessionId"] = sessionId;
  String text;
  serializeJson(message, text);
  socket.sendTXT(text);
}

void sendInfo(const char* type, const char* target = nullptr) {
  JsonDocument message;
  message["type"] = type;
  message["width"] = SIZE_POINTS;
  message["height"] = SIZE_POINTS;
  if (bearing >= 0) message["bearing"] = bearing;
  else message["bearing"] = nullptr;
  message["role"] = "spoke";
  if (target) message["targetClientId"] = target;
  send(message);
}

void receive(JsonObject message) {
  const char* type = message["type"] | "";
  const char* id = message["clientId"] | "";
  if (!id[0] || strcmp(id, clientId) == 0) return;
  if (!strcmp(type, "client_info") || !strcmp(type, "compass")) {
    Peer* p = peerFor(id, true);
    if (!p) return;
    if (message["bearing"].is<float>()) p->bearing = message["bearing"];
    if (message["width"].is<float>()) p->width = message["width"];
    if (message["height"].is<float>()) p->height = message["height"];
    if (message["role"].is<const char*>()) p->hub = message["role"] == "hub";
    // Answer a newcomer's client_info with ours, as the web app does.
    if (!strcmp(type, "client_info") && message["targetClientId"].isNull()) sendInfo("client_info", id);
  } else if (!strcmp(type, "message")) {
    Serial.printf("Message from %s: %s\n", id, message["text"] | "");
    flashUntil = millis() + 150;
  } else if (!strcmp(type, "disconnect")) {
    if (Peer* p = peerFor(id, false)) p->used = false;
  }
}

void onSocket(WStype_t type, uint8_t* data, size_t length) {
  switch (type) {
    case WStype_CONNECTED:
      online = true;
      sendInfo("client_info");
      break;
    case WStype_DISCONNECTED:
      online = false;
      for (auto& p : peers) p.used = false;
      break;
    case WStype_TEXT: {
      JsonDocument json;
      if (deserializeJson(json, data, length)) break;
      if (json.is<JsonArray>())
        for (JsonObject item : json.as<JsonArray>()) receive(item);
      else
        receive(json.as<JsonObject>());
      break;
    }
    default:
      break;
  }
}

// Once there's WiFi and a session. The client reconnects by itself from then on.
void connectSocket() {
  if (PN_SERVER_SSL) socket.beginSSL(PN_SERVER_HOST, PN_SERVER_PORT, PN_SERVER_PATH, "", "");
  else socket.begin(PN_SERVER_HOST, PN_SERVER_PORT, PN_SERVER_PATH, "");
  socket.onEvent(onSocket);
  socket.setReconnectInterval(3000);
}

// MARK: Finding the session

// The sessions advertised during one scan, and the strongest signal for each.
struct Sighting {
  String session;
  int rssi;
};
std::vector<Sighting> sightings;
NimBLEAddress unnamed;  // advertising the service without a name: read its Session characteristic
volatile bool haveUnnamed = false;
portMUX_TYPE sightingsLock = portMUX_INITIALIZER_UNLOCKED;  // filled in by the Bluetooth task

void sighted(const String& session, int rssi) {
  taskENTER_CRITICAL(&sightingsLock);
  bool seen = false;
  for (auto& s : sightings)
    if (s.session == session) {
      s.rssi = max(s.rssi, rssi);
      seen = true;
    }
  if (!seen && sightings.size() < 8) sightings.push_back({session, rssi});
  taskEXIT_CRITICAL(&sightingsLock);
}

class ScanCallbacks : public NimBLEAdvertisedDeviceCallbacks {
  void onResult(NimBLEAdvertisedDevice* device) override {
    std::string name = device->getName();
    if (name.rfind("PN ", 0) == 0 && name.size() > 3) {
      sighted(String(name.c_str() + 3), device->getRSSI());
    } else if (device->isAdvertisingService(NimBLEUUID(POINTS_NORTH_SERVICE)) && !haveUnnamed) {
      unnamed = device->getAddress();
      haveUnnamed = true;
    }
  }
};

void readUnnamed() {
  NimBLEClient* client = NimBLEDevice::createClient();
  client->setConnectTimeout(5);
  if (client->connect(unnamed)) {
    if (NimBLERemoteService* service = client->getService(POINTS_NORTH_SERVICE))
      if (NimBLERemoteCharacteristic* session = service->getCharacteristic(SESSION_CHARACTERISTIC)) {
        std::string value = session->readValue();
        if (!value.empty()) sighted(String(value.c_str()), client->getRssi());
      }
    client->disconnect();
  }
  NimBLEDevice::deleteClient(client);
}

// After each scan: stay in the session if it's still advertised nearby, else join the
// strongest one. Changing session means reconnecting, so the relay tells the old one we've gone.
void chooseSession() {
  taskENTER_CRITICAL(&sightingsLock);
  std::vector<Sighting> seen = sightings;
  sightings.clear();
  taskEXIT_CRITICAL(&sightingsLock);
  const Sighting* best = nullptr;
  for (auto& s : seen) {
    if (s.session == sessionId) return;
    if (!best || s.rssi > best->rssi) best = &s;
  }
  if (!best) return;
  sessionId = best->session;
  Serial.printf("Joining session %s\n", sessionId.c_str());
  if (online) socket.disconnect();  // reconnects by itself, then sends client_info
}

// A 2 s scan every 10 s (every 3 s until there's a session).
void scanForSessions() {
  NimBLEScan* scan = NimBLEDevice::getScan();
  static uint32_t lastScan = 0;
  static bool scanning = false;
  if (scanning && !scan->isScanning()) {
    scanning = false;
    if (haveUnnamed) {
      readUnnamed();
      haveUnnamed = false;
    }
    chooseSession();
  }
  if (!scanning && (lastScan == 0 || millis() - lastScan > (sessionId.isEmpty() ? 3000 : 10000))) {
    lastScan = millis();
    scan->clearResults();  // only while stopped: clearing a running scan corrupts the heap
    scan->start(2, nullptr, false);
    scanning = true;
  }
}

// MARK: Compass

// M5Unified calibrates the magnetometer all the time, so turning the Atom slowly through every
// direction once is enough: the offsets are saved, so they survive a restart.
void setupCompass() {
  M5.Imu.loadOffsetFromNVS();
  M5.Imu.setCalibration(0, 0, 64);
}

// Saves the magnetometer offsets once a minute, if they've changed.
void saveCompass() {
  static uint32_t lastSave = 0;
  static int32_t saved[3] = {0, 0, 0};
  if (millis() - lastSave < 60000) return;
  lastSave = millis();
  bool changed = false;
  for (int i = 0; i < 3; i++) changed |= M5.Imu.getOffsetData(6 + i) != saved[i];  // 6-8 are the magnetometer's
  if (!changed) return;
  for (int i = 0; i < 3; i++) saved[i] = M5.Imu.getOffsetData(6 + i);
  M5.Imu.saveOffsetToNVS();
}

// The bearing of the screen's top edge, in degrees clockwise from north, whatever the tilt.
bool readCompass(int& result) {
  if (!M5.Imu.update()) return false;
  auto d = M5.Imu.getImuData();
  float* m = d.mag.value;    // offsets already removed
  float* a = d.accel.value;  // points up, away from gravity

  // east = down x mag, north = east x down (horizontal north, whatever the tilt)
  float e[3] = {-(a[1] * m[2] - a[2] * m[1]), -(a[2] * m[0] - a[0] * m[2]), -(a[0] * m[1] - a[1] * m[0])};
  float n[3] = {-(e[1] * a[2] - e[2] * a[1]), -(e[2] * a[0] - e[0] * a[2]), -(e[0] * a[1] - e[1] * a[0])};
  float eLen = sqrt(e[0] * e[0] + e[1] * e[1] + e[2] * e[2]), nLen = sqrt(n[0] * n[0] + n[1] * n[1] + n[2] * n[2]);
  if (eLen == 0 || nLen == 0) return false;
  // Smooth the heading heavily as a direction (so 359 to 0 doesn't swing round): it settles
  // in about a second, which suits devices lying on a table.
  static float sx = 0, sy = 0;
  float h = atan2(e[1] / eLen, n[1] / nLen);
  sx += 0.05 * (sin(h) - sx);
  sy += 0.05 * (cos(h) - sy);
  result = ((int)lround(atan2(sx, sy) * 180 / PI) + 360) % 360;
  return true;
}

// MARK: The ring

// A device in the session, this one included.
struct Device {
  const char* id;
  float bearing, width, height;
  bool hub, isSelf;
};

// Every device with a known bearing, this one included.
std::vector<Device> devices() {
  std::vector<Device> list;
  if (bearing >= 0) list.push_back({clientId, (float)bearing, SIZE_POINTS, SIZE_POINTS, false, true});
  for (auto& p : peers)
    if (p.used && p.bearing >= 0) list.push_back({p.id, p.bearing, p.width, p.height, p.hub, false});
  return list;
}

// Message the device `offset` places round the circle (in bearing order) from this one: devices
// sit opposite where they point, so -1 is on your right and +1 on your left. Hubs sit in the
// middle, so they're not counted.
void sendToNeighbour(const char* text, int offset) {
  std::vector<Device> list;
  for (auto& d : devices())
    if (!d.hub) list.push_back(d);
  std::sort(list.begin(), list.end(), [](const Device& a, const Device& b) { return a.bearing < b.bearing; });
  int n = list.size(), i = 0;
  while (i < n && !list[i].isSelf) i++;
  if (n < 2 || i == n) return;
  JsonDocument message;
  message["type"] = "message";
  message["text"] = text;
  message["targetClientId"] = list[((i + offset) % n + n) % n].id;
  send(message);
}

// A device's screen outline, w by h either side of (0, -offset) in a frame turned by `angle`
// degrees clockwise about the centre of the screen.
void drawOutline(float cx, float cy, float angle, float w, float h, float offset) {
  float a = angle * PI / 180, s = sin(a), c = cos(a);
  float corners[4][2] = {{-w, -offset - h}, {w, -offset - h}, {w, -offset + h}, {-w, -offset + h}};
  int px[4], py[4];
  for (int k = 0; k < 4; k++) {
    px[k] = lround(cx + corners[k][0] * c - corners[k][1] * s);
    py[k] = lround(cy + corners[k][0] * s + corners[k][1] * c);
  }
  canvas.fillTriangle(px[0], py[0], px[1], py[1], px[2], py[2], TFT_BLACK);
  canvas.fillTriangle(px[0], py[0], px[2], py[2], px[3], py[3], TFT_BLACK);
  for (int k = 0; k < 4; k++) canvas.drawLine(px[k], py[k], px[(k + 1) % 4], py[(k + 1) % 4], TFT_WHITE);
}

void draw() {
  if (millis() < flashUntil) {
    canvas.fillSprite(TFT_WHITE);
    canvas.pushSprite(0, 0);
    return;
  }
  float cx = canvas.width() / 2.0, cy = canvas.height() / 2.0;
  float inner = canvas.width() * 0.3 / sqrt(2), outer = inner * 2, margin = outer - inner;
  canvas.fillSprite(TFT_BLACK);
  canvas.drawCircle(cx, cy, outer, TFT_WHITE);

  // What it's waiting for, in the middle, until it's in a session.
  canvas.setTextDatum(middle_center);
  canvas.setTextColor(TFT_DARKGREY);
  if (wifi.getConfigPortalActive()) {
    canvas.drawString("WiFi setup:", cx, cy - 6);
    canvas.drawString(portalName, cx, cy + 6);
  } else if (const char* state = !WiFi.isConnected() ? "WiFi" : sessionId.isEmpty() ? "session?" : !online ? "server?" : nullptr) {
    canvas.drawString(state, cx, cy);
  }

  if (bearing >= 0) {
    // Dotted north line between the inner circle and the edge.
    float t = -bearing * PI / 180;
    for (float r = inner; r <= outer; r += 3) canvas.drawPixel(cx + r * sin(t), cy - r * cos(t), TFT_WHITE);

    for (auto& d : devices()) {
      if (d.hub) {
        // In the middle, turned to its bearing, its corners inside the inner circle.
        float scale = inner * 2 * 0.95 / hypot(d.width, d.height);
        drawOutline(cx, cy, d.bearing - bearing, d.width * scale / 2, d.height * scale / 2, 0);
      } else {
        // On the opposite side of the table from where it points.
        float scale = min(0.15f, margin * 0.9f / max(d.width, d.height));
        float h = d.height * scale / 2;
        drawOutline(cx, cy, d.bearing - bearing + 180, d.width * scale / 2, h, inner + margin * 0.25 + h);
      }
    }
  }
  canvas.pushSprite(0, 0);
}

void setup() {
  Serial.begin(115200);  // for the status line, and WiFiManager's own messages
  M5.begin();
  canvas.createSprite(M5.Display.width(), M5.Display.height());
  setupCompass();
  const char* chars = "abcdefghijklmnopqrstuvwxyz0123456789";
  for (int i = 0; i < 8; i++) clientId[i] = chars[esp_random() % 36];
  clientId[8] = 0;

  // Joins the network it was given last time, or opens the setup portal, without waiting for
  // either: wifi.process() in the loop runs the portal.
  WiFi.mode(WIFI_STA);
  uint8_t mac[6];
  WiFi.macAddress(mac);
  snprintf(portalName, sizeof(portalName), "PN-Atom-%02x%02x", mac[4], mac[5]);
  if (M5.BtnA.isPressed()) wifi.resetSettings();
  wifi.setConfigPortalBlocking(false);
  wifi.autoConnect(portalName);

  NimBLEDevice::init("");
  NimBLEScan* scan = NimBLEDevice::getScan();
  scan->setAdvertisedDeviceCallbacks(new ScanCallbacks(), false);
  scan->setActiveScan(true);  // iOS puts the name in the scan response
  // Listen for 30 ms in every 160, leaving the radio (shared with WiFi) free most of the time.
  scan->setInterval(160);
  scan->setWindow(30);
}

void loop() {
  M5.update();
  wifi.process();
  if (M5.BtnA.wasClicked()) sendToNeighbour("Swiped!", -1);
  if (M5.BtnA.wasHold()) sendToNeighbour("Swiped!", 1);

  // Only pass on changes of 2 degrees or more, so the bearing doesn't flicker between two
  // values, and at most five times a second.
  static uint32_t lastSent = 0;
  int value;
  if (readCompass(value) && (bearing < 0 || abs((value - bearing + 540) % 360 - 180) >= 2) && millis() - lastSent > 200) {
    bearing = value;
    lastSent = millis();
    if (online) sendInfo("compass");
  }

  static bool started = false;
  if (!started && WiFi.isConnected() && !sessionId.isEmpty()) {
    started = true;
    connectSocket();
  }
  if (started) socket.loop();

  // A status line every 2 s on the serial port.
  static uint32_t lastLog = 0;
  if (millis() - lastLog > 2000) {
    lastLog = millis();
    Serial.printf("wifi=%d portal=%d session=%s server=%d bearing=%d\n", WiFi.isConnected(), wifi.getConfigPortalActive(),
                  sessionId.isEmpty() ? "-" : sessionId.c_str(), online, bearing);
  }

  saveCompass();
  scanForSessions();
  draw();
  delay(20);
}
