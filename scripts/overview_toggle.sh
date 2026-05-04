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

CURRENT=$(tmux display-message -p '#W')

unexplode() {
    # Build the set of currently-existing window ids so we can tell whether a
    # pane's origin window still survives.
    local live_windows
    live_windows=$(tmux list-windows -F '#{window_id}')

    # Group panes by their @orig_window name, so siblings from the same source
    # window (in 'all' mode) end up reunited rather than spawning duplicates.
    declare -A first_pane_of_window
    local panes_data
    panes_data=$(tmux list-panes -F '#{pane_id}'$'\t''#{@orig_window}'$'\t''#{@orig_window_id}')

    while IFS=$'\t' read -r pane_id orig_name orig_id; do
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

        if [[ -z "${first_pane_of_window[$orig_name]:-}" ]]; then
            tmux break-pane -d -s "$pane_id" -n "$orig_name"
            # The pane's id survives break-pane; record it as the join target
            # for any siblings from the same source window.
            first_pane_of_window[$orig_name]="$pane_id"
        else
            tmux join-pane -s "$pane_id" -t "${first_pane_of_window[$orig_name]}"
        fi
    done <<< "$panes_data"
}

explode() {
    # Refuse to clobber an existing window with the configured name. The user
    # can rename it or change @explode-window-name and try again.
    if tmux list-windows -F '#{window_name}' | grep -Fxq "$OVERVIEW"; then
        tmux display-message "tmux_explode: window '$OVERVIEW' already exists; rename it or set @explode-window-name"
        return 1
    fi

    tmux new-window -n "$OVERVIEW"

    # Kill the placeholder pane up front. We can't kill a window's only pane,
    # so we leave a marker pane created from the first source-pane join below.
    # Instead, gather one pane to displace the placeholder, then kill it, then
    # gather the rest while re-tiling between joins so panes don't shrink past
    # tmux's minimum size and trigger 'create pane failed: pane too small'.
    local placeholder
    placeholder=$(tmux list-panes -t "$OVERVIEW" -F '#{pane_id}' | head -1)

    join_pane_into_overview() {
        local pane_id="$1" win_name="$2" win_id="$3"
        tmux set-option -p -t "$pane_id" "@orig_window" "$win_name"
        tmux set-option -p -t "$pane_id" "@orig_window_id" "$win_id"
        tmux join-pane -s "$pane_id" -t "$OVERVIEW"
        # Re-tile between joins so the next join has room to split.
        tmux select-layout -t "$OVERVIEW" tiled
    }

    local placeholder_killed=0
    while IFS=$'\t' read -r win_id win_name; do
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
            join_pane_into_overview "$pane_id" "$win_name" "$win_id"
            if (( placeholder_killed == 0 )) && [[ -n "$placeholder" ]]; then
                tmux kill-pane -t "$placeholder"
                placeholder_killed=1
            fi
        done <<< "$pane_ids"
    done < <(tmux list-windows -F '#{window_id}'$'\t''#{window_name}')

    tmux select-layout -t "$OVERVIEW" tiled
}

if [[ "$CURRENT" == "$OVERVIEW" ]]; then
    unexplode
else
    explode
fi
