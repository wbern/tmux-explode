## [1.1.0](https://github.com/wbern/tmux-explode/compare/v1.0.5...v1.1.0) (2026-05-12)

### Features

* prefix X to fast-close a tile while a wall is up ([0334bf8](https://github.com/wbern/tmux-explode/commit/0334bf8608668e9169a5a59b15a0db6f26ac2519))

## [1.0.5](https://github.com/wbern/tmux-explode/compare/v1.0.4...v1.0.5) (2026-05-12)

### Bug Fixes

* **heatmap:** preserve active pane across bucket-style application ([d0302a2](https://github.com/wbern/tmux-explode/commit/d0302a2db50c0483322116916623b605e64dbdb8))

## [1.0.4](https://github.com/wbern/tmux-explode/compare/v1.0.3...v1.0.4) (2026-05-07)

### Bug Fixes

* **scripts:** allowlist @explode-style-anchor/local/remote values ([de66b73](https://github.com/wbern/tmux-explode/commit/de66b736dd95fe46f098fbfd16d5d21d18d0412b))

## [1.0.3](https://github.com/wbern/tmux-explode/compare/v1.0.2...v1.0.3) (2026-05-07)

### Bug Fixes

* **tests:** switch [tile labels] separator to pipe to match the script ([d1e64ad](https://github.com/wbern/tmux-explode/commit/d1e64ad051b82ce1bafe9d1d3cb7ef312d5dbe37))

## [1.0.2](https://github.com/wbern/tmux-explode/compare/v1.0.1...v1.0.2) (2026-05-07)

### Bug Fixes

* **scripts:** use printable separator that tmux 3.4 doesn't escape ([827eb40](https://github.com/wbern/tmux-explode/commit/827eb40f060e625a78aba153349cc6114ef6f0dd))

## [1.0.1](https://github.com/wbern/tmux-explode/compare/v1.0.0...v1.0.1) (2026-05-07)

### Bug Fixes

* **tests:** wait for socket release before next scenario ([90a1a51](https://github.com/wbern/tmux-explode/commit/90a1a5119f6563e893f3b7ddc3079e08d6a2507f))

# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Releases from `v1.0.1` onwards are produced automatically by
[semantic-release](https://github.com/semantic-release/semantic-release) from
[Conventional Commits](https://www.conventionalcommits.org/). Hand edits below
the auto-generated section may be overwritten.

<!-- semantic-release will insert new releases above this line -->

## [1.0.0] - 2026-05-07

First tagged release. Captures the work that landed before the project
adopted automated versioning.

### Added

- `prefix + O` toggles a tiled wall of every terminal on the tmux server and
  back. Default `all` scope covers the current session's other windows AND
  nested attaches to every other session, in the current window.
- Three scopes: `all` (default, hybrid), `session` (current session only,
  uses an `overview` window), `server` (other sessions only, in place).
- Two pane-gathering modes: `active` (only the active pane of each window)
  and `all` (every pane).
- Column-biased custom layout (default `columns`, set `@explode-layout
  tiled` for the old behaviour). Tiles default to ~2× tall as wide for
  reading streaming output, configurable via `@explode-target-aspect` and
  floored by `@explode-min-pane-width`.
- Per-tile labelled borders distinguishing the anchor pane (`◉ here`),
  local panes (`◫ <window>`), and nested-session attaches (`⇄ <session>`).
  Styles configurable via `@explode-style-anchor`, `@explode-style-local`,
  `@explode-style-remote`. Both `pane-border-status` and
  `pane-border-format` are saved and restored.
- Per-pane activity heatmap glyph (`⚪ 🔥 🌶 💤 ❄`) driven by a background
  poller (~2s tick). Bucket reflects time since the pane's last
  visible-buffer change, so quiet panes visibly cool without needing a
  fresh event. Disable with `@explode-heatmap off`.
- Cool/cold tiles get a faint navy `pane-style` wash so the eye skips
  parked panes. Disable with `@explode-dim-cold off`; override per-tier
  with `@explode-style-cool` / `@explode-style-cold`.
- Inner sessions get `status off` and `window-size smallest` while the
  wall is active, restored on toggle-off, so status bars don't stack and
  TUI output doesn't paint below the visible tile region.
- One-wall-server-wide invariant: toggling on tears down any other wall
  already up — in any session, in any scope — before building the new
  one. Sweeps stranded overview windows on every toggle.
- `./tests/demo.sh` for live attach or headless capture; Docker-based
  recording flow for the README GIF.

### Changed

- Wall layout default switched from tmux's built-in `tiled` to a
  column-biased custom layout. Set `@explode-layout tiled` to restore.

### Project

- MIT licensed.
- Visual snapshot tests run in CI on `ubuntu-latest`. Manually tested on
  tmux 3.6a (Homebrew on recent macOS).
- Requires bash 4+ (`mapfile`, `declare -A`).
- Local `commit-msg` hook rejects AI-attribution trailers.

[1.0.0]: https://github.com/wbern/tmux-explode/releases/tag/v1.0.0
