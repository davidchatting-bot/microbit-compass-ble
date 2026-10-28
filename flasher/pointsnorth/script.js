const WS_SERVER_HOST = "api.davidchatting.com";
// ?server=ws://host:3000/pubgames points the app at another relay (e.g. a local server.js)
const WS_SERVER_URL = new URLSearchParams(location.search).get("server") || `wss://${WS_SERVER_HOST}/pubgames`;

// "hub" devices (iOS app in hub mode, bridging micro:bits) are drawn in the centre of the ring
const ROLE = "spoke";

const msgLog = document.getElementById("msgLog");
const input = document.getElementById("msgInput");
const button = document.getElementById("sendBtn");

const clientId = generateRandomClientId();
let sessionId = null;
let websocket = null;

let qrP5Image = null;
let qrModuleCount = null;

// primary map of known devices
const devicesById = new Map();      // fast lookup by id
const devicesOrdered = [];         // array of device entries sorted by bearing (asc)

/**
 * Upsert a device entry and keep devicesOrdered sorted by bearing.
 * obj must include clientId. Returns the stored entry.
 */
function upsertDevice(obj = {}) {
  const id = obj.clientId;
  if (!id) return null;

  const existing = devicesById.get(id) || {};
  const entry = {
    clientId: id,
    bearing: Object.prototype.hasOwnProperty.call(obj, 'bearing') ? (obj.bearing ?? null) : (existing.bearing ?? null),
    width:   Object.prototype.hasOwnProperty.call(obj, 'width')   ? (obj.width   ?? null) : (existing.width   ?? null),
    height:  Object.prototype.hasOwnProperty.call(obj, 'height')  ? (obj.height  ?? null) : (existing.height  ?? null),
    role:    obj.role || existing.role || 'spoke',
    lastSeen: Date.now(),
    color: existing.color
  };

  // store in map
  devicesById.set(id, entry);

  // remove any existing ordered entry
  const oldIndex = devicesOrdered.findIndex(e => e.clientId === id);
  if (oldIndex !== -1) devicesOrdered.splice(oldIndex, 1);

  // insert in order: devices with numeric bearings first (ascending),
  // entries without finite bearing go to the end in insertion order
  if (entry.bearing === null || !Number.isFinite(entry.bearing)) {
    devicesOrdered.push(entry);
  } else {
    // binary search insertion by bearing
    let lo = 0, hi = devicesOrdered.length;
    while (lo < hi) {
      const mid = (lo + hi) >> 1;
      const mb = devicesOrdered[mid].bearing;
      // treat non-numeric mid bearings as greater so numerics sort earlier
      if (mb === null || !Number.isFinite(mb) || mb > entry.bearing) hi = mid;
      else lo = mid + 1;
    }
    devicesOrdered.splice(lo, 0, entry);
  }

  return entry;
}

function removeDevice(id) {
  devicesById.delete(id);
  const idx = devicesOrdered.findIndex(e => e.clientId === id);
  if (idx !== -1) devicesOrdered.splice(idx, 1);
}

function getDeviceById(id) {
  return devicesById.get(id) || null;
}

function getOrderedDevices() {
  return devicesOrdered;
}

// message buffer (last N)
const _msgBuffer = [];
const _MSG_BUFFER_MAX = 5;

let currentBearing = 0;       // local displayed bearing
const BEARING_THRESHOLD = 1.0;   // degrees - only update/send when change >= threshold

// exposed hook so other UI (QR click) can request compass permission
let requestCompassPermission = null;

// simplest possible Screen Wake Lock usage (no fallbacks)
let simpleWakeLock = null;
let wakeLockRequested = false;

function appendConsole(msg) {
  console.log(msg);
}

function getSessionIdFromUrl() {
  const params = new URLSearchParams(window.location.search);
  return params.get("session");
}

function generateRandomSessionId(length = 8) {
  return Math.random().toString(36).substring(2, 2 + length);
}

function generateRandomClientId(length = 8) {
  return Math.random().toString(36).substring(2, 2 + length);
}

// helper: normalize to [0,360)
function normalizeHeading(h) {
  return ((Number(h) % 360) + 360) % 360;
}

// helper: signed shortest difference between two headings (degrees)
// returns value in range [-180, 180]
function angleDiffDeg(a, b) {
  const toRad = (d) => d * Math.PI / 180;
  const toDeg = (r) => r * 180 / Math.PI;
  return toDeg(Math.atan2(
    Math.sin(toRad(a - b)),
    Math.cos(toRad(a - b))
  ));
}

// helper: current screen rotation angle in degrees (0,90,180,270)
function getScreenOrientationAngle() {
  if (screen && screen.orientation && typeof screen.orientation.angle === 'number') {
    return screen.orientation.angle;
  }
  if (typeof window.orientation === 'number') {
    return window.orientation;
  }
  return 0;
}

function setupQRCode(url, size = 256, minVersion = 1) {
  let svg;
  try {
    svg = kjua({
      render: 'svg',
      text: url,
      minVersion: minVersion,
      size: size,
      fill: '#999',
      back: 'transparent',
      quiet: 1
    });
  } catch (e) {
    appendConsole("⚠️ kjua QR generation failed: " + e);
    return;
  }

  try {
    const svgString = new XMLSerializer().serializeToString(svg);
    const b64 = btoa(unescape(encodeURIComponent(svgString)));
    const dataUrl = 'data:image/svg+xml;base64,' + b64;

    if (typeof loadImage === 'function') {
      loadImage(dataUrl, (img) => {
        qrP5Image = img;
      }, () => {
        appendConsole("⚠️ Failed to load QR as p5 image");
      });
    } else {
      qrP5Image = null;
      appendConsole("⚠️ p5 loadImage not available");
    }
  } catch (e) {
    appendConsole("⚠️ Error converting QR SVG to image: " + e);
  }

  return moduleCountForQRCodeVersion(minVersion);
}

// make websocket global (already declared near top)
// let websocket = null;

// replace send(ws, json) -> send(json) using global websocket
function send(json) {
  const payload = Object.assign({}, json);
  payload.clientId = payload.clientId || clientId;
  payload.sessionId = payload.sessionId || sessionId;

  if (!websocket || websocket.readyState !== WebSocket.OPEN) {
    appendConsole('⚠️ WebSocket not open — cannot send');
    return false;
  }

  try {
    websocket.send(JSON.stringify(payload));
    console.log("Sent message:", payload);
    return true;
  } catch (err) {
    appendConsole('⚠️ send failed: ' + err);
    return false;
  }
}

// keep devicesOrdered in sync by using upsertDevice
const updateDevice = (obj) => {
  if (!obj || !obj.clientId) return null;
  return upsertDevice(obj);
};

    const handleClientInfo = (obj) => {
      updateDevice(obj);
      appendConsole(`📨 [${obj.clientId}] info w=${obj.width ?? 'n/a'} h=${obj.height ?? 'n/a'}`);

      console.log("handleClientInfo", obj, websocket);
      if (obj.targetClientId == null) {
        const reply = {
          type: "client_info",
          width: window.innerWidth,
          height: window.innerHeight,
          bearing: (devicesById.get(clientId) || {}).bearing ?? null,
          role: ROLE,
          targetClientId: obj.clientId
        };
        send(reply);
      }
    };

    const handleCompass = (obj) => {
      if (!obj || !obj.clientId) return;
      const id = obj.clientId;
      // upsertDevice will store bearing/size and keep the ordered list
      const entry = upsertDevice({ clientId: id, bearing: (Number.isFinite(obj.bearing) ? Number(obj.bearing) : null), width: obj.width, height: obj.height, role: obj.role });
      appendConsole(`📨 [${id}] 🧭 ${entry.bearing !== null ? entry.bearing.toFixed(1) : 'n/a'}°`);
    };

    // handle disconnect notifications from server/peers
    const handleDisconnect = (obj) => {
      const id = obj.clientId || null;
      if (devicesById.has(id)) {
        removeDevice(id);
        appendConsole(`❌ Peer disconnected: ${id}`);
      } else {
        appendConsole(`❌ Disconnect for unknown peer: ${id}`);
      }
    };

    const handleMessage = (obj) => {
      console.log("handleMessage", obj);
      // visual cue for incoming message
      flashScreen(140, '#ffffff'); // white flash, adjust duration/color as desired

      // existing message handling behavior (keep or extend)
      // e.g. show in UI/log
      if (obj && obj.text) {
        appendConsole(`💬 [${obj.clientId || 'peer'}] ${obj.text}`);
      }
    };

    const parseMessage = (obj) => {
      if (!obj || typeof obj !== 'object') return;

      if (obj.type === 'client_info') { handleClientInfo(obj); return; }
      if (obj.type === 'message') { handleMessage(obj); return; }
      if (obj.type === 'compass') { handleCompass(obj); return; }
      if (obj.type === 'disconnect') { handleDisconnect(obj); return; }
    };

function setupWebSocket() {
  const ws = new WebSocket(WS_SERVER_URL);
  // assign to global immediately
  websocket = ws;

  ws.onopen = () => {
    appendConsole("✅ Connected to server");
    // use new send() which uses global websocket
    send({
      type: "client_info",
      width: window.innerWidth,
      height: window.innerHeight,
      role: ROLE
    });

    // register this client as the local device inside the devices map
    upsertDevice({
      clientId,
      width: window.innerWidth,
      height: window.innerHeight,
      role: ROLE,
      bearing: Number.isFinite(currentBearing) ? currentBearing : null,
      lastSeen: Date.now(),
      color: (typeof colorForClientId === 'function') ? colorForClientId(clientId) : undefined
    });
  };

  ws.onmessage = (event) => {
    let payload;
    try {
      payload = JSON.parse(event.data);
      //ved payload:", payload);

      if (Array.isArray(payload)) {
        for (const item of payload) {
          try { parseMessage(item); } catch (e) {}
        }
      } else {
        parseMessage(payload);
      }
    } 
    catch (e) {
      appendConsole("📨 " + event.data);
      return;
    }
  };

  ws.onclose = () => appendConsole("❌ Disconnected from server");
  return ws;
}

function setupSendButton() {
  if (!button) return;
  button.onclick = () => {
    /*
    if (isConnected()) {
      websocket.send(JSON.stringify({
        clientId,
        text: input ? input.value : ""
      }));
      appendConsole("➡️ Sent: " + (input ? input.value : ""));
      if (input) input.value = "";
    } else {
      appendConsole("⚠️ WebSocket not open");
    }
    */
  };
}

function setupCompass() {
  function sendCompassBearing(alpha) {
    currentBearing = Number(normalizeHeading(alpha).toFixed(1));
    updateDevice({ clientId, bearing: currentBearing });

    send({
      type: 'compass',
      bearing: currentBearing,
      width: window.innerWidth,
      height: window.innerHeight,
      role: ROLE
    });
    appendConsole(`🧭 Bearing sent: ${currentBearing}°`);
  }

  // single handler reference so we don't accidentally add multiple listeners
  let orientationHandler = null;
  let installed = false;

  // interval id for periodic sending
  let compassInterval = null;

  function startCompassInterval() {
    if (compassInterval) return;
    compassInterval = setInterval(() => {
      if (currentBearing !== null) {
        // reuse the existing sender so throttling/rounding logic is consistent
        sendCompassBearing(currentBearing);
      }
    }, 1000);
  }

  function stopCompassInterval() {
    if (!compassInterval) return;
    clearInterval(compassInterval);
    compassInterval = null;
  }

  function installOrientationListener() {
    if (orientationHandler) return; // already created
    orientationHandler = (event) => {
      let heading = null;

      if (event.webkitCompassHeading !== undefined && event.webkitCompassAccuracy !== undefined) {
        heading = event.webkitCompassHeading;
      } else if (event.alpha !== null) {
        const alpha = Number(event.alpha);
        const screenAngle = normalizeHeading(getScreenOrientationAngle());
        heading = normalizeHeading(360 - alpha - screenAngle);
      }

      if (heading === null || Number.isNaN(heading)) return;

      if (currentBearing === null || Math.abs(heading - currentBearing) >= BEARING_THRESHOLD) {
        sendCompassBearing(heading);
      }
    };

    window.addEventListener("deviceorientation", orientationHandler, true);
    window.addEventListener("deviceorientationabsolute", orientationHandler, true);
    installed = true;

    // start periodic sender (every 1s)
    //startCompassInterval();
  }

  function uninstallOrientationListener() {
    if (!orientationHandler) return;
    window.removeEventListener("deviceorientation", orientationHandler, true);
    window.removeEventListener("deviceorientationabsolute", orientationHandler, true);
    orientationHandler = null;
    installed = false;
    stopCompassInterval();
  }

  const grantAndInstall = async () => {
    if (installed) {
      return;
    }
    try {
      if (typeof DeviceOrientationEvent.requestPermission === 'function') {
        const response = await DeviceOrientationEvent.requestPermission();
        if (response !== 'granted') {
          appendConsole('❌ Permission denied');
          return;
        }
      }
      // ensure listeners are actually installed after permission
      installOrientationListener();
      appendConsole('🧭 Compass enabled');

      const btn = document.getElementById('enableCompassBtn');
      if (btn) btn.style.display = 'none';
    } catch (err) {
      appendConsole('❌ Error requesting permission: ' + err);
    }
  };

  // expose the grant function so other UI (QR click) can trigger it
  requestCompassPermission = grantAndInstall;

  // ensure periodic sender is stopped when page unloads
  window.addEventListener('pagehide', stopCompassInterval);
  window.addEventListener('beforeunload', stopCompassInterval);
  // optional: allow external code to uninstall if needed
  // return an object if caller wants to uninstall: return { uninstall: uninstallOrientationListener };
}

// Call this from a user gesture (e.g. button click). Returns after attempt.
async function requestWakeLockSimple() {
  if (wakeLockRequested) return;
  wakeLockRequested = true;

  try {
    if ('wakeLock' in navigator && typeof navigator.wakeLock.request === 'function') {
      simpleWakeLock = await navigator.wakeLock.request('screen');
      simpleWakeLock.addEventListener('release', () => {
        simpleWakeLock = null;
        wakeLockRequested = false;
        appendConsole('🛑 Wake Lock released by UA');
      });
      appendConsole('🔆 Wake Lock acquired');
    } else {
      appendConsole('⚠️ Wake Lock API not supported');
      wakeLockRequested = false;
    }
  } catch (err) {
    wakeLockRequested = false;
    appendConsole('⚠️ Wake Lock request failed: ' + err);
  }
}

// Release if held
async function releaseWakeLockSimple() {
  if (!simpleWakeLock) return;
  try {
    await simpleWakeLock.release();
    simpleWakeLock = null;
    wakeLockRequested = false;
    appendConsole('🛑 Wake Lock released');
  } catch (err) {
    appendConsole('⚠️ Failed to release Wake Lock: ' + err);
  }
}

// Re-acquire after visibilitychange if it was requested earlier (required for some browsers)
document.addEventListener('visibilitychange', async () => {
  if (document.visibilityState === 'visible' && wakeLockRequested && !simpleWakeLock) {
    await requestWakeLockSimple();
  }
});

// hit test helper for centered QR (draw size must match draw())
function _qrHitTest(x, y) {
    const qrDrawSize = 128; // keep in sync with draw()
    if (!qrP5Image || qrDrawSize <= 0) return false;
    const cx = width / 2;
    const cy = height / 2;
    const left = cx - qrDrawSize / 2;
    const top = cy - qrDrawSize / 2;
    return x >= left && x <= left + qrDrawSize && y >= top && y <= top + qrDrawSize;
}

function moduleCountForQRCodeVersion(version) {
  const v = Number(version);
  if (!Number.isInteger(v) || v < 1 || v > 40) return null;
  return 17 + 4 * v;
}

// simple swipe detection (works on iPhone/Android)
// usage: implement onSwipeLeft() and onSwipeRight() to react
let _swStartX = null;
let _swStartY = null;
let _swStartT = 0;
const SWIPE_MIN_DISTANCE = 50;   // px
const SWIPE_MAX_Y_DELTA = 80;   // px vertical tolerance
const SWIPE_MAX_TIME = 500;     // ms
const TAP_MAX_DISTANCE = 12;    // px movement tolerance for a tap
const TAP_MAX_TIME = 500;       // ms

function isHub(v) {
  return Boolean(v && v.role === 'hub');
}

function firstHub() {
  for (const v of devicesById.values()) if (isHub(v) && typeof v.bearing === 'number') return v;
  return null;
}

// a hub is drawn in the centre, scaled so its corners stay inside the inner circle
function hubScale(v, layout) {
  const w = (Number.isFinite(v.width) && v.width > 0) ? v.width : 100;
  const h = (Number.isFinite(v.height) && v.height > 0) ? v.height : 100;
  return { w, h, s: (layout.innerRadius * 2 * 0.95) / Math.hypot(w, h) };
}

// hit-test a screen point against every drawn device rect, using the same
// transform math as draw(). Returns the clientId under the point, or null.
function hitTestDevices(px, py) {
  const layout = _computeCompassLayout(width, height);
  const lx = px - layout.cx;
  const ly = py - layout.cy;

  let hit = null;
  devicesById.forEach((v, id) => {
    if (hit || !v || typeof v.bearing !== 'number') return;

    if (isHub(v)) {
      const { w, h, s } = hubScale(v, layout);
      const theta = radians((Number.isFinite(currentBearing) ? -currentBearing : 0) + v.bearing);
      const rx = lx * Math.cos(theta) + ly * Math.sin(theta);
      const ry = -lx * Math.sin(theta) + ly * Math.cos(theta);
      if (Math.abs(rx / s) <= w / 2 && Math.abs(ry / s) <= h / 2) hit = id;
      return;
    }

    const peerW = (Number.isFinite(v.width) && v.width > 0) ? v.width : 100;
    const peerH = (Number.isFinite(v.height) && v.height > 0) ? v.height : 100;
    const maxPeerWH = Math.max(peerW, peerH);
    const sPeer = Math.min(layout.deviceScale, layout.maxDim / maxPeerWH);
    const rectH = peerH * sPeer;
    const radialCenter = layout.basePos + (rectH * 0.5);

    const thetaDeg = (Number.isFinite(currentBearing) ? -currentBearing : 0) + v.bearing + 180;
    const theta = radians(thetaDeg);
    const cosT = Math.cos(theta), sinT = Math.sin(theta);

    // inverse-rotate the tap point, then undo the translate and scale
    const rx = lx * cosT + ly * sinT;
    const ry = -lx * sinT + ly * cosT;
    const sx = rx / sPeer;
    const sy = (ry + radialCenter) / sPeer;

    if (Math.abs(sx) <= peerW / 2 && Math.abs(sy) <= peerH / 2) {
      hit = id;
    }
  });

  return hit;
}

function handleDeviceTap(x, y) {
  const targetId = hitTestDevices(x, y);
  if (!targetId) return;
  appendConsole(`👆 Tapped device: ${targetId}`);
  send({
    type: 'message',
    text: 'Tapped!',
    targetClientId: targetId
  });
}

function onSwipeLeft() {
  const target = getDeviceLeft();
  appendConsole('↩️ Swipe left', target);
  // no neighbour: without a target the relay would send it to everyone
  if (!target) return;
  send({
    type: 'message',
    text: 'Swiped!',
    targetClientId: target
  });
}

function onSwipeRight() {
  const target = getDeviceRight();
  appendConsole('➡️ Swipe right', target);
  // no neighbour: without a target the relay would send it to everyone
  if (!target) return;
  send({
    type: 'message',
    text: 'Swiped!',
    targetClientId: target
  });
}

function _handleSwipeStart(startX, startY) {
  _swStartX = startX;
  _swStartY = startY;
  _swStartT = Date.now();
}

function _handleSwipeEnd(endX, endY) {
  if (_swStartX == null) return;

  const dx = endX - _swStartX;
  const dy = endY - _swStartY;
  const dt = Date.now() - _swStartT;
  _swStartX = _swStartY = null;
  _swStartT = 0;

  if (dt <= SWIPE_MAX_TIME && Math.abs(dy) <= SWIPE_MAX_Y_DELTA && Math.abs(dx) >= SWIPE_MIN_DISTANCE) {
    if (dx > 0) onSwipeLeft();
    else onSwipeRight();
    return;
  }

  // not a swipe — treat as a tap if the touch/click barely moved
  if (dt <= TAP_MAX_TIME && Math.hypot(dx, dy) <= TAP_MAX_DISTANCE) {
    handleDeviceTap(endX, endY);
  }
}

function mousePressed() {
  // ignore emulated mouse events when an active touch is present
  if (typeof touches !== 'undefined' && touches.length) return;
  _handleSwipeStart(mouseX, mouseY);
}

function mouseReleased() {
  if (typeof touches !== 'undefined' && touches.length) return;
  _handleSwipeEnd(mouseX, mouseY);
}

function touchStarted() {
  const t = (typeof touches !== 'undefined' && touches.length) ? touches[0] : null;
  const tx = t ? t.x : mouseX;
  const ty = t ? t.y : mouseY;
  _handleSwipeStart(tx, ty);
  return false; // prevent default scrolling while interacting
}

function touchEnded() {
  // prefer native changedTouches for reliable end coords
  // p5's touches[] may be empty here; fall back to mouse coords
  const active = (typeof touches !== 'undefined' && touches.length) ? touches[0] : null;
  if (active) {
    _handleSwipeEnd(active.x, active.y);
  } else {
    _handleSwipeEnd(mouseX, mouseY);
  }
  return false;
}

// Optional: if you prefer native listener for the final coordinates:
// document.addEventListener('touchend', (ev) => {
//   if (!ev.changedTouches || ev.changedTouches.length === 0) return;
//   const t = ev.changedTouches[0];
//   _handleSwipeEnd(t.clientX, t.clientY);
// }, { passive: true });
// }

// p5.js setup and draw
function setup() {
  // make the p5 canvas fill the window
  createCanvas(windowWidth, windowHeight);

  let sessionUrl = location.href;
  sessionId = getSessionIdFromUrl();
  if (!sessionId) {
    sessionId = generateRandomSessionId();
    const url = new URL(location.href);
    url.searchParams.set("session", sessionId);
    sessionUrl = url.toString();
    history.replaceState(null, "", sessionUrl);
  }

  qrModuleCount = setupQRCode(sessionUrl, 256, 4);

  websocket = setupWebSocket();
  setupSendButton();      // no param — uses global websocket
  setupCompass();         // no param — uses global websocket
}

function _computeCompassLayout(width, height) {
  const cx = width / 2;
  const cy = height / 2;
  const qrDrawSize = qrP5Image ? Math.min(width, height) * 0.3 : 0;
  const qrModuleCountLocal = qrModuleCount || 21;
  const qrModulePx = qrDrawSize ? (qrDrawSize / qrModuleCountLocal) : 0;
  const innerRadius = qrP5Image ? (qrDrawSize / Math.SQRT2) : 75;
  const outerRadius = innerRadius * 2;
  const margin = outerRadius - innerRadius;
  const tipPos = innerRadius + margin * 0.85;
  const basePos = innerRadius + margin * 0.25;

  // drawing constants used by both draw and hit-testing
  const deviceScale = 0.15;
  const maxDim = Math.max(1, margin * 0.9);
  const desiredStroke = 2;

  return { cx, cy, qrDrawSize, qrModulePx, innerRadius, outerRadius, margin, tipPos, basePos, deviceScale, maxDim, desiredStroke };
}

function draw() {
  // black background to match page
  background(0);

  const layout = _computeCompassLayout(width, height);
  translate(layout.cx, layout.cy);

  push();
    noFill();
    stroke(255);
    strokeWeight(layout.desiredStroke); // use device outline weight
    // draw so stroke is centered on outerRadius: use circle diameter = (outerRadius * 2)
    circle(0, 0, layout.outerRadius * 2);
  pop();

  // compute margin region where arrows should live (inside ring area)
  const arrowWidth = Math.max(6, layout.margin * 0.18);

  // center origin for compass drawing and rotate frame so north line is relative
  push();
    if (Number.isFinite(currentBearing)) {
      rotate(radians(-currentBearing)); // NEVER remove this
    }

    // dotted north line — draw only between the inner and outer radius
    push();
      stroke(255);
      const dashLen = layout.qrModulePx || 2;
      strokeWeight(layout.desiredStroke);
      drawingContext.setLineDash([dashLen, dashLen*2]);
      line(0, -layout.innerRadius, 0, -layout.outerRadius);
      drawingContext.setLineDash([]);
    pop();

    push();
      // Remote peers: same transform strategy per-peer
      devicesById.forEach((v, id) => {
        if (!v || typeof v.bearing !== 'number') return;

        if (isHub(v)) {
          const { w, h, s } = hubScale(v, layout);
          push();
            rotate(radians(v.bearing));
            scale(s);
            fill(0);
            stroke(255);
            strokeWeight(layout.desiredStroke / s);
            rectMode(CENTER);
            rect(0, 0, w, h, 80);
          pop();
          return;
        }

        const peerW = (Number.isFinite(v.width) && v.width > 0) ? v.width : 100;
        const peerH = (Number.isFinite(v.height) && v.height > 0) ? v.height : 100;
        const maxPeerWH = Math.max(peerW, peerH);
        const sPeer = Math.min(layout.deviceScale, layout.maxDim / maxPeerWH);
        const rectH = peerH * sPeer;
        const radialCenter = layout.basePos + (rectH * 0.5);

        push();
          if (id === clientId) {
          }
          rotate(radians(v.bearing));
          rotate(radians(180)); // NEVER remove this

          fill(0);
          stroke(255);
          strokeWeight(Math.max(0.4, (layout.qrModulePx || 1) / sPeer));
          rectMode(CENTER);

          push();
            translate(0, -radialCenter);
            scale(sPeer);
            rect(0, 0, peerW, peerH, 80);
          pop();
        pop();
      });
    pop();

  pop(); // end compass transform

  // after translate(layout.cx, layout.cy); and after drawing the ring, draw the QR:
  // (place this where you want the QR centered inside the compass)
  // with a hub in the centre, the QR sits on the hub's screen instead: upright, and as big as
  // fits inside the hub's outline at its current angle
  if (qrP5Image) {
    const hub = firstHub();
    let qrSize = layout.qrDrawSize;
    push();
      if (hub) {
        const { w, h, s } = hubScale(hub, layout);
        const t = radians(hub.bearing - (Number.isFinite(currentBearing) ? currentBearing : 0));
        qrSize = Math.min(w, h) * s * 0.8 / (Math.abs(Math.cos(t)) + Math.abs(Math.sin(t)));
      }
      imageMode(CENTER);
      noSmooth();               // keep QR sharp
      image(qrP5Image, 0, 0, qrSize, qrSize);
    pop();
  }
}

// resize canvas when the window changes size
function windowResized() {
  resizeCanvas(windowWidth, windowHeight);
}

// wire external DOM control (outside p5) to requestCompassPermission
document.addEventListener('DOMContentLoaded', () => {
  const btn = document.getElementById('enableCompassBtn');
  if (!btn) return;
  console.log("Found Enable Compass button");
  // style overlay so it sits over the p5 canvas (optional tweaks in CSS)
  btn.style.position = 'fixed';
  btn.style.top = '12px';
  btn.style.left = '12px';
  btn.style.zIndex = '9999';

  const handler = async (ev) => {
    console.log("Enable Compass button clicked/touched");
    ev.preventDefault();
    if (typeof requestCompassPermission === 'function') {
      await requestCompassPermission();
    } else {
      appendConsole('⚠️ Compass setup not ready');
    }
  };
  btn.addEventListener('click', handler, { passive: false });
  btn.addEventListener('touchend', handler, { passive: false });
});

// ensure the Enable Compass button sits above the p5 canvas and is clickable
window.addEventListener('load', () => {
  const btn = document.getElementById('enableCompassBtn');
  if (!btn) return;

  // ensure fixed positioning and high stacking order
  btn.style.position = 'fixed';
  btn.style.top = '12px';
  btn.style.left = '12px';
  btn.style.zIndex = '100000';
  btn.style.pointerEvents = 'auto';

  // move the button to the end of <body> so it's after the canvas in DOM order
  // (keeps visual order consistent across browsers)
  document.body.appendChild(btn);

  // if p5 has already created a canvas, lower its z-index so the button receives clicks
  const canv = document.querySelector('canvas');
  if (canv) {
    canv.style.zIndex = '0';
    canv.style.pointerEvents = 'auto'; // keep canvas interactive for hit-testing
  }
});

// helper to check WebSocket connection state
function isConnected(ws = websocket) {
  return Boolean(ws && ws.readyState === WebSocket.OPEN);
}

/**
 * Return the clientId of the device `offset` positions away from `startId`
 * around the ordered device circle.
 * - offset > 0 -> move right/clockwise
 * - offset < 0 -> move left/counter-clockwise
 * Returns null if there are no devices.
 */
function getDeviceIdOffset(startId = clientId, offset = 1) {
  // only devices drawn round the circle: with a bearing, and not hubs, which sit in the centre
  const ordered = devicesOrdered.filter(e => !isHub(e) && Number.isFinite(e.bearing)).map(e => e.clientId);

  // a device that isn't round the circle has no neighbours
  const startIndex = ordered.indexOf(startId);
  if (ordered.length < 2 || startIndex === -1) return null;

  const len = ordered.length;
  const target = ((startIndex + offset) % len + len) % len;
  return ordered[target] || null;
}

// convenience helpers
function getDeviceRight(startId = clientId, n = 1) { return getDeviceIdOffset(startId, Math.abs(n)); }
function getDeviceLeft(startId = clientId, n = 1)  { return getDeviceIdOffset(startId, -Math.abs(n)); }

// one-shot screen flash overlay (creates element once and reuses it)
function flashScreen(duration = 150, color = '#ffffff') {
  let el = document.getElementById('screenFlash');
  if (!el) {
    el = document.createElement('div');
    el.id = 'screenFlash';
    Object.assign(el.style, {
      position: 'fixed',
      inset: '0',
      background: color,
      opacity: '0',
      pointerEvents: 'none',
      zIndex: '1000000',
      transition: 'opacity 220ms ease'
    });
    document.body.appendChild(el);
  }

  // trigger flash
  el.style.transition = 'none';
  el.style.opacity = '0';
  // force style flush
  void el.offsetWidth;
  el.style.transition = 'opacity 220ms ease';
  el.style.opacity = '1';

  setTimeout(() => {
    el.style.opacity = '0';
  }, duration);
}