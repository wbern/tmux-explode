# tmux_explore

A tmux plugin that "explodes" all tmux windows into a single tiled view of split
panes, then "unexplodes" them back to their original windows. Useful for getting
a glance at every running terminal at once and then returning to focused work.

## Status

Early scaffold. The script below works as a starting point; the plugin polish,
tests, and packaging are still to be done.

## Design

Two modes, toggled with one keybinding (`prefix + O`):

- **Explode**: gather the active pane from every window into a new `overview`
  window, laid out tiled.
- **Unexplode**: detach each pane from the `overview` window and put it back as
  its own window with its original name.

State is tracked per-pane via a tmux user option `@orig_window`, set when a pane
is gathered. On unexplode, we read it back and restore the window name.

Caveats:
- Only the active pane of each window is gathered. Windows with multiple panes
  keep their other panes parked. Extending to sweep every pane is a 2-line
  change in the loop.
- Tiled layout becomes cramped above ~6 windows. Above that, `prefix + w`
  (`choose-tree -Zw`) is genuinely the better tool.

## Files

- `overview-toggle.sh` — the toggle script. Drop in `~/.tmux/`, `chmod +x`.
- `tmux.conf.snippet` — minimal config to wire it up.

## Original conversation context

This rig started from a conversation about Ghostty not having a "split all tabs
into panes" hotkey. tmux's `join-pane` / `break-pane` primitives can do it; this
project wraps them into a single toggle.

Quoting the relevant insight:

> No turnkey plugin for this exact toggle — but tmux has the primitives.
> The lazy, non-destructive option: `prefix + w` opens `choose-tree -Zw`.
> The "really merge them into splits" option: tmux has `join-pane` (move pane
> into another window) and `break-pane` (move pane out into its own window).
> No plugin wraps these into a one-key toggle, but it's a small script.

## Roadmap (see beads in `.beads/`)

1. Land the toggle script as a real tmux plugin (TPM-compatible)
2. Handle multi-pane windows (sweep all, not just active)
3. Test across tmux 3.0–3.6
4. README badges, install instructions, screenshots/gif
