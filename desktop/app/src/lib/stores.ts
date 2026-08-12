import { derived, writable } from "svelte/store";
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { api } from "./api";
import type {
  DnsRule,
  HostsScan,
  QueryLogEntry,
  ResolverOverview,
  ServerStatus,
  Settings,
} from "./types";

export const rules = writable<DnsRule[]>([]);
export const settings = writable<Settings>({
  checkUpdates: true,
  port: 15353,
  serverEnabled: true,
  unregisterOnQuit: false,
  launchAtLogin: false,
});
export const status = writable<ServerStatus>({
  running: false,
  enabled: true,
  error: null,
  port: 15353,
  endpoints: [],
  backend: "",
  endpointPinned: false,
});
export const queryLog = writable<QueryLogEntry[]>([]);
/// Bumped whenever backend registrations changed; SetupView refetches on it.
export const resolverVersion = writable(0);
/// Live resolver overview (statuses, plan, access) shared by the action bar
/// (orb color, status line) and the Setup view.
export const resolverOverview = writable<ResolverOverview | null>(null);
/// Hosts-file scan result, hoisted so the titlebar "Add All" action knows the
/// addable count (mirrors AppState.importSuggestions on macOS).
export const hostsScan = writable<HostsScan | null>(null);

/// Titlebar action requests → views (macOS keeps these in AppState).
export const newRuleRequest = writable(0);

/// A newer release than the running version, when known.
export interface UpdateInfo {
  version: string;
  /// "nsis" | "appimage" install in place; "package" links to the release.
  channel: string;
}
export const updateAvailable = writable<UpdateInfo | null>(null);

const RELEASES_URL = "https://github.com/sibidharan/localdns/releases/latest";

/// One unauthenticated check against the release feed. "dev" installs skip;
/// "package" installs only learn the version (never self-install).
export async function checkForUpdates(): Promise<void> {
  try {
    const channel = await invoke<string>("update_channel");
    if (channel === "dev") return;
    const { check } = await import("@tauri-apps/plugin-updater");
    const update = await check();
    if (update) {
      updateAvailable.set({ version: update.version, channel });
    }
  } catch {
    // Offline or feed unreachable — stay quiet, try again next cycle.
  }
}

export async function installUpdate(): Promise<void> {
  const { check } = await import("@tauri-apps/plugin-updater");
  const update = await check();
  if (!update) return;
  await update.downloadAndInstall();
  const { relaunch } = await import("@tauri-apps/plugin-process");
  await relaunch();
}

export async function openReleasePage(): Promise<void> {
  const { openUrl } = await import("@tauri-apps/plugin-opener");
  await openUrl(RELEASES_URL);
}

/// Orb/status derivation, mirroring ActionBar.swift's AppState extension:
/// teal = serving & settled · amber = running but work pending · gray = stopped.
export const orbState = derived(
  [status, resolverOverview],
  ([$status, $overview]): "live" | "attention" | "stopped" | "error" => {
    if ($status.error) return "error";
    if (!$status.running) return "stopped";
    if (!$overview) return "live";
    const settled =
      $overview.plan.installs.length === 0 &&
      $overview.plan.conflicts.length === 0 &&
      $overview.statuses.every((s) => s.state === "registered");
    return settled ? "live" : "attention";
  },
);

/// One line, e.g. "2 of 3 zones · port 15353" (ActionBar.statusLine parity).
export const statusLine = derived(
  [status, resolverOverview],
  ([$status, $overview]) => {
    if ($status.error) return $status.error;
    if (!$status.running) return "Server stopped";
    const total = $overview?.statuses.length ?? 0;
    if (total === 0) return `No rules yet · port ${$status.port}`;
    const ok = $overview!.statuses.filter((s) => s.state === "registered").length;
    return `${ok} of ${total} zones · port ${$status.port}`;
  },
);

export async function refreshOverview() {
  try {
    resolverOverview.set(await api.resolverOverview());
  } catch {
    /* backend busy; next event refreshes */
  }
}

export interface Toast {
  id: number;
  kind: "ok" | "error" | "info";
  message: string;
}
export const toasts = writable<Toast[]>([]);
let toastSeq = 0;

export function toast(kind: Toast["kind"], message: string, ttlMs = 4200) {
  const id = ++toastSeq;
  toasts.update((all) => [...all, { id, kind, message }]);
  setTimeout(() => toasts.update((all) => all.filter((t) => t.id !== id)), ttlMs);
}

let initialized = false;

export async function initStores() {
  if (initialized) return;
  initialized = true;

  const boot = await api.getBootstrap();
  rules.set(boot.rules);
  settings.set(boot.settings);
  status.set(boot.status);
  queryLog.set(boot.queryLog);

  await listen<DnsRule[]>("rules-changed", (e) => rules.set(e.payload));
  await listen<ServerStatus>("server-status", (e) => {
    status.set(e.payload);
    void refreshOverview();
  });
  await listen<QueryLogEntry[]>("query-log", (e) => queryLog.set(e.payload));
  await listen<Settings>("settings-changed", (e) => settings.set(e.payload));
  await listen("resolver-changed", () => {
    resolverVersion.update((v) => v + 1);
    void refreshOverview();
  });
  void refreshOverview();

  // Update check: on launch and every 24 h, only while enabled in Settings.
  const maybeCheck = () => {
    let enabled = true;
    settings.subscribe((s) => (enabled = s.checkUpdates))();
    if (enabled) void checkForUpdates();
  };
  setTimeout(maybeCheck, 5000);
  setInterval(maybeCheck, 24 * 60 * 60 * 1000);

  // Coming back from the tray: the debounced publisher skipped us while
  // hidden, so refresh the log when the window regains focus.
  window.addEventListener("focus", async () => {
    queryLog.set(await api.getQueryLog());
    status.set(await api.getStatus());
  });
}
