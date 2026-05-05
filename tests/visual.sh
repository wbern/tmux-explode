#!/usr/bin/env bash
# Visual snapshot tests for tmux_explode.
#
# Three scenarios run on an isolated tmux socket:
#   1. 'all' mode  — gather every pane, diff against explode_6_panes.txt
#   2. 'active' mode — gather one pane per window, diff against explode_active_4_panes.txt
#   3. Round-trip   — explode then unexplode, assert window names and indices restored
#
# Run from anywhere: ./tests/visual.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}" )" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FIXTURES="$SCRIPT_DIR/fixtures"
SOCKET="tmux_explode_visual_test"

# Use an isolated socket so we never touch the user's running tmux. Also
# unset TMUX so tmux won't refuse to nest, and clear TMUX_PANE so the
# toggle script's display-message context isn't poisoned by a leaked id.
unset TMUX TMUX_PANE
TMUX_CMD=(tmux -L "$SOCKET")

cleanup() {
    "${TMUX_CMD[@]}" kill-server 2>/dev/null || true
}
trap cleanup EXIT

# Match the printf-substituted marker only (e.g. "  >>> ALPHA <<<"), not the
# command line still containing the literal "%s" template that gets echoed
# while the pane is mid-render.
MARKER_RE='^[[:space:]]+>>> [A-Z][A-Z0-9-]+ <<<[[:space:]]*$'

label_pane() {
    local pane="$1" label="$2" quoted
    quoted=$(printf '%q' "$label")
    "${TMUX_CMD[@]}" send-keys -t "$pane" \
        "clear; printf '\\n  >>> %s <<<\\n' $quoted; cat" Enter
}

wait_for_markers() {
    local session="$1" expected="$2" deadline=$((SECONDS + 5)) found=0
    while (( SECONDS < deadline )); do
        found=$("${TMUX_CMD[@]}" list-panes -s -t "$session" -F '#{pane_id}' \
                | while read -r p; do
                      "${TMUX_CMD[@]}" capture-pane -p -t "$p" \
                          | grep -E "$MARKER_RE" || true
                  done | wc -l | tr -d ' ')
        (( found >= expected )) && return 0
        sleep 0.1
    done
    echo "FAIL: markers never rendered (saw $found/$expected)" >&2
    return 1
}

wait_for_window() {
    local session="$1" name="$2" deadline=$((SECONDS + 5)) wid
    while (( SECONDS < deadline )); do
        wid=$("${TMUX_CMD[@]}" list-windows -t "$session" \
              -F '#{window_id} #{window_name}' | awk -v n="$name" '$2==n {print $1; exit}')
        [[ -n "$wid" ]] && { echo "$wid"; return 0; }
        sleep 0.1
    done
    return 1
}

wait_for_window_gone() {
    local session="$1" name="$2" deadline=$((SECONDS + 5))
    while (( SECONDS < deadline )); do
        if ! "${TMUX_CMD[@]}" list-windows -t "$session" \
              -F '#{window_name}' | grep -Fxq "$name"; then
            return 0
        fi
        sleep 0.1
    done
    return 1
}

snapshot_overview() {
    local win="$1"
    local pane_data
    pane_data=$("${TMUX_CMD[@]}" list-panes -t "$win" \
                -F '#{pane_id}|#{pane_left}|#{pane_top}|#{@orig_window}')

    # Choose labels based on row/column count so a 2x2 reads "top/bottom"
    # rather than misleadingly using "top/middle".
    local distinct_tops distinct_lefts
    distinct_tops=$(awk -F'|' '{print $3}' <<< "$pane_data" | sort -nu)
    distinct_lefts=$(awk -F'|' '{print $2}' <<< "$pane_data" | sort -nu)
    local row_count col_count
    row_count=$(wc -l <<< "$distinct_tops" | tr -d ' ')
    col_count=$(wc -l <<< "$distinct_lefts" | tr -d ' ')

    local row_labels col_labels
    case "$row_count" in
        1) row_labels=(only) ;;
        2) row_labels=(top bottom) ;;
        3) row_labels=(top middle bottom) ;;
        *) row_labels=() ;;  # fall back to row0/row1/...
    esac
    case "$col_count" in
        1) col_labels=(only) ;;
        2) col_labels=(left right) ;;
        3) col_labels=(left middle right) ;;
        *) col_labels=() ;;
    esac

    declare -A row_for_top col_for_left
    local i=0
    while IFS= read -r t; do
        row_for_top[$t]="${row_labels[$i]:-row$i}"
        i=$((i + 1))
    done <<< "$distinct_tops"

    i=0
    while IFS= read -r l; do
        col_for_left[$l]="${col_labels[$i]:-col$i}"
        i=$((i + 1))
    done <<< "$distinct_lefts"

    while IFS='|' read -r pid left top orig; do
        local bucket="${row_for_top[$top]}-${col_for_left[$left]}"
        local content
        content=$("${TMUX_CMD[@]}" capture-pane -p -t "$pid" \
                  | grep -E "$MARKER_RE" \
                  | head -1 \
                  | sed -E 's/^[[:space:]]+>>> (.+) <<<[[:space:]]*$/\1/')
        printf '%-13s | orig=%-8s | content="%s"\n' "$bucket" "$orig" "$content"
    done <<< "$pane_data" | sort
}

assert_snapshot() {
    local label="$1" actual="$2" fixture="$3"
    local expected
    expected=$(sort "$fixture")
    if diff <(echo "$expected") <(echo "$actual") > /tmp/visual-test-diff.txt; then
        echo "PASS [$label] snapshot matches $(basename "$fixture")"
        echo "$actual"
        return 0
    fi
    echo "FAIL [$label] snapshot diverges from $fixture" >&2
    echo "--- expected" >&2; echo "$expected" >&2
    echo "--- actual"   >&2; echo "$actual"   >&2
    echo "--- diff"     >&2; cat /tmp/visual-test-diff.txt >&2
    return 1
}

# Build the 4-window topology used by both 'all' and 'active' scenarios.
# Returns nothing; the named session is left ready to toggle.
build_topology() {
    local session="$1"
    "${TMUX_CMD[@]}" new-session -d -s "$session" -n alpha -x 120 -y 40
    label_pane "$session:alpha.0" "ALPHA"

    "${TMUX_CMD[@]}" new-window -t "$session:" -n bravo
    "${TMUX_CMD[@]}" split-window -t "$session:bravo" -h
    "${TMUX_CMD[@]}" split-window -t "$session:bravo" -v
    "${TMUX_CMD[@]}" select-layout -t "$session:bravo" tiled
    label_pane "$session:bravo.0" "BRAVO-1"
    label_pane "$session:bravo.1" "BRAVO-2"
    label_pane "$session:bravo.2" "BRAVO-3"

    "${TMUX_CMD[@]}" new-window -t "$session:" -n charlie
    label_pane "$session:charlie.0" "CHARLIE"

    "${TMUX_CMD[@]}" new-window -t "$session:" -n delta
    label_pane "$session:delta.0" "DELTA"

    # Make bravo's first pane active so 'active' mode picks BRAVO-1.
    "${TMUX_CMD[@]}" select-pane -t "$session:bravo.0"
    "${TMUX_CMD[@]}" select-window -t "$session:alpha"
}

run_toggle() {
    # Optional target lets server-scope tests anchor the script to a specific
    # session — without it, run-shell binds to the most-recently-used pane,
    # which is ambiguous when multiple sibling sessions exist on the socket.
    if (( $# > 0 )); then
        "${TMUX_CMD[@]}" run-shell -t "$1" "$REPO_ROOT/scripts/overview_toggle.sh"
    else
        "${TMUX_CMD[@]}" run-shell "$REPO_ROOT/scripts/overview_toggle.sh"
    fi
}

# ---------------------------------------------------------------------------
# Scenario 1: 'all' mode
# ---------------------------------------------------------------------------
cleanup
SESSION_ALL="all_mode"
build_topology "$SESSION_ALL"
wait_for_markers "$SESSION_ALL" 6
"${TMUX_CMD[@]}" set-option -g @explode-mode all
run_toggle
OVERVIEW=$(wait_for_window "$SESSION_ALL" overview) \
    || { echo "FAIL [all] no overview window after explode" >&2; exit 1; }
SNAP=$(snapshot_overview "$OVERVIEW")
assert_snapshot "all" "$SNAP" "$FIXTURES/explode_6_panes.txt"

# ---------------------------------------------------------------------------
# Scenario 2: 'active' mode
# ---------------------------------------------------------------------------
cleanup
SESSION_ACTIVE="active_mode"
build_topology "$SESSION_ACTIVE"
wait_for_markers "$SESSION_ACTIVE" 6
"${TMUX_CMD[@]}" set-option -g @explode-mode active
run_toggle
OVERVIEW=$(wait_for_window "$SESSION_ACTIVE" overview) \
    || { echo "FAIL [active] no overview window after explode" >&2; exit 1; }
SNAP=$(snapshot_overview "$OVERVIEW")
assert_snapshot "active" "$SNAP" "$FIXTURES/explode_active_4_panes.txt"

# ---------------------------------------------------------------------------
# Scenario 3: round-trip (explode → unexplode restores topology)
# ---------------------------------------------------------------------------
cleanup
SESSION_RT="round_trip"
build_topology "$SESSION_RT"
wait_for_markers "$SESSION_RT" 6
BASELINE=$("${TMUX_CMD[@]}" list-windows -t "$SESSION_RT" \
           -F '#{window_index} #{window_name} #{window_panes}' | sort)

"${TMUX_CMD[@]}" set-option -g @explode-mode all
run_toggle
wait_for_window "$SESSION_RT" overview > /dev/null \
    || { echo "FAIL [round-trip] no overview after explode" >&2; exit 1; }
run_toggle
wait_for_window_gone "$SESSION_RT" overview \
    || { echo "FAIL [round-trip] overview still present after unexplode" >&2; exit 1; }

AFTER=$("${TMUX_CMD[@]}" list-windows -t "$SESSION_RT" \
        -F '#{window_index} #{window_name} #{window_panes}' | sort)

if diff <(echo "$BASELINE") <(echo "$AFTER") > /tmp/visual-roundtrip-diff.txt; then
    echo "PASS [round-trip] window indices, names, and pane counts restored"
    echo "$AFTER"
else
    echo "FAIL [round-trip] topology diverges after explode/unexplode" >&2
    echo "--- baseline" >&2; echo "$BASELINE" >&2
    echo "--- after"    >&2; echo "$AFTER"    >&2
    echo "--- diff"     >&2; cat /tmp/visual-roundtrip-diff.txt >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Scenario 4: server scope — tile every other session as a nested attach
# ---------------------------------------------------------------------------
cleanup
HOME_SESSION="home"
"${TMUX_CMD[@]}" new-session -d -s "$HOME_SESSION" -n base -x 120 -y 40
label_pane "$HOME_SESSION:base.0" "HOME"
"${TMUX_CMD[@]}" new-session -d -s "sib1" -n w1 -x 120 -y 40
label_pane "sib1:w1.0" "SIB1"
"${TMUX_CMD[@]}" new-session -d -s "sib2" -n w2 -x 120 -y 40
label_pane "sib2:w2.0" "SIB2"
"${TMUX_CMD[@]}" new-session -d -s "sib3" -n w3 -x 120 -y 40
label_pane "sib3:w3.0" "SIB3"

# Wait for every pane on the socket to render its label so the nested
# attaches don't open onto half-painted shells.
wait_for_markers "$HOME_SESSION" 1
wait_for_markers "sib1" 1
wait_for_markers "sib2" 1
wait_for_markers "sib3" 1

"${TMUX_CMD[@]}" set-option -g @explode-scope server
run_toggle "$HOME_SESSION:base"

OVERVIEW=$(wait_for_window "$HOME_SESSION" overview) \
    || { echo "FAIL [server] no overview window after explode" >&2; exit 1; }

# Wait for all 3 nested-attach panes to materialise. tmux split-window
# returns immediately, so we loop until pane count stabilises.
deadline=$((SECONDS + 5))
while (( SECONDS < deadline )); do
    pane_count=$("${TMUX_CMD[@]}" list-panes -t "$OVERVIEW" -F '#{pane_id}' | wc -l | tr -d ' ')
    (( pane_count >= 3 )) && break
    sleep 0.1
done
if (( pane_count != 3 )); then
    echo "FAIL [server] expected 3 panes in overview, got $pane_count" >&2
    exit 1
fi

# Each pane should carry an @orig_session pointing at one of the siblings.
ORIG_SESSIONS=$("${TMUX_CMD[@]}" list-panes -t "$OVERVIEW" -F '#{@orig_session}' | sort)
EXPECTED_SESSIONS=$(printf 'sib1\nsib2\nsib3\n')
if [[ "$ORIG_SESSIONS" != "$EXPECTED_SESSIONS" ]]; then
    echo "FAIL [server] overview panes don't map to sibling sessions" >&2
    echo "--- expected" >&2; echo "$EXPECTED_SESSIONS" >&2
    echo "--- actual"   >&2; echo "$ORIG_SESSIONS"     >&2
    exit 1
fi

# The window itself should advertise the @explode-overview marker so external
# tools (resurrect, witnesses, continuum) can recognise and skip it.
MARKER=$("${TMUX_CMD[@]}" show-options -w -t "$OVERVIEW" -v "@explode-overview" 2>/dev/null || true)
if [[ "$MARKER" != "1" ]]; then
    echo "FAIL [server] @explode-overview marker missing on overview window" >&2
    exit 1
fi
echo "PASS [server] overview has 3 panes, all sibling sessions attached, marker set"

# Round-trip: unexplode should drop the wall, leave every sibling session alive,
# and clear the marker.
run_toggle "$HOME_SESSION:overview"
wait_for_window_gone "$HOME_SESSION" overview \
    || { echo "FAIL [server round-trip] overview still present after unexplode" >&2; exit 1; }

REMAINING=$("${TMUX_CMD[@]}" list-sessions -F '#{session_name}' | sort)
EXPECTED_REMAINING=$(printf 'home\nsib1\nsib2\nsib3\n')
if [[ "$REMAINING" != "$EXPECTED_REMAINING" ]]; then
    echo "FAIL [server round-trip] sibling sessions changed after unexplode" >&2
    echo "--- expected" >&2; echo "$EXPECTED_REMAINING" >&2
    echo "--- actual"   >&2; echo "$REMAINING"          >&2
    exit 1
fi

# `tmux list-clients` shows attached terminals. After unexplode there should
# be no nested clients pointing at any sibling session — the only clients on
# the socket are the test harness's own (typically zero in CI).
NESTED_CLIENTS=$("${TMUX_CMD[@]}" list-clients -F '#{client_session}' \
                 | grep -E '^sib[123]$' || true)
if [[ -n "$NESTED_CLIENTS" ]]; then
    echo "FAIL [server round-trip] orphan nested clients remain:" >&2
    echo "$NESTED_CLIENTS" >&2
    exit 1
fi
echo "PASS [server round-trip] overview gone, sessions intact, no orphan clients"

# Reset the global option so it doesn't leak into any later scenarios.
"${TMUX_CMD[@]}" set-option -gu @explode-scope
