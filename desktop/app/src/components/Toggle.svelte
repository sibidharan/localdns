<script lang="ts">
  export let checked = false;
  export let disabled = false;
  export let label = "";
  export let onchange: (value: boolean) => void = () => {};

  function toggle() {
    if (disabled) return;
    onchange(!checked);
  }
</script>

<button
  type="button"
  class="switch"
  class:on={checked}
  {disabled}
  role="switch"
  aria-checked={checked}
  aria-label={label}
  on:click|stopPropagation={toggle}
>
  <span class="knob"></span>
</button>

<style>
  .switch {
    width: 36px;
    height: 21px;
    border-radius: 99px;
    background: #33404d;
    border: none;
    padding: 2px;
    display: inline-flex;
    align-items: center;
    transition: background 0.15s ease;
    flex: none;
  }
  .switch.on {
    background: var(--accent);
  }
  .switch:disabled {
    opacity: 0.4;
  }
  .knob {
    width: 17px;
    height: 17px;
    border-radius: 50%;
    background: #fff;
    transition: transform 0.15s ease;
    box-shadow: 0 1px 2px rgba(0, 0, 0, 0.35);
  }
  .switch.on .knob {
    transform: translateX(15px);
  }
</style>
