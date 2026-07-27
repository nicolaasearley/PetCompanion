import { existsSync } from "node:fs";
import { spawnSync } from "node:child_process";

const bundledCandidates = [
  process.env["PETCOMPANION_TSC_JS"],
  "/Applications/Unity/Hub/Editor/6000.5.4f1/PlaybackEngines/WebGLSupport/BuildTools/Emscripten/emscripten/node_modules/typescript/lib/tsc.js",
  "/Applications/Visual Studio Code.app/Contents/Resources/app/extensions/node_modules/typescript/lib/tsc.js",
  "/Applications/Cursor.app/Contents/Resources/app/extensions/node_modules/typescript/lib/tsc.js",
].filter(Boolean);

let result = spawnSync("tsc", ["--noEmit"], { stdio: "inherit" });
if (result.error?.code === "ENOENT") {
  const bundled = bundledCandidates.find((candidate) => existsSync(candidate));
  if (!bundled) {
    console.error(
      "TypeScript is not installed. Set PETCOMPANION_TSC_JS to a local typescript/lib/tsc.js path.",
    );
    process.exit(1);
  }
  result = spawnSync(process.execPath, [bundled, "--noEmit"], { stdio: "inherit" });
}
process.exit(result.status ?? 1);
