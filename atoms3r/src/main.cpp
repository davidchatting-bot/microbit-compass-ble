// Compass bearing and button over BLE, speaking the same protocol as the micro:bit
// Compass BLE firmware (github.com/davidchatting-bot/microbit-compass-ble), so its compass
// app can add this board too. The name starts "BBC micro:bit" because the app's device
// picker filters on that prefix.
#include <M5Unified.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLE2902.h>

#define MAGNETOMETER_SERVICE    "e95df2d8-251d-470a-a062-fa1922dfa9a8"
#define BEARING_CHARACTERISTIC  "e95d9715-251d-470a-a062-fa1922dfa9a8"  // uint16 LE, degrees
#define BUTTON_SERVICE          "e95d9882-251d-470a-a062-fa1922dfa9a8"
#define BUTTON_A_CHARACTERISTIC "e95dda90-251d-470a-a062-fa1922dfa9a8"  // uint8: 0 released, 1 pressed, 2 long press
#define BUTTON_B_CHARACTERISTIC "e95dda91-251d-470a-a062-fa1922dfa9a8"  // always 0: the Atom has one button
#define LONG_PRESS_MS 1000

// micro:bit-style LED colours, as in the compass app.
const uint16_t LED_ON = lgfx::color565(0xff, 0x3b, 0x30);
const uint16_t LED_OFF = lgfx::color565(0x2a, 0x13, 0x12);
const uint8_t TICK[5] = {0b00000, 0b00001, 0b00010, 0b10100, 0b01000};

M5Canvas canvas(&M5.Display);
BLECharacteristic *bearingChar, *buttonAChar;
volatile bool connected = false;

class ServerCallbacks : public BLEServerCallbacks {
  void onConnect(BLEServer*) override { connected = true; }
  void onDisconnect(BLEServer*) override {
    connected = false;
    BLEDevice::startAdvertising();
  }
};

BLECharacteristic* addNotifying(BLEService* service, const char* uuid) {
  auto c = service->createCharacteristic(uuid, BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_NOTIFY);
  c->addDescriptor(new BLE2902());
  return c;
}

void setupBle() {
  BLEDevice::init("BBC micro:bit [atom]");
  BLEServer* server = BLEDevice::createServer();
  server->setCallbacks(new ServerCallbacks());

  BLEService* magnetometer = server->createService(MAGNETOMETER_SERVICE);
  bearingChar = addNotifying(magnetometer, BEARING_CHARACTERISTIC);
  magnetometer->start();

  BLEService* buttons = server->createService(BUTTON_SERVICE);
  buttonAChar = addNotifying(buttons, BUTTON_A_CHARACTERISTIC);
  uint8_t released = 0;
  addNotifying(buttons, BUTTON_B_CHARACTERISTIC)->setValue(&released, 1);
  buttonAChar->setValue(&released, 1);
  buttons->start();

  BLEDevice::startAdvertising();
}

// Draws a 5x5 LED screen; one byte per row (top first), bit 4 = leftmost LED.
void drawLeds(const uint8_t rows[5]) {
  int pitch = canvas.width() / 5, margin = (canvas.width() - pitch * 5) / 2;
  canvas.fillSprite(TFT_BLACK);
  for (int y = 0; y < 5; y++)
    for (int x = 0; x < 5; x++) {
      int cx = margin + x * pitch + pitch / 2, cy = margin + y * pitch + pitch / 2;
      canvas.fillRoundRect(cx - 3, cy - 5, 6, 10, 2, (rows[y] >> (4 - x)) & 1 ? LED_ON : LED_OFF);
    }
  canvas.pushSprite(0, 0);
}

// Running min/max for hard-iron calibration: tumble the device in all directions to calibrate.
float minM[3] = {1e9, 1e9, 1e9}, maxM[3] = {-1e9, -1e9, -1e9};

// Reads the compass, giving the bearing of the screen's top edge (degrees clockwise from
// north) and north as seen on the screen (x right, y down), whatever the tilt.
bool readCompass(int& bearing, float& northX, float& northY) {
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

  bearing = ((int)lround(atan2(e[1] / eLen, n[1] / nLen) * 180 / PI) + 360) % 360;
  float len = sqrt(n[0] * n[0] + n[1] * n[1]);
  if (len > 0) {
    northX = n[0] / len;
    northY = -n[1] / len;
  }
  return true;
}

// While nothing is connected, a single pixel races across the screen towards north, as on
// the micro:bit. It moves round a virtual 7x7 grid that wraps at its edges: the 5x5 screen
// (cells 1-5) plus a hidden one-pixel border, so a pixel leaving the screen comes back in
// from the opposite side, at a random spot across its direction of travel.
// Positions are in hundredths of a cell.
int x = 300, y = 300, dx = 0, dy = -100, frame = 0, lastSpot = -1;

// The centre of a random screen cell (never the same one twice running), as a position.
int randomSpot() {
  int spot;
  do spot = random(5); while (spot == lastSpot);
  lastSpot = spot;
  return (spot + 1) * 100 + 50;
}

void setup() {
  M5.begin();
  canvas.createSprite(M5.Display.width(), M5.Display.height());
  setupBle();
}

void loop() {
  M5.update();

  uint8_t button = M5.BtnA.pressedFor(LONG_PRESS_MS) ? 2 : M5.BtnA.isPressed() ? 1 : 0;
  static uint8_t lastButton = 0;
  if (button != lastButton) {
    lastButton = button;
    buttonAChar->setValue(&button, 1);
    if (connected) buttonAChar->notify();
  }

  // The compass changes slowly, so only read it every 5th frame (about every 110 ms).
  int bearing;
  float northX, northY;
  if (frame % 5 == 0 && readCompass(bearing, northX, northY)) {
    static int lastBearing = -1;
    if (bearing != lastBearing) {
      lastBearing = bearing;
      uint8_t value[2] = {(uint8_t)(bearing & 0xff), (uint8_t)(bearing >> 8)};
      bearingChar->setValue(value, 2);
      if (connected) bearingChar->notify();
    }
    dx = lround(northX * 100);
    dy = lround(northY * 100);
  }
  frame++;

  if (connected) {
    drawLeds(TICK);
  } else {
    int nx = (x + dx + 700) % 700, ny = (y + dy + 700) % 700;
    // A big jump means it just wrapped round through the hidden border.
    if (abs(ny - y) > 350) nx = randomSpot();
    else if (abs(nx - x) > 350) ny = randomSpot();
    x = nx;
    y = ny;
    uint8_t rows[5] = {0};
    int col = x / 100 - 1, row = y / 100 - 1;
    if (col >= 0 && col < 5 && row >= 0 && row < 5) rows[row] = 1 << (4 - col);  // hidden in the border
    drawLeds(rows);
  }
  delay(22);
}
