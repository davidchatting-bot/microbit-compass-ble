import { createUSBConnection } from "@microbit/microbit-connection/usb";
import { createUniversalHexFlashDataSource } from "@microbit/microbit-connection/universal-hex";
import { DeviceError } from "@microbit/microbit-connection";

const button = document.getElementById("flash");
const progressBar = document.getElementById("progress");
const statusEl = document.getElementById("status");

const ERRORS = {
  unsupported: "This browser doesn't support WebUSB. Use Chrome or Edge on desktop or Android.",
  "device-in-use": "The micro:bit is in use by another tab or app. Close it and try again.",
  "firmware-update-required": "This micro:bit needs a firmware update: see https://microbit.org/get-started/user-guide/firmware/",
  "device-disconnected": "The micro:bit was disconnected. Plug it back in and try again.",
  timeout: "The micro:bit stopped responding. Unplug it, plug it back in and try again.",
};

const STAGES = {
  Initializing: "Starting…",
  FindingDevice: "Choose your micro:bit…",
  Connecting: "Connecting…",
  PartialFlashing: "Flashing (only changed parts)…",
  FullFlashing: "Flashing…",
};

function setStatus(text, kind = "") {
  statusEl.textContent = text;
  statusEl.className = kind;
}

const hexPromise = fetch("binary.hex").then((r) => {
  if (!r.ok) throw new Error(`couldn't load binary.hex (${r.status})`);
  return r.text();
});

fetch("../build.txt").then((r) => r.ok && r.text()).then((t) => {
  if (t) document.getElementById("build").textContent = t;
}).catch(() => {});

if (!navigator.usb) {
  setStatus(ERRORS.unsupported, "error");
} else {
  hexPromise.then(() => (button.disabled = false), (e) => setStatus(e.message, "error"));
}

const usb = createUSBConnection();

button.addEventListener("click", async () => {
  button.disabled = true;
  progressBar.hidden = true;
  setStatus("");
  try {
    const hex = await hexPromise;
    await usb.flash(createUniversalHexFlashDataSource(hex), {
      partial: true,
      progress: (stage, value) => {
        setStatus(STAGES[stage] ?? stage);
        if (value !== undefined) {
          progressBar.hidden = false;
          progressBar.value = value;
        }
      },
    });
    progressBar.value = 1;
    setStatus("Done. Tilt the micro:bit to calibrate the compass if it asks.", "done");
  } catch (e) {
    progressBar.hidden = true;
    if (e instanceof DeviceError && e.code === "no-device-selected") {
      setStatus("");
    } else {
      const msg = e instanceof DeviceError ? ERRORS[e.code] ?? e.message : e.message;
      setStatus(msg, "error");
    }
  } finally {
    button.disabled = false;
  }
});
