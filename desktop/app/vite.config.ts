import { defineConfig } from "vite";
import { svelte } from "@sveltejs/vite-plugin-svelte";

// Tauri expects a fixed dev port and doesn't want vite clearing its output.
// base "./" is load-bearing: the bundled webview serves assets over a custom
// protocol, where absolute /assets/... paths resolve unreliably (the classic
// Tauri release white-screen).
export default defineConfig({
  base: "./",
  plugins: [svelte()],
  clearScreen: false,
  server: {
    port: 1420,
    strictPort: true,
    watch: { ignored: ["**/src-tauri/**"] },
  },
  test: {
    environment: "jsdom",
    include: ["src/**/*.test.ts"],
    coverage: {
      provider: "v8",
      // The .ts modules are the logic layer; .svelte views are exercised by
      // the Rust-side command tests + manual/VM E2E, not unit-tested here.
      include: ["src/lib/**/*.ts"],
      thresholds: { lines: 80, functions: 80 },
    },
  },
});
