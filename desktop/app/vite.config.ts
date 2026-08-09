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
  },
});
