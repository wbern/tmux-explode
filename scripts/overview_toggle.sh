#!/usr/bin/env bash
# Toggle between exploded (all panes tiled in one overview window) and
# unexploded (panes restored to their original windows).
#
# Runtime options (read fresh on each invocation):
#   @explode-mode         'active' (default) or 'all'
#   @explode-window-name  default 'overview'

set -euo pipefail

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

# tmux propagates the calling pane's context via run-shell, so plain
# display-message with no -t reads from the keybinding's source pane, not from
# whichever window the user has since focused. We deliberately do NOT consult
# TMUX_PANE here — that env var leaks from any parent shell that happens to be
# inside a different tmux session.
CURRENT=$(tmux display-message -p '#W')
CURRENT_WIN=$(tmux display-message -p '#{window_id}')
SESSION=$(tmux display-message -p '#{session_id}')

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
}

# Move restored windows back to their original indices. Two-phase: park each
# at a high index first to clear collisions, then place them in ascending
# order. Best-effort — if a target index is held by some unrelated window the
# user created (or moved into place) while exploded, we leave the restored
# window parked rather than evict the squatter.
restore_window_order() {
    [[ ${#new_window_for_index[@]} -eq 0 ]] && return 0

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
    # Refuse to clobber an existing window with the configured name. The user
    # can rename it or change @explode-window-name and try again.
    if tmux list-windows -t "$SESSION" -F '#{window_name}' | grep -Fxq "$OVERVIEW"; then
        tmux display-message "tmux_explode: window '$OVERVIEW' already exists; rename it or set @explode-window-name"
        return 1
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

    tmux select-layout -t "$SESSION:$OVERVIEW" tiled
}

if [[ "$CURRENT" == "$OVERVIEW" ]]; then
    unexplode
else
    explode
fi
