// micro:bit Compass
// A full-screen micro:bit LED screen with a single pixel racing towards north, steered by
// this device's compass, just like the Compass BLE micro:bits while they wait for a
// connection. Connected micro:bits appear below, each steered by its own live bearing.

const STEP_MS = 22; // one step per frame of the micro:bit firmware
const LED_ON = "#ff3b30";
const LED_OFF = "#2a1312";
const BOARD = "#151518";
const TEXT = "#c9c9d1";

let heading = null; // this device's compass heading in degrees, null until known
let usingCompass = false;
let message = "Tap Start to use this device's compass";
let phone;
let startButton;

// The pixel moves round a virtual 7x7 grid that wraps at its edges: the 5x5 screen
// (cells 1-5) plus a hidden one-cell border, so on leaving the screen it comes back
// in from the opposite (south) side, at a random spot across its direction of travel.
class NorthPixel {
  constructor() {
    this.x = 3.5;
    this.y = 3.5;
    this.lastSpot = -1;
    this.elapsed = 0;
  }

  randomSpot() {
    let spot = floor(random(5));
    while (spot == this.lastSpot) spot = floor(random(5));
    this.lastSpot = spot;
    return spot + 1.5;
  }

  update(headingDegrees, ms) {
    if (headingDegrees == null) return;
    // North relative to the screen (x right, y down).
    const dx = -sin(radians(headingDegrees));
    const dy = -cos(radians(headingDegrees));
    this.elapsed += min(ms, 500); // don't race to catch up after the tab was hidden
    while (this.elapsed >= STEP_MS) {
      this.elapsed -= STEP_MS;
      let nx = (this.x + dx + 7) % 7;
      let ny = (this.y + dy + 7) % 7;
      // A big jump means it just wrapped round through the hidden border.
      if (abs(ny - this.y) > 3.5) nx = this.randomSpot();
      else if (abs(nx - this.x) > 3.5) ny = this.randomSpot();
      this.x = nx;
      this.y = ny;
    }
  }

  // The lit screen cell, or null while in the hidden border.
  cell() {
    const cx = floor(this.x) - 1;
    const cy = floor(this.y) - 1;
    return cx >= 0 && cx < 5 && cy >= 0 && cy < 5 ? [cx, cy] : null;
  }
}

function setup() {
  createCanvas(windowWidth, windowHeight);
  textFont("system-ui, sans-serif");
  phone = new NorthPixel();

  const controls = createDiv().addClass("controls");
  startButton = createButton("Start").parent(controls).mousePressed(startCompass);
  if (navigator.bluetooth) {
    createButton("Add micro:bit").addClass("secondary").parent(controls).mousePressed(addMicrobit);
  }
}

function draw() {
  background("#0b0b0d");
  phone.update(heading, deltaTime);

  const list = [...boards.values()];
  for (const board of list) {
    board.pixel ??= new NorthPixel();
    board.pixel.update(board.bearing, deltaTime);
  }

  // This device's screen fills the space above any micro:bits.
  const stripHeight = list.length ? min(height * 0.32, 260) : 0;
  const top = 72;
  const size = min(width * 0.86, (height - top - stripHeight) * 0.8);
  const label = heading == null ? message : `${round(heading) % 360}°`;
  drawScreen(phone, width / 2, top + (height - top - stripHeight) / 2 - 16, size, label, heading == null);

  // micro:bits in a row along the bottom.
  const tile = min(stripHeight * 0.62, (width / max(list.length, 1)) * 0.7);
  list.forEach((board, i) => {
    const cx = (width / list.length) * (i + 0.5);
    const cy = height - stripHeight / 2 - 14;
    const status = board.state || (board.bearing == null ? "" : `${board.bearing}°`);
    board.bounds = [cx - tile / 2, cy - tile / 2, tile, tile];
    drawScreen(board.pixel, cx, cy, tile, `${shortName(board.name)}  ${status}`, !!board.state);
  });
}

// A micro:bit-style 5x5 LED screen centred on (cx, cy).
function drawScreen(pixel, cx, cy, size, label, dimmed) {
  const pitch = size / 5;
  const led = pitch * 0.42;
  const lit = pixel.cell();

  push();
  translate(cx - size / 2, cy - size / 2);
  noStroke();
  fill(BOARD);
  rect(-pitch * 0.3, -pitch * 0.3, size + pitch * 0.6, size + pitch * 0.6, pitch * 0.35);

  rectMode(CENTER);
  for (let y = 0; y < 5; y++) {
    for (let x = 0; x < 5; x++) {
      const on = lit && !dimmed && lit[0] == x && lit[1] == y;
      if (on) {
        drawingContext.shadowBlur = led * 1.6;
        drawingContext.shadowColor = LED_ON;
      }
      fill(on ? LED_ON : LED_OFF);
      rect((x + 0.5) * pitch, (y + 0.5) * pitch, led * 0.6, led, led * 0.15);
      drawingContext.shadowBlur = 0;
    }
  }
  pop();

  fill(TEXT);
  noStroke();
  textAlign(CENTER, TOP);
  textSize(constrain(size * 0.07, 12, 28));
  text(label, cx, cy + size / 2 + pitch * 0.5);
}

function shortName(name) {
  // "BBC micro:bit [zavet]" -> "zavet"
  const match = name.match(/\[(.*)\]/);
  return match ? match[1] : name;
}

async function startCompass() {
  // iOS asks for permission, and only in response to a tap.
  if (typeof DeviceOrientationEvent !== "undefined" && typeof DeviceOrientationEvent.requestPermission === "function") {
    try {
      if ((await DeviceOrientationEvent.requestPermission()) !== "granted") {
        message = "Compass permission denied";
        return;
      }
    } catch (e) {
      message = "Couldn't get compass permission";
      return;
    }
  }
  // Android Chrome gives a north-referenced alpha on "deviceorientationabsolute".
  const event = "ondeviceorientationabsolute" in window ? "deviceorientationabsolute" : "deviceorientation";
  window.addEventListener(event, onOrientation);
  startButton.hide();
  message = "Waiting for compass…";
  setTimeout(() => {
    if (!usingCompass) message = "No compass on this device: drag to turn";
  }, 2000);
}

function onOrientation(e) {
  let h = null;
  if (typeof e.webkitCompassHeading === "number") h = e.webkitCompassHeading; // iOS
  else if (e.absolute && e.alpha != null) h = 360 - e.alpha;
  if (h == null) return;
  // Headings are for the top of the device held upright; allow for a rotated screen.
  const screenAngle = screen.orientation?.angle ?? window.orientation ?? 0;
  heading = (h + screenAngle + 360) % 360;
  usingCompass = true;
}

// Without a compass, drag to point north.
function mouseDragged() {
  if (usingCompass) return;
  const north = degrees(atan2(mouseX - width / 2, -(mouseY - height / 2)));
  heading = (360 - north) % 360;
}

// Tap a micro:bit's screen to disconnect it.
function mouseClicked() {
  for (const board of boards.values()) {
    const [x, y, w, h] = board.bounds ?? [];
    if (mouseX >= x && mouseX <= x + w && mouseY >= y && mouseY <= y + h) {
      if (confirm(`Disconnect ${board.name}?`)) removeMicrobit(board);
      return;
    }
  }
}

function windowResized() {
  resizeCanvas(windowWidth, windowHeight);
}
