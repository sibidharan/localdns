<script lang="ts">
  // live = serving & settled · attention = running, work pending (amber) ·
  // stopped = gray · error = red — DNSOrb.State parity.
  export let state: "live" | "attention" | "stopped" | "error" = "stopped";
  export let size = 14;
</script>

<span
  class="orb {state}"
  style="width:{size}px;height:{size}px"
  role="img"
  aria-label="Server {state}"
></span>

<style>
  .orb {
    display: inline-block;
    border-radius: 50%;
    flex: none;
  }
  .orb.live {
    background: radial-gradient(circle at 35% 30%, #7df3e3, var(--accent) 60%);
    box-shadow: 0 0 10px rgba(45, 212, 191, 0.65);
    animation: pulse 2.4s ease-in-out infinite;
  }
  .orb.stopped {
    background: radial-gradient(circle at 35% 30%, #6b7a89, #46545f 65%);
  }
  .orb.attention {
    background: radial-gradient(circle at 35% 30%, #ffd77a, var(--warn) 60%);
    box-shadow: 0 0 10px rgba(210, 153, 34, 0.6);
    animation: pulse-amber 2.4s ease-in-out infinite;
  }
  @keyframes pulse-amber {
    0%,
    100% {
      box-shadow: 0 0 6px rgba(210, 153, 34, 0.4);
    }
    50% {
      box-shadow: 0 0 14px rgba(210, 153, 34, 0.8);
    }
  }
  .orb.error {
    background: radial-gradient(circle at 35% 30%, #ff8a80, var(--danger) 60%);
    box-shadow: 0 0 10px rgba(248, 81, 73, 0.55);
  }
  @keyframes pulse {
    0%,
    100% {
      box-shadow: 0 0 6px rgba(45, 212, 191, 0.45);
    }
    50% {
      box-shadow: 0 0 14px rgba(45, 212, 191, 0.85);
    }
  }
</style>
