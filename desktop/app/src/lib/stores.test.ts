// Store-level tests: orb/status derivations (ActionBar.swift parity) and the
// bootstrap/event wiring, with the Tauri IPC fully mocked.

import { beforeEach, describe, expect, it, vi } from "vitest";
import { get } from "svelte/store";

const invokeMock = vi.fn();
const listeners = new Map<string, (event: { payload: unknown }) => void>();

vi.mock("@tauri-apps/api/core", () => ({
  invoke: (...args: unknown[]) => invokeMock(...args),
}));
vi.mock("@tauri-apps/plugin-updater", () => ({
  check: () =>
    Promise.resolve({ version: "9.9.9", downloadAndInstall: vi.fn() }),
}));
vi.mock("@tauri-apps/plugin-opener", () => ({ openUrl: vi.fn() }));
vi.mock("@tauri-apps/plugin-process", () => ({ relaunch: vi.fn() }));

vi.mock("@tauri-apps/api/event", () => ({
  listen: (name: string, handler: (event: { payload: unknown }) => void) => {
    listeners.set(name, handler);
    return Promise.resolve(() => listeners.delete(name));
  },
}));

import {
  initStores,
  orbState,
  queryLog,
  resolverOverview,
  rules,
  status,
  statusLine,
} from "./stores";
import type { ResolverOverview, ServerStatus } from "./types";

function serverStatus(overrides: Partial<ServerStatus> = {}): ServerStatus {
  return {
    running: true,
    enabled: true,
    error: null,
    port: 15353,
    endpoints: ["127.0.0.1:15353"],
    backend: "mock",
    endpointPinned: false,
    ...overrides,
  };
}

function overview(overrides: Partial<ResolverOverview> = {}): ResolverOverview {
  return {
    backend: "mock",
    access: { kind: "granted" },
    endpoint: { addr: "127.0.0.1", port: 15353 },
    statuses: [],
    plan: { installs: [], removals: [], conflicts: [] },
    instructions: { steps: [] },
    ...overrides,
  };
}

describe("orbState (DNSOrb.State parity)", () => {
  it("is stopped when the server is not running", () => {
    status.set(serverStatus({ running: false }));
    resolverOverview.set(overview());
    expect(get(orbState)).toBe("stopped");
  });

  it("is error when the server reports an error", () => {
    status.set(serverStatus({ error: "port in use" }));
    expect(get(orbState)).toBe("error");
  });

  it("is live when running and every zone is registered", () => {
    status.set(serverStatus());
    resolverOverview.set(
      overview({
        statuses: [
          { zone: "a.test", state: "registered" },
          { zone: "b.test", state: "registered" },
        ],
      }),
    );
    expect(get(orbState)).toBe("live");
  });

  it("is attention when running but work is pending", () => {
    status.set(serverStatus());
    resolverOverview.set(
      overview({
        statuses: [{ zone: "a.test", state: "notRegistered" }],
        plan: { installs: ["a.test"], removals: [], conflicts: [] },
      }),
    );
    expect(get(orbState)).toBe("attention");
  });

  it("is attention when a zone is managed elsewhere", () => {
    status.set(serverStatus());
    resolverOverview.set(
      overview({
        statuses: [{ zone: "vpn.test", state: "managedElsewhere" }],
        plan: { installs: [], removals: [], conflicts: ["vpn.test"] },
      }),
    );
    expect(get(orbState)).toBe("attention");
  });
});

describe("statusLine (ActionBar.statusLine parity)", () => {
  it("says stopped when not running", () => {
    status.set(serverStatus({ running: false }));
    resolverOverview.set(overview());
    expect(get(statusLine)).toBe("Server stopped");
  });

  it("mentions the port when there are no zones", () => {
    status.set(serverStatus({ port: 25353 }));
    resolverOverview.set(overview());
    expect(get(statusLine)).toBe("No rules yet · port 25353");
  });

  it("counts registered zones out of total", () => {
    status.set(serverStatus());
    resolverOverview.set(
      overview({
        statuses: [
          { zone: "a.test", state: "registered" },
          { zone: "b.test", state: "needsResync" },
          { zone: "c.test", state: "registered" },
        ],
      }),
    );
    expect(get(statusLine)).toBe("2 of 3 zones · port 15353");
  });

  it("surfaces the server error", () => {
    status.set(serverStatus({ error: "listener failed" }));
    expect(get(statusLine)).toBe("listener failed");
  });
});

describe("initStores wiring", () => {
  beforeEach(() => {
    invokeMock.mockReset();
    listeners.clear();
  });

  it("hydrates from get_bootstrap and applies pushed events", async () => {
    invokeMock.mockImplementation((cmd: string) => {
      switch (cmd) {
        case "get_bootstrap":
          return Promise.resolve({
            rules: [
              {
                enabled: true,
                group: "Default",
                id: "1",
                pattern: "*.a.test",
                ttl: 60,
              },
            ],
            settings: {
              port: 15353,
              serverEnabled: true,
              unregisterOnQuit: false,
              launchAtLogin: false,
              checkUpdates: false,
            },
            status: serverStatus(),
            queryLog: [],
          });
        case "resolver_overview":
          return Promise.resolve(overview());
        default:
          return Promise.resolve(null);
      }
    });

    await initStores();

    expect(get(rules)).toHaveLength(1);
    expect(invokeMock).toHaveBeenCalledWith("get_bootstrap");

    // Backend pushes replace store contents wholesale.
    listeners.get("rules-changed")!({ payload: [] });
    expect(get(rules)).toHaveLength(0);

    listeners.get("query-log")!({
      payload: [
        {
          id: "q1",
          timestampMs: 0,
          name: "x.a.test",
          qtype: "A",
          outcome: { kind: "nxdomain" },
          latencyMs: 0.1,
        },
      ],
    });
    expect(get(queryLog)).toHaveLength(1);

    listeners.get("server-status")!({ payload: serverStatus({ port: 999 }) });
    expect(get(status).port).toBe(999);

    // settings + resolver pushes and the focus catch-up path.
    listeners.get("settings-changed")!({
      payload: { port: 999, serverEnabled: false, unregisterOnQuit: false, launchAtLogin: false },
    });
    listeners.get("resolver-changed")!({ payload: null });
    window.dispatchEvent(new Event("focus"));
    await new Promise((resolve) => setTimeout(resolve, 10));
    expect(invokeMock).toHaveBeenCalledWith("resolver_overview");
  });
});

describe("toasts", () => {
  it("auto-expire after their ttl", async () => {
    const { toast, toasts } = await import("./stores");
    toast("ok", "saved", 5);
    expect(get(toasts)).toHaveLength(1);
    await new Promise((resolve) => setTimeout(resolve, 40));
    expect(get(toasts)).toHaveLength(0);
  });
});

describe("update check", () => {
  it("stores the update for updatable channels and skips dev", async () => {
    const { checkForUpdates, updateAvailable } = await import("./stores");
    invokeMock.mockImplementation((cmd: string) =>
      Promise.resolve(cmd === "update_channel" ? "nsis" : null),
    );
    await checkForUpdates();
    expect(get(updateAvailable)).toEqual({ version: "9.9.9", channel: "nsis" });

    updateAvailable.set(null);
    invokeMock.mockImplementation(() => Promise.resolve("dev"));
    await checkForUpdates();
    expect(get(updateAvailable)).toBeNull();
  });
});
