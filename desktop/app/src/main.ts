import { mount } from "svelte";
import App from "./App.svelte";
import "./app.css";

// Pause all animation work while the window is hidden (tray-only operation
// must cost ~0% CPU, matching the native app's energy behavior).
function syncHidden() {
  document.documentElement.toggleAttribute("data-hidden", document.hidden);
}
document.addEventListener("visibilitychange", syncHidden);
syncHidden();

const app = mount(App, { target: document.getElementById("app")! });

export default app;
