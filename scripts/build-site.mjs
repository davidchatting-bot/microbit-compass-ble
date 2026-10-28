// Builds the GitHub Pages site from web/ -> _site/: Points North at the root, the micro:bit
// flasher (bundled, with the freshly built hex) at flasher/, and the compass page at compass/.
import { build } from "esbuild";
import { copyFileSync, cpSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { execSync } from "node:child_process";

rmSync("_site", { recursive: true, force: true });
mkdirSync("_site/flasher", { recursive: true });
cpSync("web", "_site", { recursive: true, filter: (path) => !path.endsWith("flasher/flasher.js") });
await build({
  entryPoints: ["web/flasher/flasher.js"],
  bundle: true,
  minify: true,
  format: "iife",
  target: "es2020",
  outfile: "_site/flasher/flasher.js",
});
copyFileSync("built/binary.hex", "_site/flasher/binary.hex");

let sha = process.env.GITHUB_SHA;
try { sha ??= execSync("git rev-parse HEAD", { stdio: ["ignore", "pipe", "ignore"] }).toString().trim(); } catch {}
writeFileSync("_site/build.txt", `Built ${new Date().toISOString().slice(0, 16).replace("T", " ")} UTC` + (sha ? ` from ${sha.slice(0, 7)}` : ""));
