<script lang="ts">
  import { onMount } from "svelte";
  import { api } from "../lib/api";
  import { rules, toast } from "../lib/stores";
  import type { DnsRule, MatchPreview, PatternCheck } from "../lib/types";

  export let rule: DnsRule | null = null;
  export let initialPattern = "";
  export let onclose: () => void = () => {};

  let pattern = rule?.pattern ?? initialPattern;
  let ipv4 = rule?.ipv4 ?? "";
  let ipv6 = rule?.ipv6 ?? "";
  let ttl = rule?.ttl ?? 60;
  let group = rule?.group ?? "Default";
  let check: PatternCheck = { error: null, localTldWarning: false };
  let tryName = "";
  let preview: MatchPreview | null = null;
  let previewSeq = 0;
  let saving = false;

  $: existingGroups = [...new Set($rules.map((r) => r.group))];
  $: ipv4Invalid = ipv4.trim() !== "" && !isIpv4(ipv4.trim());
  $: ipv6Invalid = ipv6.trim() !== "" && !isIpv6(ipv6.trim());
  $: noAddress = ipv4.trim() === "" && ipv6.trim() === "";
  $: canSave =
    !check.error && !ipv4Invalid && !ipv6Invalid && pattern.trim() !== "" && !saving;

  function isIpv4(text: string): boolean {
    const parts = text.split(".");
    return (
      parts.length === 4 &&
      parts.every((p) => /^\d{1,3}$/.test(p) && Number(p) <= 255)
    );
  }

  function isIpv6(text: string): boolean {
    return /^[0-9a-fA-F:]{2,39}$/.test(text) && text.includes(":");
  }

  async function validate() {
    check = await api.validatePattern(pattern);
    await refreshPreview();
  }

  async function refreshPreview() {
    const seq = ++previewSeq;
    if (tryName.trim() === "") {
      preview = null;
      return;
    }
    const result = await api.previewMatch(tryName.trim(), {
      id: rule?.id ?? null,
      pattern,
      ipv4: ipv4.trim() || null,
      ipv6: ipv6.trim() || null,
      ttl,
    });
    if (seq === previewSeq) preview = result;
  }

  // Prefill the try-name from the pattern: *.zone → app.zone
  function suggestTryName() {
    const p = pattern.trim().toLowerCase().replace(/\.+$/, "");
    if (tryName === "" && p.startsWith("*.")) tryName = "app." + p.slice(2);
    else if (tryName === "" && p !== "") tryName = p;
    refreshPreview();
  }

  async function save() {
    if (!canSave) return;
    saving = true;
    try {
      if (rule) {
        await api.updateRule({
          ...rule,
          pattern: pattern.trim(),
          ipv4: ipv4.trim() || null,
          ipv6: ipv6.trim() || null,
          ttl,
          group: group.trim() || "Default",
        });
      } else {
        await api.addRule({
          pattern: pattern.trim(),
          ipv4: ipv4.trim() || null,
          ipv6: ipv6.trim() || null,
          ttl,
          group: group.trim() || "Default",
        });
      }
      onclose();
    } catch (e) {
      toast("error", String(e));
    } finally {
      saving = false;
    }
  }

  function onKeydown(e: KeyboardEvent) {
    if (e.key === "Escape") onclose();
    if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) save();
  }

  onMount(() => {
    if (pattern) validate();
  });
</script>

<svelte:window on:keydown={onKeydown} />

<div class="overlay" role="presentation" on:click={onclose}>
  <!-- svelte-ignore a11y_click_events_have_key_events a11y_no_noninteractive_element_interactions -->
  <div
    class="sheet panel"
    role="dialog"
    aria-modal="true"
    tabindex="-1"
    on:click|stopPropagation
  >
    <h2>{rule ? "Edit Rule" : "New Rule"}</h2>

    <label>
      <span>Pattern</span>
      <input
        class="mono"
        placeholder="*.myapp.test"
        bind:value={pattern}
        on:input={validate}
        on:blur={suggestTryName}
      />
      {#if check.error}
        <span class="hint bad">{check.error}</span>
      {:else if check.localTldWarning}
        <span class="hint warn"
          >.local belongs to Bonjour/mDNS — this can interfere with network
          services.</span
        >
      {:else if pattern.trim().startsWith("*.")}
        <span class="hint muted"
          >Matches the zone itself and subdomains at any depth.</span
        >
      {/if}
    </label>

    <div class="pair">
      <label>
        <span>IPv4 (A)</span>
        <input
          class="mono"
          placeholder="127.0.0.1"
          bind:value={ipv4}
          on:input={refreshPreview}
        />
        {#if ipv4Invalid}<span class="hint bad">Not a valid IPv4 address.</span>{/if}
      </label>
      <label>
        <span>IPv6 (AAAA)</span>
        <input
          class="mono"
          placeholder="fd00::1"
          bind:value={ipv6}
          on:input={refreshPreview}
        />
        {#if ipv6Invalid}<span class="hint bad">Not a valid IPv6 address.</span>{/if}
      </label>
    </div>
    {#if noAddress}
      <span class="hint warn"
        >No address: matching queries answer NODATA (name exists, no record).</span
      >
    {/if}

    <div class="pair">
      <label>
        <span>TTL (seconds)</span>
        <input type="number" min="1" max="86400" bind:value={ttl} on:input={refreshPreview} />
      </label>
      <label>
        <span>Group</span>
        <input list="groups" bind:value={group} placeholder="Default" />
        <datalist id="groups">
          {#each existingGroups as g}<option value={g}></option>{/each}
        </datalist>
      </label>
    </div>

    <div class="preview">
      <span class="preview-title">Live preview</span>
      <input
        class="mono"
        placeholder="Try a name, e.g. api.myapp.test"
        bind:value={tryName}
        on:input={refreshPreview}
      />
      {#if tryName.trim()}
        {#if preview}
          <div class="preview-result ok-line mono">
            {tryName.trim().toLowerCase()} → {[preview.ipv4, preview.ipv6]
              .filter(Boolean)
              .join(", ") || "NODATA"}
            <span class="faint">
              · {preview.isDraft ? "this rule" : `matches ${preview.pattern}`} · TTL {preview.ttl}s</span
            >
          </div>
        {:else}
          <div class="preview-result bad-line mono">NXDOMAIN — no rule matches</div>
        {/if}
      {/if}
    </div>

    <div class="actions">
      <button on:click={onclose}>Cancel</button>
      <button class="primary" disabled={!canSave} on:click={save}>
        {saving ? "Saving…" : rule ? "Save Changes" : "Add Rule"}
      </button>
    </div>
  </div>
</div>

<style>
  .overlay {
    position: fixed;
    inset: 0;
    background: rgba(4, 8, 12, 0.62);
    display: flex;
    align-items: center;
    justify-content: center;
    z-index: 40;
  }
  .sheet {
    width: 500px;
    max-height: 90vh;
    overflow-y: auto;
    padding: 24px;
    display: flex;
    flex-direction: column;
    gap: 15px;
    box-shadow: 0 18px 50px rgba(0, 0, 0, 0.5);
  }
  label {
    display: flex;
    flex-direction: column;
    gap: 6px;
    flex: 1;
  }
  label > span:first-child {
    font-size: 12px;
    font-weight: 600;
    color: var(--muted);
  }
  .pair {
    display: flex;
    gap: 12px;
  }
  .hint {
    font-size: 11.5px;
    line-height: 1.4;
  }
  .hint.bad {
    color: var(--danger);
  }
  .hint.warn {
    color: var(--warn);
  }
  .preview {
    background: var(--bg);
    border: 1px solid var(--border);
    border-radius: 9px;
    padding: 12px;
    display: flex;
    flex-direction: column;
    gap: 8px;
  }
  .preview-title {
    font-size: 11px;
    font-weight: 700;
    text-transform: uppercase;
    letter-spacing: 0.07em;
    color: var(--faint);
  }
  .preview-result {
    font-size: 12px;
    line-height: 1.45;
    word-break: break-all;
  }
  .ok-line {
    color: var(--ok);
  }
  .bad-line {
    color: var(--warn);
  }
  .actions {
    display: flex;
    justify-content: flex-end;
    gap: 9px;
    margin-top: 2px;
  }
</style>
