// The api object is a 1:1 mapping onto #[tauri::command] names — this pins
// every command string and its argument shape against typos.

import { describe, expect, it, vi } from "vitest";

const invokeMock = vi.fn().mockResolvedValue(null);
vi.mock("@tauri-apps/api/core", () => ({
  invoke: (...args: unknown[]) => invokeMock(...args),
}));

import { api } from "./api";
import type { DnsRule, RuleInput, Settings } from "./types";

const rule: DnsRule = {
  enabled: true,
  group: "Default",
  id: "1",
  pattern: "*.a.test",
  ttl: 60,
};
const input: RuleInput = { pattern: "*.a.test", ipv4: "10.0.0.1", ipv6: null, ttl: 60, group: "" };
const settings: Settings = {
  port: 15353,
  serverEnabled: true,
  unregisterOnQuit: false,
  launchAtLogin: false,
};

it("maps every call onto its command name and payload", async () => {
  await api.getBootstrap();
  await api.addRule(input);
  await api.updateRule(rule);
  await api.deleteRule("1");
  await api.setRuleEnabled("1", false);
  await api.setGroupEnabled("Default", true);
  await api.validatePattern("*.a.test");
  await api.previewMatch("x.a.test", null);
  await api.getSettings();
  await api.setSettings(settings);
  await api.getStatus();
  await api.runSelfTest();
  await api.getQueryLog();
  await api.clearQueryLog();
  await api.scanHosts();
  await api.addSuggestedRules([{ pattern: "*.h.test", ip: "10.0.0.2" }]);
  await api.resolverOverview();
  await api.resolverSync();
  await api.resolverUnregisterAll();
  await api.quit();

  const commands = invokeMock.mock.calls.map((call) => call[0]);
  expect(commands).toEqual([
    "get_bootstrap",
    "add_rule",
    "update_rule",
    "delete_rule",
    "set_rule_enabled",
    "set_group_enabled",
    "validate_pattern",
    "preview_match",
    "get_settings",
    "set_settings",
    "get_status",
    "run_self_test",
    "get_query_log",
    "clear_query_log",
    "scan_hosts",
    "add_suggested_rules",
    "resolver_overview",
    "resolver_sync",
    "resolver_unregister_all",
    "quit_app",
  ]);

  expect(invokeMock).toHaveBeenCalledWith("add_rule", { input });
  expect(invokeMock).toHaveBeenCalledWith("set_rule_enabled", { id: "1", enabled: false });
  expect(invokeMock).toHaveBeenCalledWith("set_settings", { settings });
});
