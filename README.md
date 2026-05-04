# tmux_explode

A tmux plugin that "explodes" every tmux window into a single tiled overview
window of split panes, then "unexplodes" them back to their original windows.
One keybinding to glance at every running terminal at once, then return to
focused work.

## Install

### Via [TPM](https://github.com/tmux-plugins/tpm) (recommended)

Add to your `~/.tmux.conf`:

```tmux
set -g @plugin 'wbern/tmux-explode'
```

Then `prefix + I` to install.

### Manual

```sh
git clone https://github.com/wbern/tmux-explode ~/.tmux/plugins/tmux-explode
```

Add to `~/.tmux.conf`:

```tmux
run-shell ~/.tmux/plugins/tmux-explode/tmux_explode.tmux
```

Reload tmux: `tmux source-file ~/.tmux.conf`.

## Usage

`prefix + O` toggles between the two modes:

- **Explode** — gather panes from every window into a new `overview` window,
  laid out tiled.
- **Unexplode** — break each pane back out, restoring the original window name.
  Panes that originated from the same source window are grouped back together.

## Configuration

All options are read fresh on each toggle, so changes take effect without
re-sourcing `tmux.conf`.

| Option                  | Default     | Description                                                          |
| ----------------------- | ----------- | -------------------------------------------------------------------- |
| `@explode-key`          | `O`         | Key bound under `prefix` to trigger the toggle.                      |
| `@explode-mode`         | `active`    | `active` = gather only the active pane of each window. `all` = sweep every pane. |
| `@explode-window-name`  | `overview`  | Name used for the overview window. Change if it collides with a window you already use. |

Example:

```tmux
set -g @plugin 'wbern/tmux-explode'
set -g @explode-key 'E'
set -g @explode-mode 'all'
set -g @explode-window-name 'glance'
```

## Behavior notes

- Above ~6 windows the tiled layout becomes cramped; `prefix + w`
  (`choose-tree -Zw`) is genuinely the better tool at that scale.
- Pane origin is tracked via the per-pane tmux user option `@orig_window`,
  set when the pane is gathered.
- If a window with the configured overview name already exists, explode is a
  no-op and shows a status-line message — rename the existing window or pick a
  different `@explode-window-name`.
- Automated visual snapshot tests run in CI on `ubuntu-latest`; also tested
  manually on tmux 3.6a (the version that ships via Homebrew on recent
  macOS).

## Development

The plugin is two files:

- `tmux_explode.tmux` — TPM entrypoint. Reads `@explode-key` and binds it.
- `scripts/overview_toggle.sh` — the toggle logic. Re-reads runtime options on
  every invocation.

Run `./tests/visual.sh` to exercise both modes plus the explode/unexplode
round-trip on an isolated tmux socket.

Issues and PRs welcome.

## License

MIT — see [LICENSE](LICENSE).
