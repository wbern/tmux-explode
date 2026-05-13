#!/usr/bin/env bash
# Fast-close binding installed by overview_toggle.sh while a wall is up.
# The binding passes `#{pane_id}` as $1 so tmux's format substitution
# resolves the firing tile at key-press time — we can't rely on
# `display-message -p` inside the script, because run-shell's default
# target drifts across other sessions on the server when no client is
# attached (or when multiple sessions are in play), which is exactly
# the configuration the wall creates.
#
# Refuses to kill the anchor tile (the one the toggle fired from) — losing
# it would strand the wall with no return point for unexplode. For added
# panes, kills the pane and re-tiles so the wall stays balanced.

set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/build_layout.sh"

active_pane="${1:-}"
if [[ -z "$active_pane" ]]; then
    active_pane=$(tmux display-message -p '#{pane_id}' 2>/dev/null || true)
fi
[[ -z "$active_pane" ]] && exit 0

active_win=$(tmux display-message -p -t "$active_pane" '#{window_id}' 2>/dev/null || true)
[[ -z "$active_win" ]] && exit 0

# Only operate on actual wall windows. Presence of @explode_saved_border_status
# is the same liveness marker setup_wall_borders writes.
wall_marker=$(tmux show-options -wqv -t "$active_win" "@explode_saved_border_status" 2>/dev/null || true)
if [[ -z "$wall_marker" ]]; then
    tmux display-message "tmux_explode: no wall here — use prefix x" 2>/dev/null || true
    exit 0
fi

# Anchor identification: every non-anchor tile carries either @orig_window
# (gathered from a local window) or @orig_session (nested attach). The
# anchor is the only pane without either marker.
orig_window=$(tmux show-options -pqv -t "$active_pane" "@orig_window" 2>/dev/null || true)
orig_session=$(tmux show-options -pqv -t "$active_pane" "@orig_session" 2>/dev/null || true)
if [[ -z "$orig_window" && -z "$orig_session" ]]; then
    tmux display-message "tmux_explode: refusing to close anchor — toggle to unexplode" 2>/dev/null || true
    exit 0
fi

# Magenta `⇄ <session>` tiles stashed the inner session's pre-wall
# `status` and `window-size` on this pane when the wall was built; the
# full unexplode loop reads those stashes and restores them BEFORE
# killing the attach (overview_toggle.sh:683-693). We have to mirror
# that here — once the pane is gone, the stash is unreachable, and the
# next toggle-off loop never touches the orphaned inner session.
# Without this, killing a single magenta tile would leave the inner
# session with `status off` and `window-size smallest`, breaking later
# attaches.
if [[ -n "$orig_session" ]]; then
    saved_status=$(tmux show-options -pqv -t "$active_pane" "@orig_session_status" 2>/dev/null || true)
    saved_ws=$(tmux show-options -pqv -t "$active_pane" "@orig_session_window_size" 2>/dev/null || true)
    if [[ "$saved_status" == "unset" ]]; then
        tmux set-option -u -t "$orig_session" status 2>/dev/null || true
    elif [[ "$saved_status" == set:* ]]; then
        tmux set-option -t "$orig_session" status "${saved_status#set:}" 2>/dev/null || true
    fi
    if [[ "$saved_ws" == "unset" ]]; then
        tmux set-option -u -t "$orig_session" window-size 2>/dev/null || true
    elif [[ "$saved_ws" == set:* ]]; then
        tmux set-option -t "$orig_session" window-size "${saved_ws#set:}" 2>/dev/null || true
    fi
    # Cross-cycle heatmap stash: persist this tile's last-change so the
    # next explode against the same session shows the correct bucket
    # instead of restarting from ⚪. Same validation rules as the
    # toggle's full-unexplode loop (digits only, not in the future).
    last_change=$(tmux show-options -pqv -t "$active_pane" "@pane_last_change" 2>/dev/null || true)
    now_ts=$(date +%s)
    if [[ -n "$last_change" && "$last_change" =~ ^[0-9]+$ ]] \
       && (( last_change > 0 && last_change <= now_ts )); then
        tmux set-option -t "$orig_session" "@explode_last_change" "$last_change" 2>/dev/null || true
    fi
fi

tmux kill-pane -t "$active_pane" 2>/dev/null || true

# Re-tile only if any panes remain — killing the last non-anchor leaves
# the anchor alone, which doesn't need a layout pass.
remaining=$(tmux list-panes -t "$active_win" 2>/dev/null | wc -l | tr -d ' ')
if [[ "$remaining" -lt 2 ]]; then
    exit 0
fi

layout_style=$(tmux show-option -gqv "@explode-layout" 2>/dev/null || true)
[[ -z "$layout_style" ]] && layout_style="columns"

if [[ "$layout_style" == "tiled" ]]; then
    tmux select-layout -t "$active_win" tiled 2>/dev/null || true
    exit 0
fi

# Honour the user's column-bias knobs on the re-tile so a wall with a
# customized @explode-min-pane-width / @explode-target-aspect doesn't
# silently fall back to build_layout's defaults after a close.
prepare_explode_layout_env

sx=$(tmux display-message -p -t "$active_win" '#{window_width}' 2>/dev/null || true)
sy=$(tmux display-message -p -t "$active_win" '#{window_height}' 2>/dev/null || true)
mapfile -t pids < <(tmux list-panes -t "$active_win" -F '#{pane_id}' 2>/dev/null || true)

if [[ -n "$sx" && -n "$sy" && ${#pids[@]} -gt 0 ]]; then
    if layout=$(build_layout "$sx" "$sy" "${pids[@]}" 2>/dev/null) \
       && tmux select-layout -t "$active_win" "$layout" 2>/dev/null; then
        exit 0
    fi
fi

tmux select-layout -t "$active_win" tiled 2>/dev/null || true
