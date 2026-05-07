#!/usr/bin/env bash
# Toggle between exploded (overview window of tiled panes) and unexploded
# (panes restored to their origins).
#
# Runtime options (read fresh on each invocation):
#   @explode-scope        'all' (default), 'session', or 'server'
#   @explode-mode         'active' (default) or 'all'    [session/all scope only]
#   @explode-window-name  default 'overview'             [session scope only]

set -euo pipefail

# Layout builder lives in a sibling script so it can be unit-tested in
# isolation (build_layout.sh --self-test). We source it for its functions only;
# its CLI dispatch is guarded by a BASH_SOURCE check.
# shellcheck source=build_layout.sh
. "$(dirname "${BASH_SOURCE[0]}")/build_layout.sh"

get_tmux_option() {
    local option="$1"
    local default_value="$2"
    local value
    value=$(tmux show-option -gqv "$option")
    if [ -z "$value" ]; then
        echo "$default_value"
    else
        echo "$value"
    fi
}

OVERVIEW=$(get_tmux_option "@explode-window-name" "overview")
MODE=$(get_tmux_option "@explode-mode" "active")
SCOPE=$(get_tmux_option "@explode-scope" "all")

# Column-bias knobs read by build_layout via the environment. Empty values
# leave build_layout's own defaults in effect (40 cells, aspect 0.5). The
# user-facing aspect option takes a decimal like `0.5`; bash arithmetic
# can't multiply floats so we convert to tenths via awk and pass that to
# build_layout as EXPLODE_TARGET_ASPECT_X10.
#
# Both values are validated against strict numeric regexes before being
# exported. Bash arithmetic context (used downstream in build_layout) does
# recursive variable resolution — an unvalidated value like
# `a[$(rm -rf /tmp/x)]` would trigger command substitution at every
# `(( min_w < 1 ))` site. The validation here is the first line of defense;
# build_layout adds a second.
_min_w=$(get_tmux_option "@explode-min-pane-width" "")
_aspect=$(get_tmux_option "@explode-target-aspect" "")
if [[ -n "$_min_w" ]]; then
    if [[ "$_min_w" =~ ^[0-9]+$ ]]; then
        export EXPLODE_MIN_PANE_WIDTH="$_min_w"
    else
        tmux display-message "tmux_explode: ignoring malformed @explode-min-pane-width"
    fi
fi
if [[ -n "$_aspect" ]]; then
    if [[ "$_aspect" =~ ^[0-9]*\.?[0-9]+$ ]]; then
        _x10=$(awk -v v="$_aspect" 'BEGIN { printf "%d", v*10 + 0.5 }')
        export EXPLODE_TARGET_ASPECT_X10="$_x10"
        unset _x10
    else
        tmux display-message "tmux_explode: ignoring malformed @explode-target-aspect"
    fi
fi
unset _min_w _aspect

# tmux propagates the calling pane's context via run-shell, so plain
# display-message with no -t reads from the keybinding's source pane, not from
# whichever window the user has since focused. We deliberately do NOT consult
# TMUX_PANE here — that env var leaks from any parent shell that happens to be
# inside a different tmux session.
#
# The $TMUX env var (set by tmux for run-shell) is reliable in a different
# way: its trailing field is the firing session's numeric id. Pin
# display-message to that session so explode and unexplode agree on which
# session they target — server-scope explode can bump activity on other
# sessions (e.g. by setting their `status` option), and on a server with
# no attached client tmux's default-target resolution then drifts to the
# most-recently-active session, which is no longer the one that fired the
# binding.
TARGET_FLAG=()
if [[ -n "${TMUX:-}" ]]; then
    TARGET_FLAG=(-t "\$${TMUX##*,}")
fi
CURRENT=$(tmux display-message -p "${TARGET_FLAG[@]}" '#W')
CURRENT_WIN=$(tmux display-message -p "${TARGET_FLAG[@]}" '#{window_id}')
SESSION=$(tmux display-message -p "${TARGET_FLAG[@]}" '#{session_id}')
SESSION_NAME=$(tmux display-message -p "${TARGET_FLAG[@]}" '#{session_name}')

# Map from original window index to the new window id created during
# unexplode. Used to put restored windows back at their original positions.
declare -A new_window_for_index

unexplode() {
    # Build the set of currently-existing window ids so we can tell whether a
    # pane's origin window still survives.
    local live_windows
    live_windows=$(tmux list-windows -t "$SESSION" -F '#{window_id}')

    # Group panes by their @orig_window_id so siblings from the same source
    # window get reunited. Keying on the id (not the name) means two source
    # windows that happen to share a name don't get collapsed into one.
    declare -A first_pane_of_window
    local panes_data
    panes_data=$(tmux list-panes -t "$CURRENT_WIN" \
                 -F '#{pane_id}'$'\t''#{@orig_window}'$'\t''#{@orig_window_id}'$'\t''#{@orig_window_index}')

    while IFS=$'\t' read -r pane_id orig_name orig_id orig_index; do
        if [[ -z "${orig_name:-}" ]]; then
            # Pane has no recorded origin — break it out anonymously rather
            # than orphan it inside the overview window.
            tmux break-pane -d -s "$pane_id"
            continue
        fi

        if [[ -n "${orig_id:-}" ]] && grep -Fxq "$orig_id" <<< "$live_windows"; then
            # Original window still exists (active-mode common case): rejoin
            # rather than spawning a duplicate window of the same name.
            tmux join-pane -s "$pane_id" -t "$orig_id"
            continue
        fi

        # Source window is dead. Group by orig_id when we have one (so
        # same-name siblings stay distinct), falling back to name for panes
        # gathered by older versions that didn't record an id.
        local group_key="${orig_id:-name:$orig_name}"

        if [[ -z "${first_pane_of_window[$group_key]:-}" ]]; then
            tmux break-pane -d -s "$pane_id" -n "$orig_name"
            # The pane's id survives break-pane; record it as the join target
            # for any siblings from the same source window.
            first_pane_of_window[$group_key]="$pane_id"
            if [[ -n "${orig_index:-}" ]]; then
                local new_win_id
                new_win_id=$(tmux display-message -p -t "$pane_id" '#{window_id}')
                new_window_for_index[$orig_index]="$new_win_id"
            fi
        else
            tmux join-pane -s "$pane_id" -t "${first_pane_of_window[$group_key]}"
        fi
    done <<< "$panes_data"

    restore_window_order

    # Belt-and-braces sweep AFTER our own teardown finishes. Catches anything
    # we missed (a partial unexplode that bailed mid-loop, a strand in some
    # other session that was never our wall to begin with). Cheap when there's
    # nothing to find.
    sweep_stranded_overviews
}

# Move restored windows back to their original indices. Two-phase: park each
# at a high index first to clear collisions, then place them in ascending
# order. Best-effort — if a target index is held by some unrelated window the
# user created (or moved into place) while exploded, we leave the restored
# window parked rather than evict the squatter.
restore_window_order() {
    # `${arr[*]+x}` is the set -u-safe way to ask "any keys?" — bash 5.x
    # treats `${#arr[@]}` on a declared-but-empty associative array as an
    # unbound-variable error.
    [[ -z ${new_window_for_index[*]+x} ]] && return 0

    local indices park=9000 i win
    indices=$(printf '%s\n' "${!new_window_for_index[@]}" | sort -n)

    # Phase 1: park each restored window at a high index. Window ids are
    # stable across move-window, so the recorded ids stay valid.
    while IFS= read -r i; do
        win="${new_window_for_index[$i]}"
        tmux move-window -d -s "$win" -t "$SESSION:$park" 2>/dev/null || true
        park=$((park + 1))
    done <<< "$indices"

    # Phase 2: place each at its original index. If a squatter holds the
    # target, fall back to the next available slot at the end of the session
    # so the restored window doesn't get stranded at a five-digit index.
    while IFS= read -r i; do
        win="${new_window_for_index[$i]}"
        if ! tmux move-window -d -s "$win" -t "$SESSION:$i" 2>/dev/null; then
            tmux move-window -d -s "$win" -t "$SESSION:" 2>/dev/null || true
        fi
    done <<< "$indices"
}

explode() {
    # Single-wall semantics: tear down ANY existing wall server-wide
    # (in-place or session-scope) before we build a new one. Catches
    # both stale strands from crashed unexplodes AND a live wall in some
    # other session that would otherwise corrupt our build.
    sweep_existing_walls

    # Refuse to clobber an existing window with the configured name. The user
    # can rename it or change @explode-window-name and try again.
    if tmux list-windows -t "$SESSION" -F '#{window_name}' | grep -Fxq "$OVERVIEW"; then
        tmux display-message "tmux_explode: window '$OVERVIEW' already exists; rename it or set @explode-window-name"
        return 0
    fi

    tmux new-window -t "$SESSION:" -n "$OVERVIEW"

    # The new-window call creates a placeholder shell pane. We can't kill a
    # window's only pane, so gather one source pane first, then kill the
    # placeholder, then gather the rest. Re-tile between joins so panes don't
    # shrink past tmux's minimum size and trigger 'create pane failed'.
    local placeholder
    placeholder=$(tmux list-panes -t "$SESSION:$OVERVIEW" -F '#{pane_id}' | head -1)

    join_pane_into_overview() {
        local pane_id="$1" win_name="$2" win_id="$3" win_index="$4"
        tmux set-option -p -t "$pane_id" "@orig_window" "$win_name"
        tmux set-option -p -t "$pane_id" "@orig_window_id" "$win_id"
        tmux set-option -p -t "$pane_id" "@orig_window_index" "$win_index"
        tmux join-pane -s "$pane_id" -t "$SESSION:$OVERVIEW"
        tmux select-layout -t "$SESSION:$OVERVIEW" tiled
    }

    local placeholder_killed=0
    while IFS=$'\t' read -r win_id win_index win_name; do
        [[ "$win_name" == "$OVERVIEW" ]] && continue

        local pane_ids
        if [[ "$MODE" == "all" ]]; then
            pane_ids=$(tmux list-panes -t "$win_id" -F '#{pane_id}')
        else
            pane_ids=$(tmux list-panes -t "$win_id" -F '#{pane_id} #{?pane_active,1,0}' \
                       | awk '$2==1 {print $1}')
        fi

        while IFS= read -r pane_id; do
            [[ -z "$pane_id" ]] && continue
            join_pane_into_overview "$pane_id" "$win_name" "$win_id" "$win_index"
            if (( placeholder_killed == 0 )) && [[ -n "$placeholder" ]]; then
                tmux kill-pane -t "$placeholder"
                placeholder_killed=1
            fi
        done <<< "$pane_ids"
    done < <(tmux list-windows -t "$SESSION" -F '#{window_id}'$'\t''#{window_index}'$'\t''#{window_name}')

    apply_column_biased_layout "$SESSION:$OVERVIEW"
}

# ---------------------------------------------------------------------------
# Server scope: split the current window in place — every other session is
# added as a sibling pane (nested attach) alongside the original. Lets the
# user glance at N agents at once, zoom into one with the built-in
# `prefix + z`, and toggle off without disturbing those sessions or losing
# their place in this window.
# ---------------------------------------------------------------------------

# Socket the calling tmux server is listening on. We reach inside $TMUX
# (which has the form '<socket-path>,<server-pid>,<session-id>') so the
# nested `tmux attach` calls can target the SAME server with `-S`. Without
# this, an unset $TMUX would send them to the default socket and they'd find
# nothing.
SOCKET_PATH="${TMUX%%,*}"

# Per-tile labeling for the in-place wall. tmux 3.6a treats pane-border-style
# as window-scoped — `set-option -p` silently falls through to the window
# option — so we can't tint each border line independently. Instead we tint
# the LABEL on top of each border via inline `#[fg=...]` markup in
# pane-border-format, which IS evaluated per-pane against that pane's user
# options (@orig_session/@orig_window).
WALL_STYLE_ANCHOR=$(get_tmux_option "@explode-style-anchor" "fg=yellow,bold")
WALL_STYLE_LOCAL=$(get_tmux_option "@explode-style-local"  "fg=cyan")
WALL_STYLE_REMOTE=$(get_tmux_option "@explode-style-remote" "fg=magenta")

# Inside a tmux format `#{?...,then,else}` the comma is the case separator,
# so a literal comma (e.g. `fg=yellow,bold`) inside `#[...]` markup has to
# be escaped as `#,`. Escape the user-supplied style strings before
# substituting them in.
WALL_FMT_ANCHOR=${WALL_STYLE_ANCHOR//,/#,}
WALL_FMT_LOCAL=${WALL_STYLE_LOCAL//,/#,}
WALL_FMT_REMOTE=${WALL_STYLE_REMOTE//,/#,}

# Per-pane activity heatmap. The background poller (heatmap_poller.sh)
# writes a bucket glyph to per-pane `@heat`. Conditional `?@heat,...,` so
# the slot stays blank during the first tick before the poller has run,
# and stays blank entirely when the heatmap is disabled.
HEATMAP_ENABLED=$(get_tmux_option "@explode-heatmap" "on")
if [[ "$HEATMAP_ENABLED" != "off" ]]; then
    WALL_HEAT_PREFIX='#{?@heat,#{@heat} ,}'
else
    WALL_HEAT_PREFIX=''
fi

WALL_BORDER_FORMAT=" ${WALL_HEAT_PREFIX}#{?@orig_session,#[${WALL_FMT_REMOTE}]⇄ #{@orig_session},#{?@orig_window,#[${WALL_FMT_LOCAL}]◫ #{@orig_window},#[${WALL_FMT_ANCHOR}]◉ here}} "

# Save the current window-scoped border options on the wall window itself so
# unexplode can put them back. `-wqv` returns just the value (unwrapped — tmux
# wraps complex values in literal double quotes when show-options prints the
# `name "value"` form, and we don't want those quotes round-tripping into
# set-option). Empty value means unset on the window; the `unset` marker tells
# teardown to drop the override rather than pin a value.
setup_wall_borders() {
    local prev
    prev=$(tmux show-options -wqv -t "$CURRENT_WIN" pane-border-status 2>/dev/null || true)
    if [[ -n "$prev" ]]; then
        tmux set-option -w -t "$CURRENT_WIN" "@explode_saved_border_status" "set:$prev"
    else
        tmux set-option -w -t "$CURRENT_WIN" "@explode_saved_border_status" "unset"
    fi

    prev=$(tmux show-options -wqv -t "$CURRENT_WIN" pane-border-format 2>/dev/null || true)
    if [[ -n "$prev" ]]; then
        tmux set-option -w -t "$CURRENT_WIN" "@explode_saved_border_format" "set:$prev"
    else
        tmux set-option -w -t "$CURRENT_WIN" "@explode_saved_border_format" "unset"
    fi

    tmux set-option -w -t "$CURRENT_WIN" pane-border-status top
    tmux set-option -w -t "$CURRENT_WIN" pane-border-format "$WALL_BORDER_FORMAT"

    start_heatmap_poller
}

# Spawn the per-pane activity heatmap poller and stash its PID on the
# wall window. Belt-and-braces: kill any prior poller PID first in case
# explode crashed mid-tick last time and never reached teardown.
start_heatmap_poller() {
    [[ "$HEATMAP_ENABLED" == "off" ]] && return 0

    local prev_pid
    prev_pid=$(tmux show-options -wqv -t "$CURRENT_WIN" "@explode_heat_pid" 2>/dev/null || true)
    if [[ -n "$prev_pid" ]]; then
        kill "$prev_pid" 2>/dev/null || true
    fi

    local poller
    poller="$(dirname "${BASH_SOURCE[0]}")/heatmap_poller.sh"
    [[ -x "$poller" ]] || return 0

    # Per-tier dim styles are passed via env so we don't bloat the poller's
    # positional arg list every time we add a knob. Read fresh on each
    # toggle so option changes take effect without re-sourcing tmux.conf.
    local dim_cold style_cool style_cold tick
    dim_cold=$(get_tmux_option "@explode-dim-cold" "on")
    style_cool=$(get_tmux_option "@explode-style-cool" "bg=#0a0a18")
    style_cold=$(get_tmux_option "@explode-style-cold" "bg=#10102a")
    # Undocumented escape hatch — tests pin a tiny tick to deterministically
    # exercise the cleanup-vs-poller race. End users never need to touch it.
    tick=$(get_tmux_option "@explode-heat-tick" "2")

    # nohup + full redirection lets the poller outlive the run-shell
    # invocation that fired this script. disown makes sure bash isn't
    # tracking it as a job we'd block on.
    EXPLODE_DIM_COLD="$dim_cold" \
        EXPLODE_STYLE_COOL="$style_cool" \
        EXPLODE_STYLE_COLD="$style_cold" \
        nohup bash "$poller" "$SOCKET_PATH" "$CURRENT_WIN" "$tick" </dev/null >/dev/null 2>&1 &
    local pid=$!
    disown 2>/dev/null || true
    tmux set-option -w -t "$CURRENT_WIN" "@explode_heat_pid" "$pid"
}

# Send SIGTERM and wait for $1 to actually exit. SIGTERM is async —
# without waiting, callers can race a poller's final tick (re-applying
# a `bg=#…` style after we've cleared it). Polls `kill -0` in 100ms
# bursts up to ~1s, then SIGKILLs as a backstop so a wedged process
# can't deadlock teardown.
kill_and_wait() {
    local pid="$1" _
    [[ -z "$pid" ]] && return 0
    kill "$pid" 2>/dev/null || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        kill -0 "$pid" 2>/dev/null || return 0
        sleep 0.1
    done
    kill -9 "$pid" 2>/dev/null || true
    for _ in 1 2 3 4 5; do
        kill -0 "$pid" 2>/dev/null || return 0
        sleep 0.1
    done
}

# Stop the poller and wipe per-pane heat markers so panes that get
# rejoined to their origin window don't carry stale @heat / @pane_*
# options into a non-walled context.
stop_heatmap_poller() {
    local pid
    pid=$(tmux show-options -wqv -t "$CURRENT_WIN" "@explode_heat_pid" 2>/dev/null || true)
    kill_and_wait "$pid"
    tmux set-option -w -u -t "$CURRENT_WIN" "@explode_heat_pid" 2>/dev/null || true

    # Belt-and-braces wipe of the EPHEMERAL markers on every pane still in
    # CURRENT_WIN (typically just the anchor — locals/remotes have already
    # been moved/killed by unexplode_inplace's loop, which also wipes
    # these). @pane_last_change and @pane_first_sight are intentionally
    # preserved here so a re-explode reflects time elapsed during the gap.
    local pane_id
    while IFS= read -r pane_id; do
        [[ -z "$pane_id" ]] && continue
        tmux set-option -p -u -t "$pane_id" "@pane_last_hash" 2>/dev/null || true
        tmux set-option -p -u -t "$pane_id" "@heat" 2>/dev/null || true
        tmux set-option -p -u -t "$pane_id" "@heat_style" 2>/dev/null || true
        tmux select-pane -t "$pane_id" -P "default" 2>/dev/null || true
    done < <(tmux list-panes -t "$CURRENT_WIN" -F '#{pane_id}' 2>/dev/null || true)
}

teardown_wall_borders() {
    # Stop the poller BEFORE we tear down per-pane markers so a final tick
    # can't race with the unset and re-set @heat on a pane that's about to
    # be broken/joined back to its origin window.
    stop_heatmap_poller

    local saved
    saved=$(tmux show-options -w -t "$CURRENT_WIN" -v "@explode_saved_border_status" 2>/dev/null || true)
    if [[ "$saved" == set:* ]]; then
        tmux set-option -w -t "$CURRENT_WIN" pane-border-status "${saved#set:}"
    elif [[ "$saved" == "unset" ]]; then
        tmux set-option -w -u -t "$CURRENT_WIN" pane-border-status 2>/dev/null || true
    fi
    tmux set-option -w -u -t "$CURRENT_WIN" "@explode_saved_border_status" 2>/dev/null || true

    saved=$(tmux show-options -w -t "$CURRENT_WIN" -v "@explode_saved_border_format" 2>/dev/null || true)
    if [[ "$saved" == set:* ]]; then
        tmux set-option -w -t "$CURRENT_WIN" pane-border-format "${saved#set:}"
    elif [[ "$saved" == "unset" ]]; then
        tmux set-option -w -u -t "$CURRENT_WIN" pane-border-format 2>/dev/null || true
    fi
    tmux set-option -w -u -t "$CURRENT_WIN" "@explode_saved_border_format" 2>/dev/null || true
}

# Bias a window's layout toward more columns of taller panes than tmux's
# built-in `tiled` produces. Reads window dimensions, lists panes in DFS-ish
# order, asks build_layout for a column-biased string, applies it, and
# verifies the resulting #{window_layout} matches what we sent (defends
# against tmux's silent no-op on pane-count mismatch and other off-by-ones).
# Falls back to `tiled` on any failure so the toggle never dead-ends with a
# stack of zero-cell panes.
apply_column_biased_layout() {
    local target="$1"

    # Opt-out: users who prefer tmux's built-in tiled (squarish) layout.
    local style
    style=$(get_tmux_option "@explode-layout" "columns")
    if [[ "$style" == "tiled" ]]; then
        tmux select-layout -t "$target" tiled
        return 0
    fi

    local fallback_reason=""
    local sx sy pane_ids
    sx=$(tmux display-message -p -t "$target" '#{window_width}' 2>/dev/null || true)
    sy=$(tmux display-message -p -t "$target" '#{window_height}' 2>/dev/null || true)
    pane_ids=$(tmux list-panes -t "$target" -F '#{pane_id}' 2>/dev/null || true)

    if [[ -z "$sx" || -z "$sy" ]]; then
        fallback_reason="no window dims"
    elif [[ -z "$pane_ids" ]]; then
        fallback_reason="no panes"
    fi

    local layout="" got=""
    if [[ -z "$fallback_reason" ]]; then
        local -a pids=()
        while IFS= read -r p; do pids+=("$p"); done <<< "$pane_ids"
        if ! layout=$(build_layout "$sx" "$sy" "${pids[@]}" 2>/dev/null); then
            fallback_reason="build_layout failed"
        elif ! tmux select-layout -t "$target" "$layout" 2>/dev/null; then
            fallback_reason="tmux rejected layout"
        else
            # tmux silently truncates layouts when the pane count doesn't
            # match the leaf count — verify via checksum read-back.
            got=$(tmux display-message -p -t "$target" '#{window_layout}' 2>/dev/null || true)
            if [[ -z "$got" || "${layout%%,*}" != "${got%%,*}" ]]; then
                fallback_reason="checksum drift"
            fi
        fi
    fi

    if [[ -n "$fallback_reason" ]]; then
        tmux select-layout -t "$target" tiled
        # Surface the fallback so silent regressions don't masquerade as
        # "the heuristic just decided to look tiled today".
        tmux display-message "tmux_explode: column-bias fallback ($fallback_reason)"
    fi
}

# Tear down a single stranded overview window. Walks its panes and undoes
# what explode (session-scope) did: nested-attach panes get killed
# (terminating their inner `tmux attach`, NOT the inner session itself),
# local-origin panes rejoin their source window if it still exists or
# break out anonymously if not. Then the now-empty overview window itself
# is killed.
#
# Refuses to act when killing this window would destroy the session it
# lives in (no other windows survive). Tolerates per-pane failures so one
# stuck pane doesn't strand the rest.
#
# Caller is responsible for verifying this IS a stranded artifact (right
# name + carries our markers + no client viewing) — we re-check the
# fallback-window guard but otherwise trust the caller.
teardown_stranded_overview() {
    local wid="$1" sess="$2"

    local fallback_wid
    fallback_wid=$(tmux list-windows -t "$sess" -F '#{window_id}' 2>/dev/null \
                   | grep -Fxv "$wid" | head -1 || true)
    [[ -z "$fallback_wid" ]] && return 0

    local live_windows
    live_windows=$(tmux list-windows -t "$sess" -F '#{window_id}' 2>/dev/null || true)

    # If this window is currently active in the session, point the session
    # at the fallback BEFORE we kill it — otherwise tmux picks an arbitrary
    # successor (and any inner attach pane targeting `sess` ends up looking
    # at whatever happens to be the new active window).
    local active_wid
    active_wid=$(tmux display-message -p -t "$sess" '#{window_id}' 2>/dev/null || true)
    if [[ "$active_wid" == "$wid" ]]; then
        tmux select-window -t "$fallback_wid" 2>/dev/null || true
    fi

    local SEP='|'
    local pane_id orig_session orig_name orig_id
    while IFS="$SEP" read -r pane_id orig_session orig_name orig_id; do
        [[ -z "$pane_id" ]] && continue

        # Wipe ephemeral wall markers before any pane move so they don't
        # follow a local pane back to its origin window.
        tmux set-option -p -u -t "$pane_id" "@pane_last_hash" 2>/dev/null || true
        tmux set-option -p -u -t "$pane_id" "@heat" 2>/dev/null || true
        tmux set-option -p -u -t "$pane_id" "@heat_style" 2>/dev/null || true
        tmux select-pane -t "$pane_id" -P "default" 2>/dev/null || true

        if [[ -n "${orig_session:-}" ]]; then
            tmux kill-pane -t "$pane_id" 2>/dev/null || true
            continue
        fi

        if [[ -z "${orig_name:-}" ]]; then
            # Untagged pane — could be the placeholder shell from new-window
            # or something the user added. Break it out so we don't kill
            # potentially-real work; the user can deal with the orphan.
            tmux break-pane -d -s "$pane_id" 2>/dev/null || true
            continue
        fi

        if [[ -n "${orig_id:-}" ]] && grep -Fxq "$orig_id" <<< "$live_windows"; then
            tmux join-pane -s "$pane_id" -t "$orig_id" 2>/dev/null || true
            continue
        fi

        tmux break-pane -d -s "$pane_id" -n "$orig_name" 2>/dev/null || true
    done < <(tmux list-panes -t "$wid" \
             -F "#{pane_id}${SEP}#{@orig_session}${SEP}#{@orig_window}${SEP}#{@orig_window_id}" 2>/dev/null)

    # If killing the last pane already collapsed the window (tmux destroys a
    # window when its last pane dies), there's nothing left to do. The
    # existence probe also guards the next list-panes from failing under
    # pipefail and tripping set -e on the assignment below.
    if ! tmux list-windows -t "$sess" -F '#{window_id}' 2>/dev/null \
            | grep -Fxq "$wid"; then
        return 0
    fi

    # Otherwise some pane teardown failed and survivors remain. Leave the
    # window so the user can see the artifact rather than us silently
    # destroying potentially-recoverable panes — kill ONLY if we somehow
    # ended at zero (shouldn't normally hit this path).
    local remaining
    remaining=$(tmux list-panes -t "$wid" -F . 2>/dev/null | wc -l | tr -d ' ' || true)
    if [[ "$remaining" == "0" ]]; then
        tmux kill-window -t "$wid" 2>/dev/null || true
    fi
}

# Tear down a single in-place wall window (server/all scope) without
# killing the window itself — the wall lives inside a regular user
# window, so we restore the border options and dismantle the artifacts
# but leave the user's window intact.
#
# Mirrors unexplode_inplace's body but parameterized on (wid, sess) so
# it works against an arbitrary wall in any session — the version sweep
# uses to clean a wall left up in some other session before we build
# our own. Skips restore_window_order (the per-session window-index
# bookkeeping is a luxury for the user's CURRENT toggle and would need
# a much wider parameterization).
teardown_inplace_wall() {
    local wid="$1" sess="$2"

    # Stop the poller FIRST so a final tick can't race with our pane
    # marker wipes. See kill_and_wait for why we wait on exit.
    local pid
    pid=$(tmux show-options -wqv -t "$wid" "@explode_heat_pid" 2>/dev/null || true)
    kill_and_wait "$pid"
    tmux set-option -w -u -t "$wid" "@explode_heat_pid" 2>/dev/null || true

    local live_windows
    live_windows=$(tmux list-windows -t "$sess" -F '#{window_id}' 2>/dev/null || true)

    declare -A first_pane_of_window=()
    local now_ts
    now_ts=$(date +%s)

    local SEP='|'
    local pane_id orig_session saved orig_name orig_id orig_index last_change saved_ws
    while IFS="$SEP" read -r pane_id orig_session saved orig_name orig_id orig_index last_change saved_ws; do
        [[ -z "$pane_id" ]] && continue

        tmux set-option -p -u -t "$pane_id" "@pane_last_hash" 2>/dev/null || true
        tmux set-option -p -u -t "$pane_id" "@heat" 2>/dev/null || true
        tmux set-option -p -u -t "$pane_id" "@heat_style" 2>/dev/null || true
        tmux select-pane -t "$pane_id" -P "default" 2>/dev/null || true

        if [[ -n "${orig_session:-}" ]]; then
            if [[ -n "${last_change:-}" ]] \
               && [[ "$last_change" =~ ^[0-9]+$ ]] \
               && (( last_change > 0 && last_change <= now_ts )); then
                tmux set-option -t "$orig_session" "@explode_last_change" "$last_change" 2>/dev/null || true
            fi

            if [[ "${saved:-}" == "unset" ]]; then
                tmux set-option -u -t "$orig_session" status 2>/dev/null || true
            elif [[ "${saved:-}" == set:* ]]; then
                tmux set-option -t "$orig_session" status "${saved#set:}" 2>/dev/null || true
            fi

            if [[ "${saved_ws:-}" == "unset" ]]; then
                tmux set-option -u -t "$orig_session" window-size 2>/dev/null || true
            elif [[ "${saved_ws:-}" == set:* ]]; then
                tmux set-option -t "$orig_session" window-size "${saved_ws#set:}" 2>/dev/null || true
            fi

            tmux kill-pane -t "$pane_id" 2>/dev/null || true
            continue
        fi

        # No @orig_window: original anchor pane (or something the user
        # added that we never gathered). Leave in place.
        [[ -z "${orig_name:-}" ]] && continue

        if [[ -n "${orig_id:-}" ]] && grep -Fxq "$orig_id" <<< "$live_windows"; then
            tmux join-pane -s "$pane_id" -t "$orig_id" 2>/dev/null || true
            continue
        fi

        local group_key="${orig_id:-name:$orig_name}"
        if [[ -z "${first_pane_of_window[$group_key]:-}" ]]; then
            tmux break-pane -d -s "$pane_id" -n "$orig_name" 2>/dev/null || true
            first_pane_of_window[$group_key]="$pane_id"
        else
            tmux join-pane -s "$pane_id" -t "${first_pane_of_window[$group_key]}" 2>/dev/null || true
        fi
    done < <(tmux list-panes -t "$wid" \
             -F "#{pane_id}${SEP}#{@orig_session}${SEP}#{@orig_session_status}${SEP}#{@orig_window}${SEP}#{@orig_window_id}${SEP}#{@orig_window_index}${SEP}#{@pane_last_change}${SEP}#{@orig_session_window_size}" 2>/dev/null)

    # Restore window-scoped border options. Both keys: `set:VALUE` means
    # the user had it pinned to VALUE before we touched it; `unset` means
    # they were inheriting the global default (drop the override with -u).
    local saved_status saved_format
    saved_status=$(tmux show-options -wqv -t "$wid" "@explode_saved_border_status" 2>/dev/null || true)
    if [[ "$saved_status" == set:* ]]; then
        tmux set-option -w -t "$wid" pane-border-status "${saved_status#set:}" 2>/dev/null || true
    elif [[ "$saved_status" == "unset" ]]; then
        tmux set-option -w -u -t "$wid" pane-border-status 2>/dev/null || true
    fi
    tmux set-option -w -u -t "$wid" "@explode_saved_border_status" 2>/dev/null || true

    saved_format=$(tmux show-options -wqv -t "$wid" "@explode_saved_border_format" 2>/dev/null || true)
    if [[ "$saved_format" == set:* ]]; then
        tmux set-option -w -t "$wid" pane-border-format "${saved_format#set:}" 2>/dev/null || true
    elif [[ "$saved_format" == "unset" ]]; then
        tmux set-option -w -u -t "$wid" pane-border-format 2>/dev/null || true
    fi
    tmux set-option -w -u -t "$wid" "@explode_saved_border_format" 2>/dev/null || true
}

# Find any explode wall already up on the server (in-place or session-
# scope) and tear it down before we build a new one. The user's "single
# wall server-wide" semantics: a wall live in session A while you toggle
# in session B was making a mess of B's new wall — nested attaches
# inheriting A's `overview` window, tile counts blowing past the
# column-bias layout's pane count, the screenshot-with-tiny-corner-tiles
# bug.
#
# Detection per window (other than CURRENT_WIN):
#   - In-place wall: window option @explode_saved_border_status is set
#     AND at least one pane carries @orig_session/@orig_window. Calls
#     teardown_inplace_wall — keeps the user's window, restores borders,
#     dismantles only the artifacts.
#   - Session-scope wall: window name == @explode-window-name AND at
#     least one pane carries artifacts. Calls teardown_stranded_overview
#     — kills the dedicated overview window once empty.
#
# Skips CURRENT_WIN (we're about to use that window — and the upstream
# `inplace_explode_active` guard already routes a re-toggle on a wall
# window into unexplode rather than into us).
#
# Deliberately does NOT skip walls being viewed by clients — the user
# explicitly asked for one wall at a time. `sweep_stranded_overviews`
# keeps its viewer-aware safety for the post-unexplode belt-and-braces
# pass; that's a different regime (cleaning leftovers, not making room).
#
# Idempotent. Cheap when there's nothing to find.
sweep_existing_walls() {
    local sess
    while IFS= read -r sess; do
        [[ -z "$sess" ]] && continue

        local wid wname
        while IFS=$'\t' read -r wid wname; do
            [[ -z "$wid" || "$wid" == "$CURRENT_WIN" ]] && continue

            local has_artifacts
            has_artifacts=$(tmux list-panes -t "$wid" \
                            -F '#{@orig_session}#{@orig_window}' 2>/dev/null \
                            | grep -v '^$' | head -1 || true)
            [[ -z "$has_artifacts" ]] && continue

            local saved_status
            saved_status=$(tmux show-options -wqv -t "$wid" \
                           "@explode_saved_border_status" 2>/dev/null || true)
            if [[ -n "$saved_status" ]]; then
                teardown_inplace_wall "$wid" "$sess"
                continue
            fi

            if [[ "$wname" == "$OVERVIEW" ]]; then
                teardown_stranded_overview "$wid" "$sess"
                continue
            fi

            # Artifacts present but no recognizable wall shape (window
            # not named OVERVIEW and no saved-border marker). Could be a
            # partial state we don't own — leave it alone rather than
            # silently destroy unknown panes.
        done < <(tmux list-windows -t "$sess" \
                 -F '#{window_id}'$'\t''#{window_name}' 2>/dev/null)
    done < <(tmux list-sessions -F '#{session_name}' 2>/dev/null)
}

# Walk every session on the server and tear down any window named like
# our @explode-window-name that carries our artifact markers AND is not
# currently being viewed by any client. Defensive cleanup for two
# failure modes:
#   1. A previous session-scope explode whose unexplode never ran (agent
#      died, kill-server, manual kill-pane on the toggle, etc.). The
#      stranded `overview` window then gets inherited by a future nested
#      attach in some other session's wall, mis-rendering tiles.
#   2. Any other state we may have left behind across the server that we
#      can detect from our own markers.
#
# "Currently viewed" = some client's #{client_window} == this window's id.
# Other clients on the same session but a different window are NOT a
# reason to skip — the overview is dormant from their perspective. This
# is intentionally more aggressive than a "is anyone attached to the
# session" check; the user explicitly asked for exhaustive cleanup.
#
# In-place walls (server/all scope) live inside regular user windows,
# never named OVERVIEW, so the name filter naturally protects them.
#
# Idempotent. Cheap when there's nothing to clean (just lists windows).
sweep_stranded_overviews() {
    # Build the set of window ids currently being viewed by some client.
    # `list-clients` with no -t argument returns clients across the whole
    # server, so one call covers every session.
    local viewed
    viewed=$(tmux list-clients -F '#{client_window}' 2>/dev/null || true)

    local sess
    while IFS= read -r sess; do
        [[ -z "$sess" ]] && continue

        local wid wname
        while IFS=$'\t' read -r wid wname; do
            [[ -z "$wid" || "$wname" != "$OVERVIEW" ]] && continue

            local has_artifacts
            has_artifacts=$(tmux list-panes -t "$wid" \
                            -F '#{@orig_session}#{@orig_window}' 2>/dev/null \
                            | grep -v '^$' | head -1 || true)
            [[ -z "$has_artifacts" ]] && continue

            if [[ -n "$viewed" ]] && grep -Fxq "$wid" <<< "$viewed"; then
                continue
            fi

            teardown_stranded_overview "$wid" "$sess"
        done < <(tmux list-windows -t "$sess" \
                 -F '#{window_id}'$'\t''#{window_name}' 2>/dev/null)
    done < <(tmux list-sessions -F '#{session_name}' 2>/dev/null)
}

add_session_attach_pane() {
    local name="$1"

    # Read & consume any saved last_change from a previous wall cycle so the
    # heatmap bucket reflects time elapsed during the gap instead of
    # restarting at ⚪. SINGLE-SHOT (unset after read) so a stale value
    # can't pin every future tile to "stale" if the user stops using the
    # wall. VALIDATE before trusting — when in doubt, drop it and let the
    # new attach pane start fresh:
    #   - must be a positive integer (rejects garbage strings),
    #   - must not be in the future (clock skew / corruption),
    #   - must not be older than ~30 days (would round to ❄ anyway, and
    #     a value that old is more likely corruption than reality).
    local saved_change=""
    saved_change=$(tmux show-options -qv -t "$name" "@explode_last_change" 2>/dev/null || true)
    tmux set-option -u -t "$name" "@explode_last_change" 2>/dev/null || true
    if [[ -n "$saved_change" ]]; then
        if [[ ! "$saved_change" =~ ^[0-9]+$ ]] || (( saved_change <= 0 )); then
            saved_change=""
        else
            local _now _age
            _now=$(date +%s)
            _age=$(( _now - saved_change ))
            if (( _age < 0 || _age > 2592000 )); then
                saved_change=""
            fi
            unset _now _age
        fi
    fi

    # Snapshot the target session's status setting so we can restore it
    # on unexplode. show-options without -g returns ONLY session-local
    # values — if empty, the session is inheriting the global default
    # and we record an "unset" marker so we know to re-inherit later.
    local saved status_line
    saved=""
    status_line=$(tmux show-options -t "$name" status 2>/dev/null || true)
    if [[ -n "$status_line" ]]; then
        saved=${status_line#status }
        saved="set:$saved"
    else
        saved="unset"
    fi
    tmux set-option -t "$name" status off

    # Snapshot the inner session's window-size and force `smallest` while
    # the wall is up. Default `latest` sizes inner windows to the most
    # recently active client — usually the user's main client (e.g.
    # 214x78), not the small wall tile (e.g. 42x38). Result: the inner
    # TUI keeps painting at the big size, but the tile only shows the
    # top-left slice; new output appears off-screen ("moves but not at
    # the bottom"). `smallest` reflows the inner window to the tile's
    # actual dimensions so streaming output stays visible. Round-trip
    # via the same set:VALUE / unset marker pattern as `status`.
    local saved_ws ws_line
    saved_ws=""
    ws_line=$(tmux show-options -t "$name" window-size 2>/dev/null || true)
    if [[ -n "$ws_line" ]]; then
        saved_ws=${ws_line#window-size }
        saved_ws="set:$saved_ws"
    else
        saved_ws="unset"
    fi
    tmux set-option -t "$name" window-size smallest 2>/dev/null || true

    # printf %q quotes session names (and the socket path) safely for the
    # shell that tmux spawns under the new pane. The leading `unset TMUX`
    # is what lets tmux nest — split-window's `-e TMUX` flag is unreliable
    # across versions (3.6a leaves the var set; some readings of -e treat
    # it as "set to empty" rather than "unset"), so we do the unset in
    # the shell where it's portable.
    local q_name q_sock cmd
    q_name=$(printf '%q' "$name")
    q_sock=$(printf '%q' "$SOCKET_PATH")
    cmd="unset TMUX; exec tmux -S $q_sock attach -t $q_name"

    local new_pane
    new_pane=$(tmux split-window -t "$CURRENT_WIN" \
               -P -F '#{pane_id}' "$cmd")

    tmux set-option -p -t "$new_pane" "@orig_session" "$name"
    tmux set-option -p -t "$new_pane" "@orig_session_status" "$saved"
    tmux set-option -p -t "$new_pane" "@orig_session_window_size" "$saved_ws"

    # Stamp the validated saved timestamp on the new pane so the heatmap
    # poller picks up the prior bucket on its first tick. No-op when the
    # session has no prior history (first-ever wall against this session,
    # or saved value failed validation).
    if [[ -n "$saved_change" ]]; then
        tmux set-option -p -t "$new_pane" "@pane_last_change" "$saved_change" 2>/dev/null || true
    fi

    # Re-tile between joins so panes don't shrink past tmux's minimum
    # size and trigger 'create pane failed'.
    tmux select-layout -t "$CURRENT_WIN" tiled
}

other_session_names() {
    local s
    while IFS= read -r s; do
        [[ -z "$s" || "$s" == "$SESSION_NAME" ]] && continue
        printf '%s\n' "$s"
    done < <(tmux list-sessions -F '#{session_name}')
}

explode_server() {
    # Single-wall sweep BEFORE we attach into anything. Tears down any
    # other wall on the server (in-place or session-scope) so a sibling
    # session's wall can't have its overview window inherited by our
    # nested attach (double-nesting whatever the old wall was attached
    # to), and so two simultaneous walls can't fight over layout space.
    sweep_existing_walls

    local others=()
    local s
    while IFS= read -r s; do
        others+=("$s")
    done < <(other_session_names)

    if (( ${#others[@]} == 0 )); then
        tmux display-message "tmux_explode: no other sessions to explode"
        return 0
    fi

    setup_wall_borders

    local name
    for name in "${others[@]}"; do
        add_session_attach_pane "$name"
    done

    apply_column_biased_layout "$CURRENT_WIN"
}

# ---------------------------------------------------------------------------
# Hybrid scope: pull in every pane on the server — current session's other
# windows get gathered like session scope, sibling sessions become nested
# attaches like server scope, all alongside the original pane in the calling
# window. One toggle, one wall, no overview tab.
# ---------------------------------------------------------------------------

explode_all() {
    # Same single-wall sweep as explode_server — any other wall on the
    # server is torn down first so this one has clean ground to build on.
    sweep_existing_walls

    # Look ahead — if there are no other windows in this session and no
    # other sessions on the server, there is nothing to gather. Bail before
    # we've touched any window options.
    local has_local=0 win_id win_index win_name s
    while IFS=$'\t' read -r win_id win_index win_name; do
        [[ "$win_id" == "$CURRENT_WIN" ]] && continue
        has_local=1
        break
    done < <(tmux list-windows -t "$SESSION" -F '#{window_id}'$'\t''#{window_index}'$'\t''#{window_name}')

    local has_remote=0
    while IFS= read -r s; do
        has_remote=1
        break
    done < <(other_session_names)

    if (( has_local == 0 && has_remote == 0 )); then
        tmux display-message "tmux_explode: nothing else on the server to explode"
        return 0
    fi

    setup_wall_borders

    while IFS=$'\t' read -r win_id win_index win_name; do
        [[ "$win_id" == "$CURRENT_WIN" ]] && continue

        local pane_ids
        if [[ "$MODE" == "all" ]]; then
            pane_ids=$(tmux list-panes -t "$win_id" -F '#{pane_id}')
        else
            pane_ids=$(tmux list-panes -t "$win_id" -F '#{pane_id} #{?pane_active,1,0}' \
                       | awk '$2==1 {print $1}')
        fi

        while IFS= read -r pane_id; do
            [[ -z "$pane_id" ]] && continue
            tmux set-option -p -t "$pane_id" "@orig_window" "$win_name"
            tmux set-option -p -t "$pane_id" "@orig_window_id" "$win_id"
            tmux set-option -p -t "$pane_id" "@orig_window_index" "$win_index"
            tmux join-pane -s "$pane_id" -t "$CURRENT_WIN"
            tmux select-layout -t "$CURRENT_WIN" tiled
        done <<< "$pane_ids"
    done < <(tmux list-windows -t "$SESSION" -F '#{window_id}'$'\t''#{window_index}'$'\t''#{window_name}')

    while IFS= read -r s; do
        add_session_attach_pane "$s"
    done < <(other_session_names)

    apply_column_biased_layout "$CURRENT_WIN"
}

unexplode_inplace() {
    # Stop the heatmap poller FIRST so it can't re-apply a `bg=#…` style
    # between our per-pane wipe and a join-pane-back-to-origin (a local
    # pane joined back with the dim style still on it would carry the
    # stain into another window). teardown_wall_borders calls this again
    # at the end; the second pass is a no-op (PID already dead).
    stop_heatmap_poller

    local live_windows
    live_windows=$(tmux list-windows -t "$SESSION" -F '#{window_id}')

    declare -A first_pane_of_window

    # Pipe instead of tab. tab is whitespace, and `read` with IFS=tab
    # collapses consecutive tabs — a pane with empty leading fields (e.g.
    # a server pane with @orig_session set but no @orig_window) shifts its
    # later fields into the wrong variables.
    #
    # We previously used $'\x1f' (unit separator) for the same reason. tmux
    # 3.6 emits the byte verbatim in -F output, but tmux 3.4 (Ubuntu noble,
    # CI default) escapes non-printable bytes as the literal string `\NNN`,
    # so `IFS=$'\x1f' read` no longer splits — every field collapses into
    # pane_id and the loop's kill-pane / join-pane never fires. Pipe is
    # safe across versions and across all values we put in these fields:
    # pane/window ids, integers, session names, and "set:VALUE" / "unset"
    # for status and window-size (none of which contain `|`).
    local SEP='|'
    local panes_data
    panes_data=$(tmux list-panes -t "$CURRENT_WIN" \
                 -F "#{pane_id}${SEP}#{@orig_session}${SEP}#{@orig_session_status}${SEP}#{@orig_window}${SEP}#{@orig_window_id}${SEP}#{@orig_window_index}${SEP}#{@pane_last_change}${SEP}#{@orig_session_window_size}")

    local now_ts
    now_ts=$(date +%s)

    local pane_id orig_session saved orig_name orig_id orig_index last_change saved_ws
    while IFS="$SEP" read -r pane_id orig_session saved orig_name orig_id orig_index last_change saved_ws; do
        # Wipe ephemeral wall markers before any pane-moving action so they
        # don't follow a local pane back to its origin window. We deliberately
        # KEEP @pane_last_change and @pane_first_sight — those drive the
        # heatmap bucket calc, and preserving them lets a re-explode reflect
        # the time elapsed during the gap (a hot pane + 30-min gap → ❄ on
        # re-explode, correctly cooled). @pane_last_hash IS wiped so the
        # next first tick re-baselines the hash and doesn't mistake an
        # accumulated multi-day diff for a fresh change.
        tmux set-option -p -u -t "$pane_id" "@pane_last_hash" 2>/dev/null || true
        tmux set-option -p -u -t "$pane_id" "@heat" 2>/dev/null || true
        tmux set-option -p -u -t "$pane_id" "@heat_style" 2>/dev/null || true
        tmux select-pane -t "$pane_id" -P "default" 2>/dev/null || true

        if [[ -n "${orig_session:-}" ]]; then
            # Stash this remote tile's last-change timestamp on the inner
            # session so the next explode can re-stamp it on the new attach
            # pane. Validate before storing — a bogus value here would
            # corrupt every future wall against this session.
            if [[ -n "${last_change:-}" ]] \
               && [[ "$last_change" =~ ^[0-9]+$ ]] \
               && (( last_change > 0 && last_change <= now_ts )); then
                tmux set-option -t "$orig_session" "@explode_last_change" "$last_change" 2>/dev/null || true
            fi

            # Restore the target session's status setting. `unset` means the
            # session was inheriting the global default — use -u to drop the
            # session-local override rather than pinning a value.
            if [[ "${saved:-}" == "unset" ]]; then
                tmux set-option -u -t "$orig_session" status 2>/dev/null || true
            elif [[ "${saved:-}" == set:* ]]; then
                tmux set-option -t "$orig_session" status "${saved#set:}" 2>/dev/null || true
            fi

            # Restore window-size (forced to `smallest` while the wall was up).
            if [[ "${saved_ws:-}" == "unset" ]]; then
                tmux set-option -u -t "$orig_session" window-size 2>/dev/null || true
            elif [[ "${saved_ws:-}" == set:* ]]; then
                tmux set-option -t "$orig_session" window-size "${saved_ws#set:}" 2>/dev/null || true
            fi

            # Killing the pane terminates its `tmux attach` process, dropping
            # only the nested client we created — other clients attached to
            # that session stay put, and the session itself is untouched.
            # Tolerate already-dead panes (user closed one manually before
            # toggling off) so the loop still cleans up its siblings.
            tmux kill-pane -t "$pane_id" 2>/dev/null || true
            continue
        fi

        # No @orig_window means this is the user's original pane (or a
        # sibling they had open before exploding) — leave it in place.
        [[ -z "${orig_name:-}" ]] && continue

        if [[ -n "${orig_id:-}" ]] && grep -Fxq "$orig_id" <<< "$live_windows"; then
            tmux join-pane -s "$pane_id" -t "$orig_id"
            continue
        fi

        local group_key="${orig_id:-name:$orig_name}"

        if [[ -z "${first_pane_of_window[$group_key]:-}" ]]; then
            tmux break-pane -d -s "$pane_id" -n "$orig_name"
            first_pane_of_window[$group_key]="$pane_id"
            if [[ -n "${orig_index:-}" ]]; then
                local new_win_id
                new_win_id=$(tmux display-message -p -t "$pane_id" '#{window_id}')
                new_window_for_index[$orig_index]="$new_win_id"
            fi
        else
            tmux join-pane -s "$pane_id" -t "${first_pane_of_window[$group_key]}"
        fi
    done <<< "$panes_data"

    teardown_wall_borders
    restore_window_order

    # Belt-and-braces sweep across the whole server after our own teardown.
    # Catches strands in sibling sessions that we couldn't see during our own
    # in-place wall (those sessions had their `overview` window inherited by
    # our nested attach; killing the attach pane doesn't tear down their
    # overview window — the inner `unexplode` was never run). Cheap when
    # there's nothing to find.
    sweep_stranded_overviews
}

# An in-place explosion (server or hybrid scope) is in progress when any pane
# in the current window carries @orig_session or @orig_window — those markers
# survive a mid-flow @explode-scope flip, so unexplode works regardless.
inplace_explode_active() {
    local marker
    marker=$(tmux list-panes -t "$CURRENT_WIN" \
             -F '#{@orig_session}#{@orig_window}' 2>/dev/null \
             | grep -v '^$' | head -1 || true)
    [[ -n "$marker" ]]
}

if [[ "$CURRENT" == "$OVERVIEW" ]]; then
    unexplode
elif inplace_explode_active; then
    unexplode_inplace
else
    case "$SCOPE" in
        server) explode_server ;;
        all)    explode_all ;;
        *)      explode ;;
    esac
fi
