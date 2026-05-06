# tmux_explode

A tmux plugin that "explodes" every tmux window into a single tiled overview
window of split panes, then "unexplodes" them back to their original windows.
One keybinding to glance at every running terminal at once, then return to
focused work.

![demo](docs/demo.gif)

(Server-scope wall: five sibling sessions tiled into one overview, recorded
in a Linux container. Reproduce with `docker build -f tests/Dockerfile.record
-t tmux-explode-record . && docker run --rm -it tmux-explode-record`.)

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

`prefix + O` toggles a tiled wall of every terminal on your tmux server and
back. By default the wall covers **everything**: panes from your current
session's other windows AND nested attaches to every other session, all
added alongside your original pane in the current window. Zoom into any
tile with `prefix + z`. Toggle off and the wall collapses — added panes are
killed, gathered panes return to their origin windows, and the session
you fired from is left exactly as it was.

Two narrower scopes are available for users who want a tighter view — set
`@explode-scope` to override the default:

- **`session`** — gather panes from the current session's windows into a
  new `overview` window. Other sessions are ignored.
- **`server`** — only nest-attach the *other* sessions, leaving your
  current session's other windows alone.

## Configuration

All options are read fresh on each toggle, so changes take effect without
re-sourcing `tmux.conf`.

| Option                  | Default     | Description                                                          |
| ----------------------- | ----------- | -------------------------------------------------------------------- |
| `@explode-key`          | `O`         | Key bound under `prefix` to trigger the toggle.                      |
| `@explode-scope`        | `all`       | `all` = current session's other windows AND nested attaches to every other session, in the current window. `session` = only the current session's windows (uses an `overview` tab). `server` = only nested attaches to other sessions, in the current window. |
| `@explode-mode`         | `active`    | `active` = gather only the active pane of each gathered window. `all` = sweep every pane. Applies to local-window gathering in `all` and `session` scopes; ignored when `@explode-scope = server`. |
| `@explode-window-name`  | `overview`  | Name used for the overview window in **session scope** only. `all` and `server` scopes split the current window in place and ignore this option. |
| `@explode-style-anchor` | `fg=yellow,bold` | Inline style for the anchor tile's border label (the pane the toggle fired from). In-place walls only. |
| `@explode-style-local`  | `fg=cyan`   | Inline style for tiles gathered from other windows of the current session. In-place walls only. |
| `@explode-style-remote` | `fg=magenta` | Inline style for nested-attach tiles pointing at sibling sessions. In-place walls only. |

Example:

```tmux
set -g @plugin 'wbern/tmux-explode'
set -g @explode-key 'E'
set -g @explode-mode 'all'
set -g @explode-window-name 'glance'
```

## Behavior notes

- Above ~6 windows/sessions the tiled layout becomes cramped; `prefix + w`
  (`choose-tree -Zw`) is genuinely the better tool at that scale.
- Pane origin is tracked via the per-pane tmux user option `@orig_window`
  (panes gathered from a window of the current session) or `@orig_session`
  (nested-attach panes pointing at another session), set when the pane is
  gathered. Default `all` scope uses both.
- If a window with the configured overview name already exists, explode is a
  no-op and shows a status-line message — rename the existing window or pick a
  different `@explode-window-name`.
- Automated visual snapshot tests run in CI on `ubuntu-latest`; also tested
  manually on tmux 3.6a (the version that ships via Homebrew on recent
  macOS).

### In-place wall notes (`all` and `server` scopes)

- The wall is built **in place** by splitting the calling window. Your
  original pane stays put as one tile; gathered panes and nested-session
  attaches are added alongside it. Toggling off restores everything — no
  extra tab to navigate, and a single-window session can never be
  collapsed by the toggle.
- Each tile gets a labelled border (`pane-border-status top`) so you can
  tell at a glance what's where: `◉ here` for the anchor pane (yellow),
  `◫ <window>` for a local pane gathered from another window of the
  current session (cyan), `⇄ <session>` for a nested attach into a
  sibling session (magenta). Override colours with the
  `@explode-style-*` options. Both `pane-border-status` and
  `pane-border-format` are saved before the wall goes up and restored on
  toggle-off.
- Added panes are tagged with the per-pane user option `@orig_session`
  (nested attaches) or `@orig_window` (panes gathered from windows of the
  current session). Toggle-off uses those tags to kill nested attaches and
  rejoin/break-pane local panes back to their origin window.
- Each nested-attach pane runs `tmux attach -t <session>` against the same
  socket. tmux's prefix collision is **not** worked around — to send
  `prefix` (default `C-b`) to a focused inner session, press it twice
  (`C-b C-b`).
- Inner sessions get their `status` option set to `off` while the wall is
  active so status bars don't stack inside each pane. The previous value is
  restored on toggle-off.
- [tmux-resurrect](https://github.com/tmux-plugins/tmux-resurrect) and
  [tmux-continuum](https://github.com/tmux-plugins/tmux-continuum) are the
  only real footgun: an autosave that fires while an in-place wall is
  exploded will capture the nested attaches and try to restore them on
  startup. Toggle the wall off before letting an autosave run, or pause
  continuum while you have one open.

## Development

The plugin is two files:

- `tmux_explode.tmux` — TPM entrypoint. Reads `@explode-key` and binds it.
- `scripts/overview_toggle.sh` — the toggle logic. Re-reads runtime options on
  every invocation.

Run `./tests/visual.sh` to exercise session scope (both `active` and `all`
modes), the session-scope round-trip, server scope across multiple sibling
sessions, the server-scope round-trip, and the default hybrid `all` scope
(local windows + sibling sessions in one wall) — all on an isolated tmux
socket.

For a live demo or to capture screenshots, use `./tests/demo.sh`:

```sh
./tests/demo.sh server attach                # build a wall and attach to it
./tests/demo.sh session capture /tmp/explode # headless: dump SVG + per-pane text
```

Capture mode also writes a colour-preserving HTML overview if
[`aha`](https://github.com/theZiz/aha) is installed (`brew install aha`).

Issues and PRs welcome.

## License

MIT — see [LICENSE](LICENSE).
