<script lang="ts">
  // live = serving & settled · attention = running, work pending (amber) ·
  // stopped = gray · error = red — DNSOrb.State parity.
  //
  // Energy contract (the native app idles at ~0.2% CPU; this port must too):
  // the breathing halo is a SEPARATE tiny pre-blurred layer animated on
  // opacity ONLY — never box-shadow, whose blur is recomputed every frame and
  // cost ~40% idle CPU under the software-rendered webview. The damage region
  // stays a few hundred pixels; blur is baked into a static radial gradient.
  export let state: "live" | "attention" | "stopped" | "error" = "stopped";
  export let size = 14;
</script>

<span class="orb-wrap" style="width:{size}px;height:{size}px">
  <span class="halo {state}"></span>
  <span class="orb {state}" role="img" aria-label="Server {state}"></span>
</span>

<style>
  .orb-wrap {
    position: relative;
    display: inline-block;
    flex: none;
  }
  .orb {
    position: absolute;
    inset: 0;
    border-radius: 50%;
  }
  .halo {
    position: absolute;
    inset: -55%;
    border-radius: 50%;
    opacity: 0;
    pointer-events: none;
  }
  .orb.live {
    background: radial-gradient(circle at 35% 30%, #7df3e3, var(--accent) 60%);
  }
  /* steps(12): a soft stepped fade — 12 repaints per 2.4s cycle instead of
     ~144 at 60fps; indistinguishable at these opacity deltas, ~90% cheaper
     under software rendering. */
  .halo.live {
    background: radial-gradient(circle, rgba(45, 212, 191, 0.55) 0%, rgba(45, 212, 191, 0) 70%);
    animation: breathe 2.4s steps(12) infinite;
  }
  .orb.attention {
    background: radial-gradient(circle at 35% 30%, #ffd77a, var(--warn) 60%);
  }
  .halo.attention {
    background: radial-gradient(circle, rgba(210, 153, 34, 0.6) 0%, rgba(210, 153, 34, 0) 70%);
    animation: breathe 2.4s steps(12) infinite;
  }
  .orb.stopped {
    background: radial-gradient(circle at 35% 30%, #6b7a89, #46545f 65%);
  }
  .orb.error {
    background: radial-gradient(circle at 35% 30%, #ff8a80, var(--danger) 60%);
  }
  .halo.error {
    background: radial-gradient(circle, rgba(248, 81, 73, 0.55) 0%, rgba(248, 81, 73, 0) 70%);
    opacity: 0.9;
  }
  @keyframes breathe {
    0%,
    100% {
      opacity: 0.35;
    }
    50% {
      opacity: 0.95;
    }
  }
  /* Battery / vestibular respect: a static glow instead of the pulse. */
  @media (prefers-reduced-motion: reduce) {
    .halo.live,
    .halo.attention {
      animation: none;
      opacity: 0.6;
    }
  }
  /* main.ts toggles data-hidden on <html> when the page is not visible. */
  :global(html[data-hidden]) .halo {
    animation-play-state: paused;
  }
</style>
