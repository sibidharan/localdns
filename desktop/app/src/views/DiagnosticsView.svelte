<script lang="ts">
  import { queryLog } from "../lib/stores";
  import type { Outcome } from "../lib/types";

  function time(ms: number): string {
    return new Date(ms).toLocaleTimeString(undefined, { hour12: false });
  }

  function outcomeText(outcome: Outcome): string {
    switch (outcome.kind) {
      case "answered":
        return outcome.value;
      case "noData":
        return "NODATA";
      case "nxdomain":
        return "NXDOMAIN";
    }
  }

  function outcomeClass(outcome: Outcome): string {
    switch (outcome.kind) {
      case "answered":
        return "ok-text";
      case "noData":
        return "warn-text";
      case "nxdomain":
        return "muted";
    }
  }

</script>

<div class="head">
  <h2>Diagnostics</h2>
  <div class="right">
    <span class="muted count">{$queryLog.length} queries (last 200)</span>
  </div>
</div>

{#if $queryLog.length === 0}
  <div class="panel empty">
    <p><strong>No queries yet.</strong></p>
    <p class="muted">
      Once the OS routes a zone here (or you run the self-test), every query the
      server answers appears live in this list.
    </p>
  </div>
{:else}
  <div class="panel table-wrap">
    <table>
      <thead>
        <tr>
          <th class="t-time">Time</th>
          <th>Name</th>
          <th class="t-type">Type</th>
          <th>Answer</th>
          <th class="t-lat">Latency</th>
        </tr>
      </thead>
      <tbody>
        {#each $queryLog as entry (entry.id)}
          <tr>
            <td class="mono faint t-time">{time(entry.timestampMs)}</td>
            <td class="mono">{entry.name}</td>
            <td class="mono muted t-type">{entry.qtype}</td>
            <td class="mono {outcomeClass(entry.outcome)}">{outcomeText(entry.outcome)}</td>
            <td class="mono faint t-lat">{entry.latencyMs.toFixed(2)} ms</td>
          </tr>
        {/each}
      </tbody>
    </table>
  </div>
{/if}

<style>
  .head {
    display: flex;
    align-items: center;
    justify-content: space-between;
    margin-bottom: 18px;
  }
  .right {
    display: flex;
    align-items: center;
    gap: 12px;
  }
  .count {
    font-size: 12px;
  }
  .empty {
    padding: 30px;
    text-align: center;
    display: flex;
    flex-direction: column;
    gap: 8px;
  }
  .table-wrap {
    overflow: auto;
    max-height: calc(100vh - 160px);
  }
  table {
    width: 100%;
    border-collapse: collapse;
    font-size: 12.5px;
  }
  th {
    text-align: left;
    font-size: 11px;
    font-weight: 700;
    text-transform: uppercase;
    letter-spacing: 0.06em;
    color: var(--faint);
    padding: 10px 14px;
    border-bottom: 1px solid var(--border);
    position: sticky;
    top: 0;
    background: var(--panel);
    z-index: 1;
  }
  td {
    padding: 8px 14px;
    border-bottom: 1px solid var(--border);
    white-space: nowrap;
  }
  tr:last-child td {
    border-bottom: none;
  }
  .t-time {
    width: 90px;
  }
  .t-type {
    width: 70px;
  }
  .t-lat {
    width: 90px;
    text-align: right;
  }
  .ok-text {
    color: var(--ok);
  }
  .warn-text {
    color: var(--warn);
  }
</style>
