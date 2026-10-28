// Bundles the WebUSB flasher and copies in the freshly built hex: flasher/ + built/binary.hex -> _site/
import { build } from "esbuild";
import { copyFileSync, cpSync, mkdirSync, writeFileSync } from "node:fs";
import { execSync } from "node:child_process";

mkdirSync("_site", { recursive: true });
await build({
  entryPoints: ["flasher/flasher.js"],
  bundle: true,
  minify: true,
  format: "iife",
  target: "es2020",
  outfile: "_site/flasher.js",
});
copyFileSync("flasher/index.html", "_site/index.html");
copyFileSync("flasher/compass.html", "_site/compass.html"); // redirects to compass/
cpSync("flasher/compass", "_site/compass", { recursive: true });
cpSync("flasher/pointsnorth", "_site/pointsnorth", { recursive: true });
copyFileSync("built/binary.hex", "_site/binary.hex");

let sha = process.env.GITHUB_SHA;
try { sha ??= execSync("git rev-parse HEAD", { stdio: ["ignore", "pipe", "ignore"] }).toString().trim(); } catch {}
writeFileSync("_site/build.txt", `Built ${new Date().toISOString().slice(0, 16).replace("T", " ")} UTC` + (sha ? ` from ${sha.slice(0, 7)}` : ""));
