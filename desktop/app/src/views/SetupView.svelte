<script lang="ts">
  import { writeText } from "@tauri-apps/plugin-clipboard-manager";
  import { api } from "../lib/api";
  import { refreshOverview, resolverOverview, toast } from "../lib/stores";
  import type { SyncOutcome, ZoneState } from "../lib/types";

  let busy = false;
  $: overview = $resolverOverview;
  $: loading = overview === null;

  const stateLabel: Record<ZoneState, string> = {
    registered: "Registered",
    needsResync: "Needs re-sync",
    notRegistered: "Not registered",
    managedElsewhere: "Managed elsewhere",
  };
  const stateClass: Record<ZoneState, string> = {
    registered: "ok",
    needsResync: "warn",
    notRegistered: "off",
    managedElsewhere: "bad",
  };

  const refresh = refreshOverview;

  function describeOutcome(outcome: SyncOutcome): string {
    switch (outcome.kind) {
      case "upToDate":
        return "Already up to date.";
      case "applied":
        return outcome.value.conflicts.length
          ? `Applied — ${outcome.value.conflicts.length} zone(s) managed elsewhere were left untouched.`
          : "Registrations applied.";
      case "accessDenied":
        return "Access denied — complete the one-time setup below.";
      case "failed":
        return `Failed: ${outcome.value}`;
    }
  }

  async function unregisterAll() {
    busy = true;
    try {
      const outcome = await api.resolverUnregisterAll();
      toast(outcome.kind === "failed" ? "error" : "info", describeOutcome(outcome));
    } finally {
      busy = false;
      refresh();
    }
  }

  async function copy(command: string) {
    await writeText(command);
    toast("info", "Copied to clipboard.");
  }
</script>

<div class="head">
  <h2>Setup</h2>
  <div class="actions">
    <button on:click={refresh} disabled={busy}>Re-check</button>
    <button class="danger" on:click={unregisterAll} disabled={busy || overview?.access.kind !== "granted"}
      >Unregister All</button
    >
  </div>
</div>

{#if loading}
  <p class="muted">Checking resolver state…</p>
{:else if overview}
  {#if overview.access.kind === "granted"}
    <div class="banner panel ok-banner">
      <strong>Ready.</strong>
      <span class="muted">
        Zone queries route to
        <span class="mono">{overview.endpoint.addr}:{overview.endpoint.port}</span>
        via the <span class="mono">{overview.backend}</span> backend. Rule changes
        sync automatically.
      </span>
    </div>
  {:else}
    <div class="banner panel warn-banner">
      <strong>One-time setup required.</strong>
      <span class="muted">{overview.access.value}</span>
    </div>
  {/if}

  {#if overview.instructions.steps.length}
    <section>
      <h3>Steps</h3>
      <ol class="steps">
        {#each overview.instructions.steps as step, i}
          <li class="panel step">
            <div class="step-number">{i + 1}</div>
            <div class="step-body">
              <strong>{step.title}</strong>
              <span class="muted">{step.detail}</span>
              {#if step.copyCommand}
                <div class="command">
                  <code class="mono">{step.copyCommand}</code>
                  <button on:click={() => copy(step.copyCommand ?? "")}>Copy</button>
                </div>
              {/if}
            </div>
          </li>
        {/each}
      </ol>
    </section>
  {/if}

  <section>
    <h3>Zones</h3>
    {#if overview.statuses.length === 0}
      <p class="muted">No zones yet — add an enabled rule and its zone appears here.</p>
    {:else}
      <div class="panel">
        {#each overview.statuses as status (status.zone)}
          <div class="zone-row">
            <span class="mono">{status.zone}</span>
            <span class="chip {stateClass[status.state]}">{stateLabel[status.state]}</span>
          </div>
        {/each}
      </div>
      {#if overview.plan.conflicts.length}
        <p class="conflict-note muted">
          Zones marked “Managed elsewhere” have a registration owned by another
          tool (e.g. a VPN). LocalDNS never modifies them.
        </p>
      {/if}
    {/if}
  </section>
{/if}

<style>
  .head {
    display: flex;
    align-items: center;
    justify-content: space-between;
    margin-bottom: 18px;
    gap: 12px;
    flex-wrap: wrap;
  }
  .actions {
    display: flex;
    gap: 8px;
  }
  .banner {
    padding: 14px 16px;
    display: flex;
    flex-direction: column;
    gap: 4px;
    margin-bottom: 20px;
    line-height: 1.45;
  }
  .ok-banner {
    border-color: rgba(63, 185, 80, 0.4);
  }
  .warn-banner {
    border-color: rgba(210, 153, 34, 0.45);
  }
  section {
    margin-bottom: 22px;
  }
  h3 {
    margin-bottom: 9px;
  }
  .steps {
    list-style: none;
    display: flex;
    flex-direction: column;
    gap: 10px;
  }
  .step {
    display: flex;
    gap: 14px;
    padding: 14px 16px;
  }
  .step-number {
    width: 26px;
    height: 26px;
    border-radius: 50%;
    background: var(--accent-dim);
    color: var(--accent);
    font-weight: 700;
    display: flex;
    align-items: center;
    justify-content: center;
    flex: none;
    font-size: 13px;
  }
  .step-body {
    display: flex;
    flex-direction: column;
    gap: 5px;
    line-height: 1.45;
    min-width: 0;
    flex: 1;
  }
  .command {
    display: flex;
    gap: 8px;
    align-items: center;
    margin-top: 4px;
  }
  .command code {
    flex: 1;
    background: var(--bg);
    border: 1px solid var(--border);
    border-radius: 7px;
    padding: 8px 10px;
    font-size: 11.5px;
    overflow-x: auto;
    white-space: nowrap;
  }
  .zone-row {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 11px 14px;
    border-bottom: 1px solid var(--border);
    gap: 12px;
  }
  .zone-row:last-child {
    border-bottom: none;
  }
  .conflict-note {
    font-size: 12px;
    margin-top: 8px;
    line-height: 1.5;
  }
</style>
