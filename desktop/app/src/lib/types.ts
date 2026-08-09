// Mirrors the serde types emitted by src-tauri (camelCase via rename_all).

export interface DnsRule {
  enabled: boolean;
  group: string;
  id: string;
  ipv4?: string | null;
  ipv6?: string | null;
  pattern: string;
  ttl: number;
}

export interface Settings {
  port: number;
  serverEnabled: boolean;
  unregisterOnQuit: boolean;
  launchAtLogin: boolean;
}

export interface ServerStatus {
  running: boolean;
  enabled: boolean;
  error: string | null;
  port: number;
  endpoints: string[];
  backend: string;
  endpointPinned: boolean;
}

export type Outcome =
  | { kind: "answered"; value: string }
  | { kind: "noData" }
  | { kind: "nxdomain" };

export interface QueryLogEntry {
  id: string;
  timestampMs: number;
  name: string;
  qtype: string;
  outcome: Outcome;
  latencyMs: number;
}

export type ZoneState =
  | "registered"
  | "needsResync"
  | "notRegistered"
  | "managedElsewhere";

export interface ZoneStatus {
  zone: string;
  state: ZoneState;
}

export interface SyncPlan {
  installs: string[];
  removals: string[];
  conflicts: string[];
}

export type SyncOutcome =
  | { kind: "upToDate"; value: { conflicts: string[] } }
  | { kind: "applied"; value: { conflicts: string[] } }
  | { kind: "accessDenied" }
  | { kind: "failed"; value: string };

export type AccessState =
  | { kind: "granted" }
  | { kind: "needsSetup"; value: string };

export interface SetupStep {
  title: string;
  detail: string;
  copyCommand: string | null;
}

export interface ResolverOverview {
  backend: string;
  access: AccessState;
  endpoint: { addr: string; port: number };
  statuses: ZoneStatus[];
  plan: SyncPlan;
  instructions: { steps: SetupStep[] };
}

export interface SuggestedRule {
  pattern: string;
  ip: string;
  coveredHostnames: string[];
}

export interface HostsScan {
  path: string;
  suggestions: SuggestedRule[];
  uncovered: string[];
}

export interface PatternCheck {
  error: string | null;
  localTldWarning: boolean;
}

export interface MatchPreview {
  pattern: string;
  ipv4: string | null;
  ipv6: string | null;
  ttl: number;
  isDraft: boolean;
}

export interface SelfTestResult {
  ok: boolean;
  message: string;
}

export interface Bootstrap {
  rules: DnsRule[];
  settings: Settings;
  status: ServerStatus;
  queryLog: QueryLogEntry[];
}

export interface RuleInput {
  pattern: string;
  ipv4: string | null;
  ipv6: string | null;
  ttl: number;
  group: string;
}

export interface DraftRule {
  id: string | null;
  pattern: string;
  ipv4: string | null;
  ipv6: string | null;
  ttl: number;
}
