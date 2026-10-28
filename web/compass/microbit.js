// Web Bluetooth connections to micro:bits running Compass BLE: each board's live bearing
// from the Magnetometer Service's Bearing characteristic (uint16 LE, degrees), and its
// A and B buttons from the Button Service (uint8: 0 released, 1 pressed, 2 long press).

const MAGNETOMETER_SERVICE = "e95df2d8-251d-470a-a062-fa1922dfa9a8";
const BEARING_CHARACTERISTIC = "e95d9715-251d-470a-a062-fa1922dfa9a8";
const BUTTON_SERVICE = "e95d9882-251d-470a-a062-fa1922dfa9a8";
const BUTTON_CHARACTERISTICS = { a: "e95dda90-251d-470a-a062-fa1922dfa9a8", b: "e95dda91-251d-470a-a062-fa1922dfa9a8" };

const boards = new Map(); // device.id -> { device, name, bearing, state, pixel }

function boardFor(device) {
  let board = boards.get(device.id);
  if (board) return board;
  board = { device, name: device.name || "micro:bit", bearing: null, buttons: { a: 0, b: 0 }, state: "Connecting…", pixel: null };
  device.addEventListener("gattserverdisconnected", () => reconnect(board));
  boards.set(device.id, board);
  return board;
}

async function connect(board) {
  board.state = "Connecting…";
  const server = await board.device.gatt.connect();
  const service = await server.getPrimaryService(MAGNETOMETER_SERVICE);
  const bearing = await service.getCharacteristic(BEARING_CHARACTERISTIC);
  bearing.addEventListener("characteristicvaluechanged", (e) => (board.bearing = e.target.value.getUint16(0, true)));
  board.bearing = (await bearing.readValue()).getUint16(0, true);
  await bearing.startNotifications();
  board.state = "";

  // Buttons are optional: older firmware lacks the service, and boards allowed before it
  // was added need re-adding through the picker to grant access to it.
  try {
    const buttons = await server.getPrimaryService(BUTTON_SERVICE);
    for (const [key, uuid] of Object.entries(BUTTON_CHARACTERISTICS)) {
      const button = await buttons.getCharacteristic(uuid);
      button.addEventListener("characteristicvaluechanged", (e) => (board.buttons[key] = e.target.value.getUint8(0)));
      board.buttons[key] = (await button.readValue()).getUint8(0);
      await button.startNotifications();
    }
  } catch {
    board.buttons = null;
  }
}

async function reconnect(board) {
  if (board.reconnecting) return;
  board.reconnecting = true;
  for (let attempt = 0; boards.has(board.device.id) && !board.device.gatt.connected; attempt++) {
    board.state = "Reconnecting…";
    try {
      await connect(board);
    } catch {
      board.state = "Out of range";
      await new Promise((r) => setTimeout(r, Math.min(2000 * 2 ** attempt, 30000)));
    }
  }
  board.reconnecting = false;
}

async function addMicrobit() {
  let device;
  try {
    device = await navigator.bluetooth.requestDevice({
      // The iPhone app advertises the service, but Chrome may know it by the phone's own name.
      filters: [{ namePrefix: "BBC micro:bit" }, { services: [MAGNETOMETER_SERVICE] }],
      optionalServices: [MAGNETOMETER_SERVICE, BUTTON_SERVICE],
    });
  } catch {
    return; // picker cancelled
  }
  const board = boardFor(device);
  if (device.gatt.connected) return;
  try {
    await connect(board);
  } catch (e) {
    board.state = e.name === "NotFoundError" ? "Not running Compass BLE?" : "Couldn't connect";
    reconnect(board);
  }
}

function removeMicrobit(board) {
  boards.delete(board.device.id);
  if (board.device.gatt.connected) board.device.gatt.disconnect();
  board.device.forget?.();
}

// Reconnect to boards this site was already given permission for.
if (navigator.bluetooth?.getDevices) {
  navigator.bluetooth.getDevices().then((devices) => devices.forEach((d) => reconnect(boardFor(d))));
}
