<script lang="ts">
  import { onMount } from "svelte";
  import { api } from "../lib/api";
  import { hostsScan, rules, toast } from "../lib/stores";

  let loading = false;
  let busy = false;
  $: scan = $hostsScan;

  async function refresh() {
    loading = scan === null;
    try {
      hostsScan.set(await api.scanHosts());
    } catch (e) {
      toast("error", String(e));
    } finally {
      loading = false;
    }
  }

  onMount(() => {
    if ($hostsScan === null) void refresh();
  });
  // Rule changes alter what's "already covered" — rescan.
  $: $rules, $hostsScan !== null && refresh();

  $: existingPatterns = new Set(
    $rules.map((r) => r.pattern.toLowerCase().replace(/\.+$/, "")),
  );

  function alreadyAdded(pattern: string): boolean {
    return existingPatterns.has(pattern.toLowerCase());
  }

  async function add(pattern: string, ip: string) {
    busy = true;
    try {
      await api.addSuggestedRules([{ pattern, ip }]);
      toast("ok", `Added ${pattern} → ${ip}`);
    } catch (e) {
      toast("error", String(e));
    } finally {
      busy = false;
    }
  }

</script>

<div class="head">
  <h2>Import from hosts file</h2>
</div>

{#if loading}
  <p class="muted">Reading hosts file…</p>
{:else if scan}
  <p class="muted intro">
    Read-only analysis of <span class="mono">{scan.path}</span> — the file is
    never modified. Groups of hostnames sharing an address and parent domain
    become wildcard suggestions.
  </p>

  {#if scan.suggestions.length === 0}
    <div class="panel empty">
      <p><strong>No wildcard candidates found.</strong></p>
      <p class="muted">
        Suggestions appear when at least two hostnames share an address and a
        parent domain (e.g. <span class="mono">api.myapp.test</span> and
        <span class="mono">web.myapp.test</span> → <span class="mono">*.myapp.test</span>).
      </p>
    </div>
  {:else}
    <section>
      <h3>Suggestions</h3>
      <div class="cards">
        {#each scan.suggestions as s (s.pattern + s.ip)}
          <div class="panel card">
            <div class="card-top">
              <span class="mono pattern">{s.pattern}</span>
              <span class="mono muted">→ {s.ip}</span>
            </div>
            <div class="covered muted">
              Covers {s.coveredHostnames.length}:
              {s.coveredHostnames.slice(0, 4).join(", ")}{s.coveredHostnames.length > 4
                ? "…"
                : ""}
            </div>
            {#if alreadyAdded(s.pattern)}
              <span class="chip ok">Added</span>
            {:else}
              <button disabled={busy} on:click={() => add(s.pattern, s.ip)}>Add</button>
            {/if}
          </div>
        {/each}
      </div>
    </section>
  {/if}

  {#if scan.uncovered.length}
    <section>
      <h3>Not covered by any rule</h3>
      <div class="panel uncovered">
        {#each scan.uncovered as name (name)}
          <span class="mono">{name}</span>
        {/each}
      </div>
    </section>
  {/if}
{/if}

<style>
  .head {
    display: flex;
    align-items: center;
    justify-content: space-between;
    margin-bottom: 12px;
  }
  .intro {
    margin-bottom: 18px;
    line-height: 1.5;
    max-width: 640px;
  }
  .empty {
    padding: 28px;
    text-align: center;
    display: flex;
    flex-direction: column;
    gap: 8px;
  }
  section {
    margin-bottom: 22px;
  }
  h3 {
    margin-bottom: 9px;
  }
  .cards {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(290px, 1fr));
    gap: 12px;
  }
  .card {
    padding: 14px;
    display: flex;
    flex-direction: column;
    gap: 8px;
    align-items: flex-start;
  }
  .card-top {
    display: flex;
    flex-direction: column;
    gap: 3px;
  }
  .pattern {
    font-weight: 700;
    font-size: 13px;
  }
  .covered {
    font-size: 11.5px;
    line-height: 1.45;
    word-break: break-all;
  }
  .uncovered {
    padding: 12px 14px;
    display: flex;
    flex-wrap: wrap;
    gap: 7px 16px;
    font-size: 12px;
  }
</style>
