// Builds the per-OS privileged helper and stages it where the Tauri bundler
// expects it. Run automatically by beforeBuildCommand.
//
//   Windows: cargo build --release -p localdns-helper
//            → src-tauri/binaries/localdns-helper-<triple>.exe   (externalBin)
//   Linux:   cargo build --release -p localdns-agentd
//            → referenced directly from target/release by the deb/rpm "files" map
//   macOS:   nothing to stage (mock backend).

import { execSync } from "node:child_process";
import { copyFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const appDir = dirname(dirname(fileURLToPath(import.meta.url)));
const workspace = join(appDir, "..");

function sh(cmd, cwd) {
  console.log(`[sidecars] ${cmd}`);
  execSync(cmd, { cwd, stdio: "inherit" });
}

function hostTriple() {
  const out = execSync("rustc -vV").toString();
  return /host: (\S+)/.exec(out)[1];
}

if (process.platform === "win32") {
  sh("cargo build --release -p localdns-helper", workspace);
  const triple = hostTriple();
  const dest = join(appDir, "src-tauri", "binaries");
  mkdirSync(dest, { recursive: true });
  copyFileSync(
    join(workspace, "target", "release", "localdns-helper.exe"),
    join(dest, `localdns-helper-${triple}.exe`),
  );
  console.log(`[sidecars] staged localdns-helper-${triple}.exe`);
} else if (process.platform === "linux") {
  sh("cargo build --release -p localdns-agentd", workspace);
  console.log("[sidecars] localdns-agentd built (bundled via deb/rpm files map)");
} else {
  console.log("[sidecars] nothing to stage on this platform");
}
