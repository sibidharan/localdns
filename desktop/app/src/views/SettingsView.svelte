<script lang="ts">
  import { settings, status, toast } from "../lib/stores";
  import { api } from "../lib/api";
import { checkForUpdates, updateAvailable } from "../lib/stores";
  import Toggle from "../components/Toggle.svelte";

  let portDraft: number = $settings.port;
  $: portDraft = $settings.port;
  $: portChanged = portDraft !== $settings.port;
  $: portValid = portDraft >= 1024 && portDraft <= 65535;

  async function apply(overrides: Partial<typeof $settings>) {
    try {
      await api.setSettings({ ...$settings, ...overrides });
    } catch (e) {
      toast("error", String(e));
    }
  }

  async function applyPort() {
    if (!portValid || !portChanged) return;
    await apply({ port: portDraft });
    toast("ok", `Server restarted on port ${portDraft}; zones re-sync automatically.`);
  }
</script>

<div class="head"><h2>Settings</h2></div>

<div class="panel section">
  <div class="row">
    <div class="row-text">
      <strong>DNS server port</strong>
      <span class="muted">
        {#if $status.endpointPinned}
          This platform routes zone queries to a fixed endpoint
          ({$status.endpoints.join(", ")}), so the port is managed for you.
        {:else}
          UDP + TCP on 127.0.0.1. Changing it restarts the server and re-writes
          zone registrations.
        {/if}
      </span>
    </div>
    <div class="port-controls">
      <input
        type="number"
        min="1024"
        max="65535"
        bind:value={portDraft}
        disabled={$status.endpointPinned}
        on:keydown={(e) => e.key === "Enter" && applyPort()}
      />
      {#if !$status.endpointPinned}
        <button disabled={!portChanged || !portValid} on:click={applyPort}>Apply</button>
      {/if}
    </div>
  </div>
  {#if !portValid}
    <span class="hint bad">Port must be between 1024 and 65535.</span>
  {/if}
</div>

<div class="panel section">
  <div class="row">
    <div class="row-text">
      <strong>Launch at login</strong>
      <span class="muted">Start LocalDNS hidden in the tray when you sign in.</span>
    </div>
    <Toggle
      checked={$settings.launchAtLogin}
      label="Launch at login"
      onchange={(on) => apply({ launchAtLogin: on })}
    />
  </div>
  <div class="row">
    <div class="row-text">
      <strong>Unregister zones on quit</strong>
      <span class="muted">
        Remove this app's OS registrations when quitting, so zone queries fall
        back to normal DNS while LocalDNS isn't running.
      </span>
    </div>
    <Toggle
      checked={$settings.unregisterOnQuit}
      label="Unregister on quit"
      onchange={(on) => apply({ unregisterOnQuit: on })}
    />
  </div>
  <div class="row">
    <div class="row-text">
      <strong>Check for updates automatically</strong>
      <span class="muted">
        Once a day, one request to github.com/sibidharan/localdns — nothing
        else ever leaves this machine.
      </span>
    </div>
    <Toggle
      checked={$settings.checkUpdates}
      label="Check for updates"
      onchange={(on) => apply({ checkUpdates: on })}
    />
  </div>
  <div class="row">
    <div class="row-text">
      <strong>Updates</strong>
      <span class="muted">
        {#if $updateAvailable}
          Version {$updateAvailable.version} is available.
        {:else}
          You're on the latest known version.
        {/if}
      </span>
    </div>
    <button on:click={() => checkForUpdates()}>Check now</button>
  </div>
</div>

<div class="panel section">
  <div class="row">
    <div class="row-text">
      <strong>Server endpoints</strong>
      <span class="muted mono">{$status.endpoints.join("  ·  ") || "—"}</span>
    </div>
  </div>
  <div class="row">
    <div class="row-text">
      <strong>Resolver backend</strong>
      <span class="muted mono">{$status.backend}</span>
    </div>
  </div>
</div>

<div class="quit-row">
  <button class="danger" on:click={() => api.quit()}>Quit LocalDNS</button>
</div>

<style>
  .head {
    margin-bottom: 18px;
  }
  .section {
    padding: 4px 16px;
    margin-bottom: 14px;
  }
  .row {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 20px;
    padding: 13px 0;
    border-bottom: 1px solid var(--border);
  }
  .section .row:last-child {
    border-bottom: none;
  }
  .row-text {
    display: flex;
    flex-direction: column;
    gap: 3px;
    line-height: 1.45;
    max-width: 520px;
  }
  .row-text .muted {
    font-size: 12px;
  }
  .port-controls {
    display: flex;
    gap: 8px;
    align-items: center;
    flex: none;
  }
  .port-controls input {
    width: 90px;
  }
  .hint.bad {
    color: var(--danger);
    font-size: 11.5px;
    display: block;
    padding: 0 0 12px;
  }
  .quit-row {
    display: flex;
    justify-content: flex-end;
    margin-top: 4px;
  }
</style>
