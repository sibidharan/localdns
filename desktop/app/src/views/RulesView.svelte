<script lang="ts">
  import { newRuleRequest, rules, toast } from "../lib/stores";
  import { api } from "../lib/api";
  import type { DnsRule } from "../lib/types";
  import Toggle from "../components/Toggle.svelte";
  import RuleEditSheet from "./RuleEditSheet.svelte";

  let editing: DnsRule | null = null;
  let sheetOpen = false;
  let confirmDelete: DnsRule | null = null;

  // Titlebar "Add Rule" action (ContentView keeps this in AppState on macOS).
  let lastRequest = 0;
  $: if ($newRuleRequest !== lastRequest) {
    lastRequest = $newRuleRequest;
    if (lastRequest > 0) openNew();
  }

  // Group by first appearance, like the macOS RulesView.
  $: groups = (() => {
    const order: string[] = [];
    const byGroup = new Map<string, DnsRule[]>();
    for (const rule of $rules) {
      if (!byGroup.has(rule.group)) {
        order.push(rule.group);
        byGroup.set(rule.group, []);
      }
      byGroup.get(rule.group)!.push(rule);
    }
    return order.map((name) => ({ name, rules: byGroup.get(name)! }));
  })();

  function openNew() {
    editing = null;
    sheetOpen = true;
  }

  function openEdit(rule: DnsRule) {
    editing = rule;
    sheetOpen = true;
  }

  async function toggleRule(rule: DnsRule, enabled: boolean) {
    try {
      await api.setRuleEnabled(rule.id, enabled);
    } catch (e) {
      toast("error", String(e));
    }
  }

  async function toggleGroup(name: string, enabled: boolean) {
    try {
      await api.setGroupEnabled(name, enabled);
    } catch (e) {
      toast("error", String(e));
    }
  }

  async function doDelete() {
    if (!confirmDelete) return;
    try {
      await api.deleteRule(confirmDelete.id);
      toast("info", `Deleted ${confirmDelete.pattern}`);
    } catch (e) {
      toast("error", String(e));
    } finally {
      confirmDelete = null;
    }
  }

  function addressText(rule: DnsRule): string {
    return [rule.ipv4, rule.ipv6].filter(Boolean).join("  ·  ") || "no address";
  }
</script>

<div class="head">
  <h2>Rules</h2>
</div>

{#if $rules.length === 0}
  <div class="empty panel">
    <p><strong>No rules yet.</strong></p>
    <p class="muted">
      Add a wildcard like <span class="mono">*.myapp.test</span> pointing at
      <span class="mono">127.0.0.1</span> or a container address — every
      subdomain resolves instantly, no hosts-file editing.
    </p>
    <button class="primary" on:click={openNew}>Add your first rule</button>
  </div>
{:else}
  {#each groups as group (group.name)}
    <section class="group">
      <div class="group-head">
        <h3>{group.name}</h3>
        <span class="muted count"
          >{group.rules.filter((r) => r.enabled).length}/{group.rules.length}</span
        >
        <Toggle
          checked={group.rules.some((r) => r.enabled)}
          label="Toggle group {group.name}"
          onchange={(on) => toggleGroup(group.name, on)}
        />
      </div>
      <div class="panel list">
        {#each group.rules as rule (rule.id)}
          <div
            class="row"
            class:disabled={!rule.enabled}
            role="button"
            tabindex="0"
            on:click={() => openEdit(rule)}
            on:keydown={(e) => e.key === "Enter" && openEdit(rule)}
          >
            <div class="row-main">
              <span class="pattern mono">{rule.pattern}</span>
              <span class="addr muted mono">{addressText(rule)}</span>
            </div>
            <span class="ttl faint mono">TTL {rule.ttl}s</span>
            <button
              class="ghost del"
              title="Delete rule"
              on:click|stopPropagation={() => (confirmDelete = rule)}>✕</button
            >
            <Toggle
              checked={rule.enabled}
              label="Enable {rule.pattern}"
              onchange={(on) => toggleRule(rule, on)}
            />
          </div>
        {/each}
      </div>
    </section>
  {/each}
{/if}

{#if sheetOpen}
  <RuleEditSheet rule={editing} onclose={() => (sheetOpen = false)} />
{/if}

{#if confirmDelete}
  <div class="overlay" role="presentation" on:click={() => (confirmDelete = null)}>
    <!-- svelte-ignore a11y_click_events_have_key_events a11y_no_noninteractive_element_interactions -->
    <div class="dialog panel" role="dialog" tabindex="-1" on:click|stopPropagation>
      <h2>Delete rule?</h2>
      <p class="muted">
        <span class="mono">{confirmDelete.pattern}</span> will stop resolving.
        Its zone is removed from the OS on the next sync.
      </p>
      <div class="dialog-actions">
        <button on:click={() => (confirmDelete = null)}>Cancel</button>
        <button class="danger" on:click={doDelete}>Delete</button>
      </div>
    </div>
  </div>
{/if}

<style>
  .head {
    display: flex;
    align-items: center;
    justify-content: space-between;
    margin-bottom: 18px;
  }
  .empty {
    padding: 34px;
    text-align: center;
    display: flex;
    flex-direction: column;
    gap: 10px;
    align-items: center;
  }
  .empty .muted {
    max-width: 460px;
    line-height: 1.5;
  }
  .group {
    margin-bottom: 22px;
  }
  .group-head {
    display: flex;
    align-items: center;
    gap: 10px;
    margin-bottom: 8px;
    padding: 0 2px;
  }
  .group-head .count {
    font-size: 11.5px;
    font-family: var(--mono);
    margin-right: auto;
  }
  .list {
    overflow: hidden;
  }
  .row {
    display: flex;
    align-items: center;
    gap: 14px;
    padding: 11px 14px;
    border-bottom: 1px solid var(--border);
    cursor: pointer;
  }
  .row:last-child {
    border-bottom: none;
  }
  .row:hover {
    background: var(--panel-hover);
  }
  .row.disabled .pattern,
  .row.disabled .addr {
    opacity: 0.45;
  }
  .row-main {
    flex: 1;
    display: flex;
    flex-direction: column;
    gap: 3px;
    min-width: 0;
  }
  .pattern {
    font-weight: 600;
    font-size: 13px;
  }
  .addr {
    font-size: 11.5px;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }
  .ttl {
    font-size: 11px;
    flex: none;
  }
  .del {
    padding: 3px 8px;
    font-size: 12px;
    visibility: hidden;
  }
  .row:hover .del {
    visibility: visible;
  }
  .overlay {
    position: fixed;
    inset: 0;
    background: rgba(4, 8, 12, 0.62);
    display: flex;
    align-items: center;
    justify-content: center;
    z-index: 40;
  }
  .dialog {
    width: 400px;
    padding: 22px;
    display: flex;
    flex-direction: column;
    gap: 12px;
    box-shadow: 0 18px 50px rgba(0, 0, 0, 0.5);
  }
  .dialog-actions {
    display: flex;
    justify-content: flex-end;
    gap: 9px;
    margin-top: 6px;
  }
</style>
