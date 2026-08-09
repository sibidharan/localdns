import { invoke } from "@tauri-apps/api/core";
import type {
  Bootstrap,
  DnsRule,
  DraftRule,
  HostsScan,
  MatchPreview,
  PatternCheck,
  QueryLogEntry,
  ResolverOverview,
  RuleInput,
  SelfTestResult,
  ServerStatus,
  Settings,
  SyncOutcome,
} from "./types";

export const api = {
  getBootstrap: () => invoke<Bootstrap>("get_bootstrap"),

  addRule: (input: RuleInput) => invoke<DnsRule[]>("add_rule", { input }),
  updateRule: (rule: DnsRule) => invoke<DnsRule[]>("update_rule", { rule }),
  deleteRule: (id: string) => invoke<DnsRule[]>("delete_rule", { id }),
  setRuleEnabled: (id: string, enabled: boolean) =>
    invoke<DnsRule[]>("set_rule_enabled", { id, enabled }),
  setGroupEnabled: (group: string, enabled: boolean) =>
    invoke<DnsRule[]>("set_group_enabled", { group, enabled }),

  validatePattern: (pattern: string) =>
    invoke<PatternCheck>("validate_pattern", { pattern }),
  previewMatch: (name: string, draft: DraftRule | null) =>
    invoke<MatchPreview | null>("preview_match", { name, draft }),

  getSettings: () => invoke<Settings>("get_settings"),
  setSettings: (settings: Settings) =>
    invoke<Settings>("set_settings", { settings }),

  getStatus: () => invoke<ServerStatus>("get_status"),
  runSelfTest: () => invoke<SelfTestResult>("run_self_test"),

  getQueryLog: () => invoke<QueryLogEntry[]>("get_query_log"),
  clearQueryLog: () => invoke<QueryLogEntry[]>("clear_query_log"),

  scanHosts: () => invoke<HostsScan>("scan_hosts"),
  addSuggestedRules: (items: { pattern: string; ip: string }[]) =>
    invoke<DnsRule[]>("add_suggested_rules", { items }),

  resolverOverview: () => invoke<ResolverOverview>("resolver_overview"),
  resolverSync: () => invoke<SyncOutcome>("resolver_sync"),
  resolverUnregisterAll: () => invoke<SyncOutcome>("resolver_unregister_all"),

  quit: () => invoke<void>("quit_app"),
};
