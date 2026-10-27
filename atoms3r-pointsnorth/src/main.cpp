// Points North over BLE for the M5Stack AtomS3R: joins the iOS app (ios/PointsNorth.swift)
// round the table. The screen shows a ring with each device (this one at the bottom) drawn as
// an outline of its screen at its real-world position, found by comparing compass bearings,
// and flashes white when another device messages it. The Atom has no touch screen, so its
// button messages a neighbour instead: click for the device to your right, hold for your left.
//
// Same protocol as the iOS app: it advertises its bearing with the micro:bit's Magnetometer
// Service plus a Points North Service holding its screen size and a message inbox, and connects
// to every device it finds advertising the Magnetometer Service that also has Points North.
#include <M5Unified.h>
#include <NimBLEDevice.h>
#include <vector>

#define MAGNETOMETER_SERVICE   "e95df2d8-251d-470a-a062-fa1922dfa9a8"
#define BEARING_CHARACTERISTIC "e95d9715-251d-470a-a062-fa1922dfa9a8"  // uint16 LE, degrees
// Info: 8-byte client ID, then uint16 LE screen width and height in points.
// Message: the sender's 8-byte client ID, then UTF-8 text.
#define POINTS_NORTH_SERVICE   "00e43092-366d-46da-8323-42bf39b7078e"
#define INFO_CHARACTERISTIC    "ecc93172-718c-4a86-8459-9cb1d893e71a"
#define MESSAGE_CHARACTERISTIC "02ba1fe3-f825-486b-9b9b-417d31d6debc"

// The 0.85" screen in iOS-style points (about 1/160 inch), so its outline is to scale.
const int SCREEN_POINTS = 96;
// The prebuilt controller allows 6 BLE activities: advertising, scanning, and two links for
// each other device (it connects to us, we connect to it).
const int MAX_PEERS = 2;

char clientId[9];
M5Canvas canvas(&M5.Display);
NimBLECharacteristic *bearingChar, *infoChar;
int bearing = -1;
volatile uint32_t flashUntil = 0;

// Another device round the table, and what it has told us so far.
struct Peer {
  bool used = false;
  volatile bool disconnected = false;
  NimBLEAddress address;
  NimBLEClient* client = nullptr;
  NimBLERemoteCharacteristic* message = nullptr;
  char id[9] = "";
  int width = 100, height = 100;
  int bearing = -1;
};
Peer peers[MAX_PEERS];
std::vector<NimBLEAddress> ignored;  // no Points North Service, e.g. the CompassBLE app

// A device seen advertising, waiting for the main loop to connect to it.
volatile bool found = false;
NimBLEAddress foundAddress;

Peer* peerFor(NimBLEClient* client) {
  for (auto& p : peers)
    if (p.used && p.client == client) return &p;
  return nullptr;
}

bool known(const NimBLEAddress& address) {
  for (auto& p : peers)
    if (p.used && p.address == address) return true;
  for (auto& a : ignored)
    if (a == address) return true;
  return false;
}

int uint16At(const uint8_t* data, int offset) { return data[offset] | data[offset + 1] << 8; }

void readInfo(Peer& p, const uint8_t* data, size_t length) {
  if (length < 12) return;
  memcpy(p.id, data, 8);
  p.id[8] = 0;
  p.width = uint16At(data, 8);
  p.height = uint16At(data, 10);
}

// MARK: Sharing this device

class ServerCallbacks : public NimBLEServerCallbacks {
  // Advertising stops when something connects; keep going so the others can connect too.
  void onConnect(NimBLEServer*) override { NimBLEDevice::startAdvertising(); }
};

class MessageCallbacks : public NimBLECharacteristicCallbacks {
  void onWrite(NimBLECharacteristic*) override { flashUntil = millis() + 150; }
};

void setInfo() {
  uint8_t info[12];
  memcpy(info, clientId, 8);
  info[8] = info[10] = SCREEN_POINTS & 0xff;
  info[9] = info[11] = SCREEN_POINTS >> 8;
  infoChar->setValue(info, sizeof(info));
}

void setupServer() {
  NimBLEServer* server = NimBLEDevice::createServer();
  server->setCallbacks(new ServerCallbacks());

  NimBLEService* magnetometer = server->createService(MAGNETOMETER_SERVICE);
  bearingChar = magnetometer->createCharacteristic(BEARING_CHARACTERISTIC, NIMBLE_PROPERTY::READ | NIMBLE_PROPERTY::NOTIFY);
  uint8_t zero[2] = {0, 0};
  bearingChar->setValue(zero, 2);
  magnetometer->start();

  NimBLEService* pointsNorth = server->createService(POINTS_NORTH_SERVICE);
  infoChar = pointsNorth->createCharacteristic(INFO_CHARACTERISTIC, NIMBLE_PROPERTY::READ | NIMBLE_PROPERTY::NOTIFY);
  setInfo();
  pointsNorth->createCharacteristic(MESSAGE_CHARACTERISTIC, NIMBLE_PROPERTY::WRITE)->setCallbacks(new MessageCallbacks());
  pointsNorth->start();

  // The service UUID and the name don't both fit, so the name goes in the scan response.
  // The compass page's picker filters on the "BBC micro:bit" prefix.
  NimBLEAdvertisementData data, response;
  data.setFlags(BLE_HS_ADV_F_DISC_GEN | BLE_HS_ADV_F_BREDR_UNSUP);
  data.setCompleteServices(NimBLEUUID(MAGNETOMETER_SERVICE));
  response.setName("BBC micro:bit [atom]");
  NimBLEAdvertising* advertising = NimBLEDevice::getAdvertising();
  advertising->setScanResponse(true);
  advertising->setAdvertisementData(data);
  advertising->setScanResponseData(response);
  advertising->start();
}

// MARK: Finding the other devices

class ScanCallbacks : public NimBLEAdvertisedDeviceCallbacks {
  void onResult(NimBLEAdvertisedDevice* device) override {
    if (!found && device->isAdvertisingService(NimBLEUUID(MAGNETOMETER_SERVICE))) {
      foundAddress = device->getAddress();
      found = true;
    }
  }
};

class ClientCallbacks : public NimBLEClientCallbacks {
  void onDisconnect(NimBLEClient* client) override {
    if (Peer* p = peerFor(client)) p->disconnected = true;  // tidied up in the main loop
  }
};
ClientCallbacks clientCallbacks;

void onNotify(NimBLERemoteCharacteristic* characteristic, uint8_t* data, size_t length, bool) {
  Peer* p = peerFor(characteristic->getRemoteService()->getClient());
  if (!p) return;
  if (characteristic->getUUID() == NimBLEUUID(BEARING_CHARACTERISTIC) && length >= 2) p->bearing = uint16At(data, 0);
  else if (characteristic->getUUID() == NimBLEUUID(INFO_CHARACTERISTIC)) readInfo(*p, data, length);
}

void connectTo(const NimBLEAddress& address) {
  Peer* slot = nullptr;
  for (auto& p : peers)
    if (!p.used) slot = &p;
  if (!slot) return;

  NimBLEClient* client = NimBLEDevice::createClient();
  client->setClientCallbacks(&clientCallbacks, false);
  client->setConnectTimeout(5);
  if (!client->connect(address)) {
    NimBLEDevice::deleteClient(client);
    return;
  }
  NimBLERemoteService* magnetometer = client->getService(MAGNETOMETER_SERVICE);
  NimBLERemoteService* pointsNorth = client->getService(POINTS_NORTH_SERVICE);
  NimBLERemoteCharacteristic* bearing = magnetometer ? magnetometer->getCharacteristic(BEARING_CHARACTERISTIC) : nullptr;
  NimBLERemoteCharacteristic* info = pointsNorth ? pointsNorth->getCharacteristic(INFO_CHARACTERISTIC) : nullptr;
  NimBLERemoteCharacteristic* message = pointsNorth ? pointsNorth->getCharacteristic(MESSAGE_CHARACTERISTIC) : nullptr;
  if (!bearing || !info || !message) {
    // Not playing: remember it so it isn't connected to again.
    if (ignored.size() < 16) ignored.push_back(address);
    NimBLEDevice::deleteClient(client);
    return;
  }

  Peer& p = *slot;
  p = Peer();
  p.address = address;
  p.client = client;
  p.message = message;
  NimBLEAttValue value = info->readValue();
  readInfo(p, value.data(), value.length());
  value = bearing->readValue();
  if (value.length() >= 2) p.bearing = uint16At(value.data(), 0);
  p.used = true;
  info->subscribe(true, onNotify);
  bearing->subscribe(true, onNotify);

  // An iPhone changes its Bluetooth address every so often, so the same device can turn up
  // again: keep only the newest link to it.
  for (auto& other : peers)
    if (&other != &p && other.used && strcmp(other.id, p.id) == 0) other.disconnected = true;
}

void tidyPeers() {
  for (auto& p : peers)
    if (p.used && p.disconnected) {
      p.used = false;
      NimBLEDevice::deleteClient(p.client);
    }
}

// MARK: Compass

// Running min/max for hard-iron calibration: turn the Atom slowly through every direction.
float minM[3] = {1e9, 1e9, 1e9}, maxM[3] = {-1e9, -1e9, -1e9};

// The bearing of the screen's top edge, in degrees clockwise from north, whatever the tilt.
bool readCompass(int& result) {
  if (!M5.Imu.update()) return false;
  auto d = M5.Imu.getImuData();
  float m[3];
  for (int i = 0; i < 3; i++) {
    minM[i] = min(minM[i], d.mag.value[i]);
    maxM[i] = max(maxM[i], d.mag.value[i]);
    m[i] = d.mag.value[i] - (minM[i] + maxM[i]) / 2;
  }
  float* a = d.accel.value;  // points up, away from gravity

  // east = down x mag, north = east x down (horizontal north, whatever the tilt)
  float e[3] = {-(a[1] * m[2] - a[2] * m[1]), -(a[2] * m[0] - a[0] * m[2]), -(a[0] * m[1] - a[1] * m[0])};
  float n[3] = {-(e[1] * a[2] - e[2] * a[1]), -(e[2] * a[0] - e[0] * a[2]), -(e[0] * a[1] - e[1] * a[0])};
  float eLen = sqrt(e[0] * e[0] + e[1] * e[1] + e[2] * e[2]), nLen = sqrt(n[0] * n[0] + n[1] * n[1] + n[2] * n[2]);
  if (eLen == 0 || nLen == 0) return false;
  result = ((int)lround(atan2(e[1] / eLen, n[1] / nLen) * 180 / PI) + 360) % 360;
  return true;
}

// MARK: The ring

// A device round the table, this one included.
struct Device {
  const char* id;
  int bearing, width, height;
  bool isSelf;
};

// Every device with a known bearing, this one included, in bearing order.
std::vector<Device> devices() {
  std::vector<Device> list;
  if (bearing >= 0) list.push_back({clientId, bearing, SCREEN_POINTS, SCREEN_POINTS, true});
  for (auto& p : peers)
    if (p.used && p.bearing >= 0 && p.id[0]) list.push_back({p.id, p.bearing, p.width, p.height, false});
  std::sort(list.begin(), list.end(), [](const Device& a, const Device& b) { return a.bearing < b.bearing; });
  return list;
}

// Message the device `offset` places round the circle (in bearing order) from this one.
void sendToNeighbour(const char* text, int offset) {
  auto list = devices();
  int n = list.size(), i = 0;
  while (i < n && !list[i].isSelf) i++;
  if (n < 2 || i == n) return;
  const char* target = list[((i + offset) % n + n) % n].id;
  for (auto& p : peers)
    if (p.used && strcmp(p.id, target) == 0) {
      std::string message = std::string(clientId) + text;
      p.message->writeValue((const uint8_t*)message.data(), message.size(), true);
    }
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
  if (bearing >= 0) {
    // Dotted north line between the inner circle and the edge.
    float t = -bearing * PI / 180;
    for (float r = inner; r <= outer; r += 3) canvas.drawPixel(cx + r * sin(t), cy - r * cos(t), TFT_WHITE);

    // Each device's screen outline, on the opposite side of the table from where it points.
    for (auto& d : devices()) {
      float a = (d.bearing - bearing + 180) * PI / 180, s = sin(a), c = cos(a);
      float scale = min(0.15f, margin * 0.9f / max(d.width, d.height));
      float w = d.width * scale / 2, h = d.height * scale / 2, rc = inner + margin * 0.25 + h;
      float corners[4][2] = {{-w, -rc - h}, {w, -rc - h}, {w, -rc + h}, {-w, -rc + h}};
      int px[4], py[4];
      for (int k = 0; k < 4; k++) {
        px[k] = lround(cx + corners[k][0] * c - corners[k][1] * s);
        py[k] = lround(cy + corners[k][0] * s + corners[k][1] * c);
      }
      canvas.fillTriangle(px[0], py[0], px[1], py[1], px[2], py[2], TFT_BLACK);
      canvas.fillTriangle(px[0], py[0], px[2], py[2], px[3], py[3], TFT_BLACK);
      for (int k = 0; k < 4; k++) canvas.drawLine(px[k], py[k], px[(k + 1) % 4], py[(k + 1) % 4], TFT_WHITE);
    }
  }
  canvas.pushSprite(0, 0);
}

void setup() {
  M5.begin();
  canvas.createSprite(M5.Display.width(), M5.Display.height());
  const char* chars = "abcdefghijklmnopqrstuvwxyz0123456789";
  for (int i = 0; i < 8; i++) clientId[i] = chars[esp_random() % 36];
  clientId[8] = 0;

  NimBLEDevice::init("BBC micro:bit [atom]");
  setupServer();
  NimBLEScan* scan = NimBLEDevice::getScan();
  scan->setAdvertisedDeviceCallbacks(new ScanCallbacks(), false);
  scan->setMaxResults(0);  // only the callback is needed
  scan->setInterval(100);
  scan->setWindow(50);
}

void loop() {
  M5.update();
  if (M5.BtnA.wasClicked()) sendToNeighbour("Swiped!", 1);
  if (M5.BtnA.wasHold()) sendToNeighbour("Swiped!", -1);

  int value;
  if (readCompass(value) && value != bearing) {
    bearing = value;
    uint8_t data[2] = {(uint8_t)(value & 0xff), (uint8_t)(value >> 8)};
    bearingChar->setValue(data, 2);
    bearingChar->notify();
  }

  tidyPeers();
  NimBLEScan* scan = NimBLEDevice::getScan();
  if (found) {
    NimBLEAddress address = foundAddress;
    found = false;
    if (!known(address)) {
      scan->stop();
      connectTo(address);
    }
  }
  bool room = false;
  for (auto& p : peers) room |= !p.used;
  // Short scans, so a device that went away and came back is reported again.
  if (room && !scan->isScanning()) scan->start(2, nullptr, false);

  draw();
  delay(30);
}
