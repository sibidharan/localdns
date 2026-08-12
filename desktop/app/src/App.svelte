<script lang="ts">
  import { onMount } from "svelte";
  import {
    hostsScan,
    initStores,
    installUpdate,
    openReleasePage,
    updateAvailable,
    newRuleRequest,
    orbState,
    queryLog,
    refreshOverview,
    resolverOverview,
    rules,
    settings,
    statusLine,
    toast,
    toasts,
  } from "./lib/stores";
  import { api } from "./lib/api";
  import Orb from "./components/Orb.svelte";
  import Toggle from "./components/Toggle.svelte";
  import RulesView from "./views/RulesView.svelte";
  import SetupView from "./views/SetupView.svelte";
  import ImportView from "./views/ImportView.svelte";
  import DiagnosticsView from "./views/DiagnosticsView.svelte";
  import SettingsView from "./views/SettingsView.svelte";

  type Tab = "rules" | "setup" | "import" | "diagnostics" | "settings";
  let tab: Tab = "rules";
  let ready = false;
  let testing = false;
  let syncing = false;
  let scanning = false;

  const tabs: { id: Tab; label: string; icon: string }[] = [
    { id: "rules", label: "Rules", icon: "☰" },
    { id: "setup", label: "Setup", icon: "⛨" },
    { id: "import", label: "Import", icon: "⇲" },
    { id: "diagnostics", label: "Diagnostics", icon: "∿" },
    { id: "settings", label: "Settings", icon: "⚙" },
  ];

  onMount(async () => {
    await initStores();
    ready = true;
  });

  $: enabledRules = $rules.filter((r) => r.enabled).length;
  $: addableSuggestions = ($hostsScan?.suggestions ?? []).filter(
    (s) =>
      !$rules.some(
        (r) => r.pattern.toLowerCase().replace(/\.+$/, "") === s.pattern.toLowerCase(),
      ),
  ).length;
  $: planNoop =
    !$resolverOverview ||
    ($resolverOverview.plan.installs.length === 0 &&
      $resolverOverview.plan.removals.length === 0);

  // The orb IS the self-test button, exactly like the native ActionBar.
  async function selfTest() {
    if (testing) return;
    testing = true;
    try {
      const result = await api.runSelfTest();
      toast(result.ok ? "ok" : "error", result.message, result.ok ? 4200 : 7000);
    } catch (e) {
      toast("error", String(e));
    } finally {
      testing = false;
    }
  }

  async function toggleServer(on: boolean) {
    try {
      await api.setSettings({ ...$settings, serverEnabled: on });
    } catch (e) {
      toast("error", String(e));
    }
  }

  // Titlebar cluster actions (ContentView.sectionActions parity).
  async function syncNow() {
    syncing = true;
    try {
      const outcome = await api.resolverSync();
      if (outcome.kind === "failed") toast("error", outcome.value);
      else if (outcome.kind === "accessDenied")
        toast("error", "Access denied — complete the one-time setup.");
      else toast("ok", outcome.kind === "applied" ? "Registrations applied." : "Already up to date.");
    } finally {
      syncing = false;
      void refreshOverview();
    }
  }

  async function scanHosts() {
    scanning = true;
    try {
      hostsScan.set(await api.scanHosts());
    } catch (e) {
      toast("error", String(e));
    } finally {
      scanning = false;
    }
  }

  async function addAllSuggestions() {
    const scan = $hostsScan;
    if (!scan) return;
    const pending = scan.suggestions.filter(
      (s) =>
        !$rules.some(
          (r) => r.pattern.toLowerCase().replace(/\.+$/, "") === s.pattern.toLowerCase(),
        ),
    );
    try {
      await api.addSuggestedRules(pending.map((s) => ({ pattern: s.pattern, ip: s.ip })));
      toast("ok", `Added ${pending.length} rule(s) to the Imported group.`);
    } catch (e) {
      toast("error", String(e));
    }
  }

  async function clearLog() {
    try {
      await api.clearQueryLog();
      queryLog.set([]);
    } catch (e) {
      toast("error", String(e));
    }
  }
</script>

{#if ready}
  <div class="layout">
    <aside class="sidebar">
      <div class="brand">
        <img src="/icon.png" alt="" class="brand-icon" />
        <span>LocalDNS</span>
      </div>
      <nav>
        {#each tabs as t}
          <button
            class="nav-item"
            class:active={tab === t.id}
            on:click={() => (tab = t.id)}
          >
            <span class="nav-icon">{t.icon}</span>{t.label}
            {#if t.id === "rules" && $rules.length}
              <span class="count">{enabledRules}/{$rules.length}</span>
            {/if}
          </button>
        {/each}
      </nav>
      <div class="sidebar-footer muted">
        <span class="mono">{$resolverOverview?.backend ?? "…"}</span> backend
      </div>
    </aside>

    <div class="main">
      <!-- PersistentActionBar parity: orb (self-test) + status line + switch,
           plus the Helm-style per-section icon cluster on the trailing edge. -->
      <header class="topbar">
        <div class="status-cluster">
          <button
            class="orb-button"
            title="Run self-test"
            aria-label="Run self-test"
            disabled={testing}
            on:click={selfTest}
          >
            <Orb state={testing ? "attention" : $orbState} size={20} />
          </button>
          <span class="status-text muted" title={$statusLine}>{$statusLine}</span>
        </div>

        <div class="topbar-actions">
          {#if tab === "rules"}
            <button
              class="icon-action"
              title="Add Rule"
              aria-label="Add Rule"
              on:click={() => newRuleRequest.update((n) => n + 1)}>＋</button
            >
          {:else if tab === "import"}
            {#if addableSuggestions > 0}
              <button
                class="icon-action"
                title="Add All Suggestions"
                aria-label="Add All Suggestions"
                on:click={addAllSuggestions}>⧉</button
              >
            {/if}
            <button
              class="icon-action"
              title="Scan hosts file"
              aria-label="Scan hosts file"
              disabled={scanning}
              on:click={scanHosts}>🔍</button
            >
          {:else if tab === "setup"}
            <button
              class="icon-action"
              title="Re-sync Now"
              aria-label="Re-sync Now"
              disabled={syncing || planNoop || $resolverOverview?.access.kind !== "granted"}
              on:click={syncNow}>⟳</button
            >
          {:else if tab === "diagnostics"}
            <button
              class="icon-action"
              title="Clear Log"
              aria-label="Clear Log"
              disabled={$queryLog.length === 0}
              on:click={clearLog}>🗑</button
            >
          {/if}
          <Toggle
            checked={$settings.serverEnabled}
            label="DNS server master switch"
            onchange={toggleServer}
          />
        </div>
      </header>

      {#if $updateAvailable}
        <div class="update-banner">
          <span>
            LocalDNS {$updateAvailable.version} is available.
          </span>
          {#if $updateAvailable.channel === "package"}
            <button class="update-action" on:click={() => openReleasePage()}>
              View release
            </button>
          {:else}
            <button class="update-action" on:click={() => installUpdate()}>
              Install &amp; relaunch
            </button>
          {/if}
          <button class="update-dismiss" on:click={() => updateAvailable.set(null)}>
            Later
          </button>
        </div>
      {/if}
      <main class="content">
        {#if tab === "rules"}
          <RulesView />
        {:else if tab === "setup"}
          <SetupView />
        {:else if tab === "import"}
          <ImportView />
        {:else if tab === "diagnostics"}
          <DiagnosticsView />
        {:else}
          <SettingsView />
        {/if}
      </main>
    </div>
  </div>

  <div class="toasts">
    {#each $toasts as t (t.id)}
      <div class="toast {t.kind}">{t.message}</div>
    {/each}
  </div>
{/if}

<style>
  .layout {
    display: flex;
    height: 100vh;
  }
  .sidebar {
    width: 196px;
    flex: none;
    background: var(--bg-raised);
    border-right: 1px solid var(--border);
    display: flex;
    flex-direction: column;
    padding: 14px 10px;
    gap: 14px;
  }
  .brand {
    display: flex;
    align-items: center;
    gap: 9px;
    font-weight: 700;
    font-size: 15px;
    letter-spacing: -0.01em;
    padding: 2px 8px;
  }
  .brand-icon {
    width: 26px;
    height: 26px;
    border-radius: 6px;
  }
  nav {
    display: flex;
    flex-direction: column;
    gap: 2px;
    flex: 1;
  }
  .nav-item {
    display: flex;
    align-items: center;
    gap: 10px;
    background: transparent;
    border: none;
    border-radius: 8px;
    padding: 8px 10px;
    color: var(--muted);
    font-size: 13.5px;
    text-align: left;
  }
  .nav-item:hover {
    background: var(--panel);
    color: var(--text);
  }
  .nav-item.active {
    background: var(--accent-dim);
    color: var(--accent);
    font-weight: 600;
  }
  .nav-icon {
    width: 16px;
    text-align: center;
    opacity: 0.9;
  }
  .count {
    margin-left: auto;
    font-size: 11px;
    color: var(--faint);
    font-family: var(--mono);
  }
  .sidebar-footer {
    font-size: 11.5px;
    padding: 0 8px;
  }
  .main {
    flex: 1;
    display: flex;
    flex-direction: column;
    min-width: 0;
  }
  .update-banner {
    display: flex;
    align-items: center;
    gap: 12px;
    margin: 0 10px 10px;
    padding: 8px 16px;
    border-radius: 10px;
    background: color-mix(in srgb, var(--accent, #3478f6) 18%, transparent);
    font-size: 13px;
  }
  .update-banner span {
    flex: 1;
  }
  .update-action {
    font-weight: 600;
  }
  .update-dismiss {
    opacity: 0.7;
  }

  .topbar {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 9px 16px;
    border-bottom: 1px solid var(--border);
    background: var(--bg-raised);
    gap: 16px;
  }
  .status-cluster {
    display: flex;
    align-items: center;
    gap: 11px;
    min-width: 0;
  }
  .orb-button {
    background: transparent;
    border: none;
    border-radius: 50%;
    padding: 5px;
    display: flex;
    cursor: pointer;
    transition: background 0.15s ease;
  }
  .orb-button:hover:not(:disabled) {
    background: var(--panel);
  }
  .status-text {
    font-size: 12.5px;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
    max-width: 430px;
  }
  .topbar-actions {
    display: flex;
    align-items: center;
    gap: 10px;
    flex: none;
  }
  .icon-action {
    width: 32px;
    height: 30px;
    padding: 0;
    display: inline-flex;
    align-items: center;
    justify-content: center;
    font-size: 15px;
    line-height: 1;
    background: var(--panel);
    border: 1px solid var(--border);
    border-radius: 7px;
  }
  .content {
    flex: 1;
    overflow-y: auto;
    padding: 20px;
  }
  .toasts {
    position: fixed;
    bottom: 18px;
    right: 18px;
    display: flex;
    flex-direction: column;
    gap: 8px;
    z-index: 50;
    max-width: 420px;
  }
  .toast {
    padding: 10px 14px;
    border-radius: 9px;
    font-size: 12.5px;
    border: 1px solid var(--border);
    background: var(--panel);
    box-shadow: 0 6px 24px rgba(0, 0, 0, 0.45);
    animation: slide-in 0.18s ease;
  }
  .toast.ok {
    border-color: rgba(63, 185, 80, 0.5);
    color: var(--ok);
  }
  .toast.error {
    border-color: rgba(248, 81, 73, 0.5);
    color: var(--danger);
  }
  @keyframes slide-in {
    from {
      transform: translateY(6px);
      opacity: 0;
    }
    to {
      transform: none;
      opacity: 1;
    }
  }
</style>
