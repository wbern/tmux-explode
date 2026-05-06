#!/usr/bin/env bash
# Toggle between exploded (overview window of tiled panes) and unexploded
# (panes restored to their origins).
#
# Runtime options (read fresh on each invocation):
#   @explode-scope        'session' (default) or 'server'
#   @explode-mode         'active' (default) or 'all'    [session-scope only]
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
SCOPE=$(get_tmux_option "@explode-scope" "session")

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

    tmux select-layout -t "$SESSION:$OVERVIEW" tiled
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

explode_server() {
    local others=()
    local s
    while IFS= read -r s; do
        [[ -z "$s" || "$s" == "$SESSION_NAME" ]] && continue
        others+=("$s")
    done < <(tmux list-sessions -F '#{session_name}')

    if (( ${#others[@]} == 0 )); then
        tmux display-message "tmux_explode: no other sessions to explode"
        return 0
    fi

    local name
    for name in "${others[@]}"; do
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

        # Re-tile between joins so panes don't shrink past tmux's minimum
        # size and trigger 'create pane failed'.
        tmux select-layout -t "$CURRENT_WIN" tiled
    done

    tmux select-layout -t "$CURRENT_WIN" tiled
}

unexplode_server() {
    local panes_data
    panes_data=$(tmux list-panes -t "$CURRENT_WIN" \
                 -F '#{pane_id}'$'\t''#{@orig_session}'$'\t''#{@orig_session_status}')

    local pane_id orig_session saved
    while IFS=$'\t' read -r pane_id orig_session saved; do
        [[ -z "${orig_session:-}" ]] && continue

        # Restore the target session's status setting. `unset` means the
        # session was inheriting the global default — use -u to drop the
        # session-local override rather than pinning a value.
        if [[ "${saved:-}" == "unset" ]]; then
            tmux set-option -u -t "$orig_session" status 2>/dev/null || true
        elif [[ "${saved:-}" == set:* ]]; then
            tmux set-option -t "$orig_session" status "${saved#set:}" 2>/dev/null || true
        fi

        # Killing the pane terminates its `tmux attach` process, dropping
        # only the nested client we created — other clients attached to
        # that session stay put, and the session itself is untouched.
        # Tolerate already-dead panes (user closed one manually before
        # toggling off) so the loop still cleans up its siblings.
        tmux kill-pane -t "$pane_id" 2>/dev/null || true
    done <<< "$panes_data"
}

# A server-scope explosion is in progress when any pane in the current
# window carries @orig_session — that marker is set only by explode_server
# and survives across @explode-scope flips, so unexplode works even if the
# user changed scope mid-flow.
server_explode_active() {
    local marker
    marker=$(tmux list-panes -t "$CURRENT_WIN" -F '#{@orig_session}' 2>/dev/null \
             | grep -v '^$' | head -1 || true)
    [[ -n "$marker" ]]
}

if server_explode_active; then
    unexplode_server
elif [[ "$CURRENT" == "$OVERVIEW" ]]; then
    unexplode
else
    case "$SCOPE" in
        server) explode_server ;;
        *)      explode ;;
    esac
fi
