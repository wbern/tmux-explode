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
# `-f /dev/null` keeps ~/.tmux.conf out of the test server — otherwise any
# user-level @explode-* option leaks into the harness and the assertions
# misfire.
unset TMUX TMUX_PANE
TMUX_CMD=(tmux -f /dev/null -L "$SOCKET")

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

wait_for_pane_count() {
    local target="$1" expected="$2" deadline=$((SECONDS + 5)) actual
    while (( SECONDS < deadline )); do
        actual=$("${TMUX_CMD[@]}" list-panes -t "$target" -F '#{pane_id}' 2>/dev/null \
                 | wc -l | tr -d ' ')
        (( actual == expected )) && return 0
        sleep 0.1
    done
    echo "wait_for_pane_count: $target expected=$expected actual=$actual" >&2
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
"${TMUX_CMD[@]}" set-option -g @explode-scope session
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
"${TMUX_CMD[@]}" set-option -g @explode-scope session
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

"${TMUX_CMD[@]}" set-option -g @explode-scope session
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
# Scenario 4: server scope splits the current window in place
#
# No new "overview" window is created — sibling sessions are added as panes
# alongside the original pane in the calling window. Unexplode kills the
# added panes and leaves the original alone.
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

wait_for_markers "$HOME_SESSION" 1
wait_for_markers "sib1" 1
wait_for_markers "sib2" 1
wait_for_markers "sib3" 1

BASE_WIN=$("${TMUX_CMD[@]}" display-message -p -t "$HOME_SESSION:base" '#{window_id}')
WINDOW_COUNT_BEFORE=$("${TMUX_CMD[@]}" list-windows -t "$HOME_SESSION" -F '#{window_id}' | wc -l | tr -d ' ')

"${TMUX_CMD[@]}" set-option -g @explode-scope server
run_toggle "$HOME_SESSION:base"

# Wait for all 3 nested-attach panes to materialise alongside the original.
deadline=$((SECONDS + 5))
while (( SECONDS < deadline )); do
    pane_count=$("${TMUX_CMD[@]}" list-panes -t "$BASE_WIN" -F '#{pane_id}' | wc -l | tr -d ' ')
    (( pane_count >= 4 )) && break
    sleep 0.1
done
if (( pane_count != 4 )); then
    echo "FAIL [server] expected 4 panes in base window, got $pane_count" >&2
    exit 1
fi

# No new window should have been created.
WINDOW_COUNT_AFTER=$("${TMUX_CMD[@]}" list-windows -t "$HOME_SESSION" -F '#{window_id}' | wc -l | tr -d ' ')
if (( WINDOW_COUNT_AFTER != WINDOW_COUNT_BEFORE )); then
    echo "FAIL [server] window count changed: $WINDOW_COUNT_BEFORE → $WINDOW_COUNT_AFTER" >&2
    exit 1
fi
if "${TMUX_CMD[@]}" list-windows -t "$HOME_SESSION" -F '#{window_name}' | grep -Fxq overview; then
    echo "FAIL [server] overview window created — should split current window in place" >&2
    exit 1
fi

# Three panes should carry an @orig_session pointing at one of the siblings;
# the original pane should NOT have @orig_session set.
ORIG_SESSIONS=$("${TMUX_CMD[@]}" list-panes -t "$BASE_WIN" -F '#{@orig_session}' \
                | grep -v '^$' | sort)
EXPECTED_SESSIONS=$(printf 'sib1\nsib2\nsib3\n')
if [[ "$ORIG_SESSIONS" != "$EXPECTED_SESSIONS" ]]; then
    echo "FAIL [server] added panes don't map to sibling sessions" >&2
    echo "--- expected" >&2; echo "$EXPECTED_SESSIONS" >&2
    echo "--- actual"   >&2; echo "$ORIG_SESSIONS"     >&2
    exit 1
fi
echo "PASS [server] base window has 4 panes (1 original + 3 attaches), no new window"

# Round-trip: unexplode should drop the added panes, leave every sibling
# session alive, and leave the base window with exactly its original pane.
run_toggle "$HOME_SESSION:base"

deadline=$((SECONDS + 5))
while (( SECONDS < deadline )); do
    pane_count=$("${TMUX_CMD[@]}" list-panes -t "$BASE_WIN" -F '#{pane_id}' | wc -l | tr -d ' ')
    (( pane_count == 1 )) && break
    sleep 0.1
done
if (( pane_count != 1 )); then
    echo "FAIL [server round-trip] expected 1 pane after unexplode, got $pane_count" >&2
    exit 1
fi

REMAINING=$("${TMUX_CMD[@]}" list-sessions -F '#{session_name}' | sort)
EXPECTED_REMAINING=$(printf 'home\nsib1\nsib2\nsib3\n')
if [[ "$REMAINING" != "$EXPECTED_REMAINING" ]]; then
    echo "FAIL [server round-trip] sibling sessions changed after unexplode" >&2
    echo "--- expected" >&2; echo "$EXPECTED_REMAINING" >&2
    echo "--- actual"   >&2; echo "$REMAINING"          >&2
    exit 1
fi

NESTED_CLIENTS=$("${TMUX_CMD[@]}" list-clients -F '#{client_session}' \
                 | grep -E '^sib[123]$' || true)
if [[ -n "$NESTED_CLIENTS" ]]; then
    echo "FAIL [server round-trip] orphan nested clients remain:" >&2
    echo "$NESTED_CLIENTS" >&2
    exit 1
fi
echo "PASS [server round-trip] base window restored, sessions intact, no orphan clients"

"${TMUX_CMD[@]}" set-option -gu @explode-scope

# ---------------------------------------------------------------------------
# Scenario 5: server scope with only the home session — should refuse
# ---------------------------------------------------------------------------
cleanup
"${TMUX_CMD[@]}" new-session -d -s "$HOME_SESSION" -n base -x 120 -y 40
label_pane "$HOME_SESSION:base.0" "HOME"
wait_for_markers "$HOME_SESSION" 1

BASE_WIN=$("${TMUX_CMD[@]}" display-message -p -t "$HOME_SESSION:base" '#{window_id}')

"${TMUX_CMD[@]}" set-option -g @explode-scope server
run_toggle "$HOME_SESSION:base"

sleep 0.3
LONE_PANES=$("${TMUX_CMD[@]}" list-panes -t "$BASE_WIN" -F '#{pane_id}' | wc -l | tr -d ' ')
if (( LONE_PANES != 1 )); then
    echo "FAIL [server lone] base window altered when no siblings exist (panes=$LONE_PANES)" >&2
    exit 1
fi
if "${TMUX_CMD[@]}" list-windows -t "$HOME_SESSION" -F '#{window_name}' | grep -Fxq overview; then
    echo "FAIL [server lone] overview window created when no siblings exist" >&2
    exit 1
fi
echo "PASS [server lone] no panes added, no window created when no other sessions exist"
"${TMUX_CMD[@]}" set-option -gu @explode-scope

# ---------------------------------------------------------------------------
# Scenario 6: server scope round-trip restores explicit session-local status
# ---------------------------------------------------------------------------
cleanup
"${TMUX_CMD[@]}" new-session -d -s "$HOME_SESSION" -n base -x 120 -y 40
label_pane "$HOME_SESSION:base.0" "HOME"
"${TMUX_CMD[@]}" new-session -d -s "sibset" -n w -x 120 -y 40
label_pane "sibset:w.0" "SIBSET"
wait_for_markers "$HOME_SESSION" 1
wait_for_markers "sibset" 1

BASE_WIN=$("${TMUX_CMD[@]}" display-message -p -t "$HOME_SESSION:base" '#{window_id}')

"${TMUX_CMD[@]}" set-option -t sibset status 2
PRE_STATUS=$("${TMUX_CMD[@]}" show-options -t sibset -v status)
if [[ "$PRE_STATUS" != "2" ]]; then
    echo "FAIL [server status restore] precondition: expected status=2, got '$PRE_STATUS'" >&2
    exit 1
fi

"${TMUX_CMD[@]}" set-option -g @explode-scope server
run_toggle "$HOME_SESSION:base"

deadline=$((SECONDS + 5))
while (( SECONDS < deadline )); do
    pane_count=$("${TMUX_CMD[@]}" list-panes -t "$BASE_WIN" -F '#{pane_id}' | wc -l | tr -d ' ')
    (( pane_count == 2 )) && break
    sleep 0.1
done
if (( pane_count != 2 )); then
    echo "FAIL [server status restore] expected 2 panes after explode, got $pane_count" >&2
    exit 1
fi

DURING=$("${TMUX_CMD[@]}" show-options -t sibset -v status)
if [[ "$DURING" != "off" ]]; then
    echo "FAIL [server status restore] expected status=off during explode, got '$DURING'" >&2
    exit 1
fi

run_toggle "$HOME_SESSION:base"

deadline=$((SECONDS + 5))
while (( SECONDS < deadline )); do
    pane_count=$("${TMUX_CMD[@]}" list-panes -t "$BASE_WIN" -F '#{pane_id}' | wc -l | tr -d ' ')
    (( pane_count == 1 )) && break
    sleep 0.1
done
if (( pane_count != 1 )); then
    echo "FAIL [server status restore] expected 1 pane after unexplode, got $pane_count" >&2
    exit 1
fi

POST_STATUS=$("${TMUX_CMD[@]}" show-options -t sibset -v status)
if [[ "$POST_STATUS" != "$PRE_STATUS" ]]; then
    echo "FAIL [server status restore] sibling status not restored" >&2
    echo "--- before: $PRE_STATUS" >&2
    echo "--- after:  $POST_STATUS" >&2
    exit 1
fi
echo "PASS [server status restore] session-local status round-trips through explode"

"${TMUX_CMD[@]}" set-option -gu @explode-scope

# ---------------------------------------------------------------------------
# Scenario 7: single-window-session safety
#
# A session whose only window is the calling window must survive an
# explode/unexplode cycle. The previous "create overview window + absorb
# original pane" design destroyed such sessions on unexplode.
# ---------------------------------------------------------------------------
cleanup
"${TMUX_CMD[@]}" new-session -d -s "$HOME_SESSION" -n base -x 120 -y 40
label_pane "$HOME_SESSION:base.0" "HOME"
"${TMUX_CMD[@]}" new-session -d -s "sib1" -n w1 -x 120 -y 40
label_pane "sib1:w1.0" "SIB1"
wait_for_markers "$HOME_SESSION" 1
wait_for_markers "sib1" 1

BASE_WIN=$("${TMUX_CMD[@]}" display-message -p -t "$HOME_SESSION:base" '#{window_id}')

"${TMUX_CMD[@]}" set-option -g @explode-scope server
run_toggle "$HOME_SESSION:base"
wait_for_pane_count "$BASE_WIN" 2 \
    || { echo "FAIL [server single-window safety] explode never reached 2 panes" >&2; exit 1; }
run_toggle "$HOME_SESSION:base"
wait_for_pane_count "$BASE_WIN" 1 \
    || { echo "FAIL [server single-window safety] unexplode never reduced to 1 pane" >&2; exit 1; }

if ! "${TMUX_CMD[@]}" has-session -t "$HOME_SESSION" 2>/dev/null; then
    echo "FAIL [server single-window safety] home session destroyed by toggle cycle" >&2
    exit 1
fi
echo "PASS [server single-window safety] home session intact after toggle cycle"

"${TMUX_CMD[@]}" set-option -gu @explode-scope

# ---------------------------------------------------------------------------
# Scenario 8: hybrid scope — gather current session's other windows AND
# nested attaches to other sessions into the calling window in place.
# ---------------------------------------------------------------------------
cleanup
"${TMUX_CMD[@]}" new-session -d -s "$HOME_SESSION" -n base -x 120 -y 40
label_pane "$HOME_SESSION:base.0" "HOME"
"${TMUX_CMD[@]}" new-window -t "$HOME_SESSION:" -n extra
label_pane "$HOME_SESSION:extra.0" "EXTRA"
# Re-focus base so home's current window is the one that fires the toggle —
# the script reads the firing session's current window, not the run-shell -t
# target.
"${TMUX_CMD[@]}" select-window -t "$HOME_SESSION:base"
"${TMUX_CMD[@]}" new-session -d -s "sib1" -n w1 -x 120 -y 40
label_pane "sib1:w1.0" "SIB1"
"${TMUX_CMD[@]}" new-session -d -s "sib2" -n w2 -x 120 -y 40
label_pane "sib2:w2.0" "SIB2"

wait_for_markers "$HOME_SESSION" 2
wait_for_markers "sib1" 1
wait_for_markers "sib2" 1

BASE_WIN=$("${TMUX_CMD[@]}" display-message -p -t "$HOME_SESSION:base" '#{window_id}')
EXTRA_INDEX=$("${TMUX_CMD[@]}" display-message -p -t "$HOME_SESSION:extra" '#{window_index}')

"${TMUX_CMD[@]}" set-option -g @explode-scope all
run_toggle "$HOME_SESSION:base"

wait_for_pane_count "$BASE_WIN" 4 \
    || { echo "FAIL [hybrid] explode never reached 4 panes in base window" >&2; exit 1; }

# Window count should drop from 2 to 1 — extra had a single pane, so gathering
# it consumes the window. base is the only survivor.
WINDOW_COUNT=$("${TMUX_CMD[@]}" list-windows -t "$HOME_SESSION" -F '#{window_id}' | wc -l | tr -d ' ')
if (( WINDOW_COUNT != 1 )); then
    echo "FAIL [hybrid] expected 1 window after explode, got $WINDOW_COUNT" >&2
    exit 1
fi

ORIG_WINDOWS=$("${TMUX_CMD[@]}" list-panes -t "$BASE_WIN" -F '#{@orig_window}' \
               | grep -v '^$' | sort)
if [[ "$ORIG_WINDOWS" != "extra" ]]; then
    echo "FAIL [hybrid] expected one local pane tagged @orig_window=extra, got: $ORIG_WINDOWS" >&2
    exit 1
fi

ORIG_SESSIONS=$("${TMUX_CMD[@]}" list-panes -t "$BASE_WIN" -F '#{@orig_session}' \
                | grep -v '^$' | sort)
EXPECTED_SESSIONS=$(printf 'sib1\nsib2\n')
if [[ "$ORIG_SESSIONS" != "$EXPECTED_SESSIONS" ]]; then
    echo "FAIL [hybrid] expected sib1+sib2 as @orig_session panes, got:" >&2
    echo "$ORIG_SESSIONS" >&2
    exit 1
fi
echo "PASS [hybrid explode] base window has 4 panes (1 original + 1 local + 2 attaches)"

# Round-trip: unexplode should kill nested attaches, rejoin/break-pane local
# panes back to their origin window, and leave base with one pane.
run_toggle "$HOME_SESSION:base"

wait_for_pane_count "$BASE_WIN" 1 \
    || { echo "FAIL [hybrid round-trip] base never reduced to 1 pane" >&2; exit 1; }

if ! "${TMUX_CMD[@]}" list-windows -t "$HOME_SESSION" -F '#{window_name}' | grep -Fxq extra; then
    echo "FAIL [hybrid round-trip] extra window not restored" >&2
    "${TMUX_CMD[@]}" list-windows -t "$HOME_SESSION" >&2
    exit 1
fi

EXTRA_INDEX_AFTER=$("${TMUX_CMD[@]}" display-message -p -t "$HOME_SESSION:extra" '#{window_index}')
if [[ "$EXTRA_INDEX_AFTER" != "$EXTRA_INDEX" ]]; then
    echo "FAIL [hybrid round-trip] extra window index drift: was $EXTRA_INDEX, now $EXTRA_INDEX_AFTER" >&2
    exit 1
fi

REMAINING=$("${TMUX_CMD[@]}" list-sessions -F '#{session_name}' | sort)
EXPECTED_REMAINING=$(printf 'home\nsib1\nsib2\n')
if [[ "$REMAINING" != "$EXPECTED_REMAINING" ]]; then
    echo "FAIL [hybrid round-trip] sibling sessions changed:" >&2
    echo "--- expected" >&2; echo "$EXPECTED_REMAINING" >&2
    echo "--- actual"   >&2; echo "$REMAINING" >&2
    exit 1
fi

NESTED_CLIENTS=$("${TMUX_CMD[@]}" list-clients -F '#{client_session}' \
                 | grep -E '^sib[12]$' || true)
if [[ -n "$NESTED_CLIENTS" ]]; then
    echo "FAIL [hybrid round-trip] orphan nested clients remain:" >&2
    echo "$NESTED_CLIENTS" >&2
    exit 1
fi
echo "PASS [hybrid round-trip] base restored, extra window back at index $EXTRA_INDEX, sessions intact"

"${TMUX_CMD[@]}" set-option -gu @explode-scope

# ---------------------------------------------------------------------------
# Scenario 9: per-tile border labels. tmux 3.6a treats pane-border-style as
# window-scoped, so we color the label inside pane-border-format with inline
# `#[fg=...]` markup keyed off per-pane @orig_session / @orig_window markers.
# Test asserts: format string carries each tier's color + glyph, every wall
# pane renders the right label for its tier, and pane-border-status /
# pane-border-format are saved+restored cleanly across a toggle cycle.
# ---------------------------------------------------------------------------
cleanup
"${TMUX_CMD[@]}" new-session -d -s "$HOME_SESSION" -n base -x 120 -y 40
label_pane "$HOME_SESSION:base.0" "HOME"
"${TMUX_CMD[@]}" new-window -t "$HOME_SESSION:" -n extra
label_pane "$HOME_SESSION:extra.0" "EXTRA"
"${TMUX_CMD[@]}" select-window -t "$HOME_SESSION:base"
"${TMUX_CMD[@]}" new-session -d -s "sib1" -n w1 -x 120 -y 40
label_pane "sib1:w1.0" "SIB1"

wait_for_markers "$HOME_SESSION" 2
wait_for_markers "sib1" 1

BASE_WIN=$("${TMUX_CMD[@]}" display-message -p -t "$HOME_SESSION:base" '#{window_id}')

BASELINE_STATUS=$("${TMUX_CMD[@]}" show-options -wqv -t "$BASE_WIN" pane-border-status)
BASELINE_FORMAT=$("${TMUX_CMD[@]}" show-options -wqv -t "$BASE_WIN" pane-border-format)
if [[ -n "$BASELINE_STATUS" || -n "$BASELINE_FORMAT" ]]; then
    echo "FAIL [tile labels] expected clean baseline, got status='$BASELINE_STATUS' format='$BASELINE_FORMAT'" >&2
    exit 1
fi

"${TMUX_CMD[@]}" set-option -g @explode-scope all
run_toggle "$HOME_SESSION:base"

wait_for_pane_count "$BASE_WIN" 3 \
    || { echo "FAIL [tile labels] explode never reached 3 panes (anchor + local + remote)" >&2; exit 1; }

WALL_STATUS=$("${TMUX_CMD[@]}" show-options -wqv -t "$BASE_WIN" pane-border-status)
if [[ "$WALL_STATUS" != "top" ]]; then
    echo "FAIL [tile labels] expected pane-border-status=top while walled, got '$WALL_STATUS'" >&2
    exit 1
fi

WALL_FORMAT=$("${TMUX_CMD[@]}" show-options -wqv -t "$BASE_WIN" pane-border-format)
for needle in "@heat" "@orig_session" "@orig_window" "fg=yellow#,bold" "fg=cyan" "fg=magenta" "◉ here" "◫" "⇄"; do
    if [[ "$WALL_FORMAT" != *"$needle"* ]]; then
        echo "FAIL [tile labels] pane-border-format missing '$needle': '$WALL_FORMAT'" >&2
        exit 1
    fi
done

# Render the saved format in each pane's context — display-message expands
# format vars (incl. per-pane user options) against the target pane, so we
# get the actual on-screen label for that tile.
saw_anchor=0; saw_local=0; saw_remote=0
while IFS=$'\x1f' read -r pane_id orig_sess orig_win; do
    [[ -z "$pane_id" ]] && continue
    rendered=$("${TMUX_CMD[@]}" display-message -p -t "$pane_id" "$WALL_FORMAT")
    if [[ -n "$orig_sess" ]]; then
        [[ "$rendered" != *"⇄ $orig_sess"* ]] && {
            echo "FAIL [tile labels] remote pane $pane_id label missing '⇄ $orig_sess', got '$rendered'" >&2
            exit 1
        }
        saw_remote=1
    elif [[ -n "$orig_win" ]]; then
        [[ "$rendered" != *"◫ $orig_win"* ]] && {
            echo "FAIL [tile labels] local pane $pane_id label missing '◫ $orig_win', got '$rendered'" >&2
            exit 1
        }
        saw_local=1
    else
        [[ "$rendered" != *"◉ here"* ]] && {
            echo "FAIL [tile labels] anchor pane $pane_id label missing '◉ here', got '$rendered'" >&2
            exit 1
        }
        saw_anchor=1
    fi
done < <("${TMUX_CMD[@]}" list-panes -t "$BASE_WIN" \
         -F $'#{pane_id}\x1f#{@orig_session}\x1f#{@orig_window}')

if (( saw_anchor == 0 || saw_local == 0 || saw_remote == 0 )); then
    echo "FAIL [tile labels] missing tier — anchor=$saw_anchor local=$saw_local remote=$saw_remote" >&2
    exit 1
fi
echo "PASS [tile labels] anchor/local/remote tiles render distinct labels"

run_toggle "$HOME_SESSION:base"
wait_for_pane_count "$BASE_WIN" 1 \
    || { echo "FAIL [tile labels round-trip] base never reduced to 1 pane" >&2; exit 1; }

POST_STATUS=$("${TMUX_CMD[@]}" show-options -wqv -t "$BASE_WIN" pane-border-status)
POST_FORMAT=$("${TMUX_CMD[@]}" show-options -wqv -t "$BASE_WIN" pane-border-format)
if [[ -n "$POST_STATUS" || -n "$POST_FORMAT" ]]; then
    echo "FAIL [tile labels round-trip] window options leaked: status='$POST_STATUS' format='$POST_FORMAT'" >&2
    exit 1
fi
echo "PASS [tile labels round-trip] window-scoped border options cleared"

"${TMUX_CMD[@]}" set-option -gu @explode-scope

# ---------------------------------------------------------------------------
# Scenario 10: pre-existing pane-border-format / pane-border-status on the
# firing window must round-trip across a toggle cycle. The save path uses
# `show-options -wqv` to avoid round-tripping tmux's literal-quote wrapper
# around values containing spaces — this scenario locks that in. A multi-word
# format with spaces and a `#{...}` substitution exercises both pitfalls.
# ---------------------------------------------------------------------------
cleanup
"${TMUX_CMD[@]}" new-session -d -s "$HOME_SESSION" -n base -x 120 -y 40
label_pane "$HOME_SESSION:base.0" "HOME"
"${TMUX_CMD[@]}" new-session -d -s "sib1" -n w1 -x 120 -y 40
label_pane "sib1:w1.0" "SIB1"
wait_for_markers "$HOME_SESSION" 1
wait_for_markers "sib1" 1

BASE_WIN=$("${TMUX_CMD[@]}" display-message -p -t "$HOME_SESSION:base" '#{window_id}')

CUSTOM_FORMAT='[#{pane_index}] #{pane_current_command}'
"${TMUX_CMD[@]}" set-option -w -t "$BASE_WIN" pane-border-status bottom
"${TMUX_CMD[@]}" set-option -w -t "$BASE_WIN" pane-border-format "$CUSTOM_FORMAT"

"${TMUX_CMD[@]}" set-option -g @explode-scope server
run_toggle "$HOME_SESSION:base"
wait_for_pane_count "$BASE_WIN" 2 \
    || { echo "FAIL [custom-format round-trip] explode never reached 2 panes" >&2; exit 1; }

run_toggle "$HOME_SESSION:base"
wait_for_pane_count "$BASE_WIN" 1 \
    || { echo "FAIL [custom-format round-trip] unexplode never reduced to 1 pane" >&2; exit 1; }

POST_STATUS=$("${TMUX_CMD[@]}" show-options -wqv -t "$BASE_WIN" pane-border-status)
POST_FORMAT=$("${TMUX_CMD[@]}" show-options -wqv -t "$BASE_WIN" pane-border-format)
if [[ "$POST_STATUS" != "bottom" ]]; then
    echo "FAIL [custom-format round-trip] expected status=bottom, got '$POST_STATUS'" >&2
    exit 1
fi
if [[ "$POST_FORMAT" != "$CUSTOM_FORMAT" ]]; then
    echo "FAIL [custom-format round-trip] format mangled by save/restore" >&2
    echo "  expected: $CUSTOM_FORMAT" >&2
    echo "  actual:   $POST_FORMAT" >&2
    exit 1
fi
echo "PASS [custom-format round-trip] custom pane-border-format/status preserved"

"${TMUX_CMD[@]}" set-option -gu @explode-scope

# ---------------------------------------------------------------------------
# Scenario 11: column-biased layout. On a wide window with several panes the
# new layout builder must place tiles into more columns than tmux's built-in
# `tiled` would (which biases toward squarish tiles, producing landscape
# panes that are bad for reading streaming text). Six panes on a 200×50
# window: tiled would give 3 cols × 2 rows; our heuristic targets aspect
# ≈0.5 capped at min-width 40 → K=5 columns of taller panes.
# ---------------------------------------------------------------------------
cleanup
"${TMUX_CMD[@]}" new-session -d -s "$HOME_SESSION" -n base -x 200 -y 50
label_pane "$HOME_SESSION:base.0" "HOME"
for i in 1 2 3 4 5; do
    "${TMUX_CMD[@]}" new-session -d -s "wide$i" -n w -x 200 -y 50
    label_pane "wide$i:w.0" "WIDE$i"
done
wait_for_markers "$HOME_SESSION" 1
for i in 1 2 3 4 5; do
    wait_for_markers "wide$i" 1
done

BASE_WIN=$("${TMUX_CMD[@]}" display-message -p -t "$HOME_SESSION:base" '#{window_id}')
"${TMUX_CMD[@]}" set-option -g @explode-scope server
run_toggle "$HOME_SESSION:base"
wait_for_pane_count "$BASE_WIN" 6 \
    || { echo "FAIL [column-biased] explode never reached 6 panes" >&2; exit 1; }

# Number of distinct pane_left values = number of columns rendered.
COL_COUNT=$("${TMUX_CMD[@]}" list-panes -t "$BASE_WIN" -F '#{pane_left}' \
            | sort -nu | wc -l | tr -d ' ')
if (( COL_COUNT < 4 )); then
    echo "FAIL [column-biased] expected >=4 columns on 200×50 with 6 panes, got $COL_COUNT" >&2
    "${TMUX_CMD[@]}" list-panes -t "$BASE_WIN" -F '#{pane_id} L=#{pane_left} T=#{pane_top} #{pane_width}x#{pane_height}' >&2
    exit 1
fi
echo "PASS [column-biased] 200×50 with 6 panes → $COL_COUNT columns (was 3 with tiled)"

run_toggle "$HOME_SESSION:base"
wait_for_pane_count "$BASE_WIN" 1 \
    || { echo "FAIL [column-biased] unexplode never reduced to 1 pane" >&2; exit 1; }

"${TMUX_CMD[@]}" set-option -gu @explode-scope

# ---------------------------------------------------------------------------
# Scenario 12: heatmap poller sets @heat on tiles after a tick, stashes its
# PID on the wall window, and cleans up on unexplode (PID gone, per-pane
# markers wiped). Bucket *content* is timing-dependent and tested only
# loosely (must be one of the four glyphs); presence is the firm assertion.
# ---------------------------------------------------------------------------
cleanup
"${TMUX_CMD[@]}" new-session -d -s "$HOME_SESSION" -n base -x 120 -y 40
label_pane "$HOME_SESSION:base.0" "HOME"
"${TMUX_CMD[@]}" new-session -d -s "sib1" -n w1 -x 120 -y 40
label_pane "sib1:w1.0" "SIB1"
wait_for_markers "$HOME_SESSION" 1
wait_for_markers "sib1" 1

BASE_WIN=$("${TMUX_CMD[@]}" display-message -p -t "$HOME_SESSION:base" '#{window_id}')
"${TMUX_CMD[@]}" set-option -g @explode-scope all
run_toggle "$HOME_SESSION:base"
wait_for_pane_count "$BASE_WIN" 2 \
    || { echo "FAIL [heatmap] explode never reached 2 panes" >&2; exit 1; }

HEAT_PID=$("${TMUX_CMD[@]}" show-options -wqv -t "$BASE_WIN" "@explode_heat_pid")
if [[ -z "$HEAT_PID" ]] || ! kill -0 "$HEAT_PID" 2>/dev/null; then
    echo "FAIL [heatmap] poller PID not stashed or process not alive: '$HEAT_PID'" >&2
    exit 1
fi

# Poller ticks every ~2s; give it up to 6s to set @heat on at least one
# pane. Quiet test panes (no output between ticks) should land on ⚪
# (neutral — no observed activity yet), not 🔥. Tighter than 6s flakes
# on slow CI runners.
saw_heat=""
for _ in 1 2 3 4 5 6; do
    while IFS= read -r p; do
        [[ -z "$p" ]] && continue
        h=$("${TMUX_CMD[@]}" show-options -pqv -t "$p" "@heat")
        if [[ -n "$h" ]]; then
            saw_heat="$h"
            break 2
        fi
    done < <("${TMUX_CMD[@]}" list-panes -t "$BASE_WIN" -F '#{pane_id}')
    sleep 1
done

case "$saw_heat" in
    ⚪|🔥|🌶|💤|❄) echo "PASS [heatmap] poller set @heat=$saw_heat on at least one tile" ;;
    *) echo "FAIL [heatmap] no tile got @heat after 6s, got '$saw_heat'" >&2; exit 1 ;;
esac

# Quiet panes must NOT be 🔥 just because the wall came up — first sight
# is observation, not activity. Verify every tile is in the neutral or
# cool family. (A pane that legitimately produced output between explode
# and now would land on 🔥/🌶, which would also be correct, but in this
# fixture none of them do — the test sessions are sitting at idle prompts
# the whole time, so any 🔥 here is the old "first sight = activity" bug.)
while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    h=$("${TMUX_CMD[@]}" show-options -pqv -t "$p" "@heat")
    case "$h" in
        ⚪|💤|❄|"") ;;
        *)
            echo "FAIL [heatmap] quiet pane $p reported active glyph '$h' (should be ⚪/💤/❄)" >&2
            echo "  bug: 'first sight' is being treated as 'change detected'" >&2
            exit 1
            ;;
    esac
done < <("${TMUX_CMD[@]}" list-panes -t "$BASE_WIN" -F '#{pane_id}')
echo "PASS [heatmap] quiet panes show neutral glyph, not false-hot"

run_toggle "$HOME_SESSION:base"
wait_for_pane_count "$BASE_WIN" 1 \
    || { echo "FAIL [heatmap teardown] base never reduced to 1 pane" >&2; exit 1; }

# Poller PID stashed on the wall window must be unset and the process
# itself reaped. Per-pane heat markers must be cleared from the surviving
# anchor pane.
POST_PID=$("${TMUX_CMD[@]}" show-options -wqv -t "$BASE_WIN" "@explode_heat_pid")
if [[ -n "$POST_PID" ]]; then
    echo "FAIL [heatmap teardown] @explode_heat_pid leaked: '$POST_PID'" >&2
    exit 1
fi
# Give the poller a beat to notice the window is gone and exit on its
# own; SIGTERM should already have done the job, but a slow scheduler
# can leave a zombie window of a few hundred ms.
for _ in 1 2 3 4 5; do
    kill -0 "$HEAT_PID" 2>/dev/null || break
    sleep 1
done
if kill -0 "$HEAT_PID" 2>/dev/null; then
    echo "FAIL [heatmap teardown] poller PID $HEAT_PID still alive after toggle-off" >&2
    kill "$HEAT_PID" 2>/dev/null || true
    exit 1
fi

ANCHOR_PANE=$("${TMUX_CMD[@]}" list-panes -t "$BASE_WIN" -F '#{pane_id}' | head -1)
for opt in "@heat" "@heat_style" "@pane_last_hash" "@pane_last_change" "@pane_first_sight" "pane-style"; do
    leaked=$("${TMUX_CMD[@]}" show-options -pqv -t "$ANCHOR_PANE" "$opt")
    if [[ -n "$leaked" ]]; then
        echo "FAIL [heatmap teardown] $opt leaked on anchor pane: '$leaked'" >&2
        exit 1
    fi
done
echo "PASS [heatmap teardown] poller killed and per-pane markers cleared"

"${TMUX_CMD[@]}" set-option -gu @explode-scope

# ---------------------------------------------------------------------------
# Scenario 13: stranded overview pruning. A previous explode that didn't
# tear down cleanly leaves a target session with `overview` as its active
# window — then a fresh `tmux attach -t <name>` from add_session_attach_pane
# inherits that window and the new tile renders someone else's content.
# add_session_attach_pane must detect and prune the stranded artifact.
# ---------------------------------------------------------------------------
cleanup
"${TMUX_CMD[@]}" new-session -d -s "$HOME_SESSION" -n base -x 120 -y 40
label_pane "$HOME_SESSION:base.0" "HOME"
"${TMUX_CMD[@]}" new-session -d -s "victim" -n real -x 120 -y 40
label_pane "victim:real.0" "VICTIM-REAL"
wait_for_markers "$HOME_SESSION" 1
wait_for_markers "victim" 1

# Forge the stranded state: an extra window in `victim` named "overview"
# with a pane carrying our @orig_session marker, and victim's active
# window set to it. Mirrors what a crashed explode would leave behind.
"${TMUX_CMD[@]}" new-window -t "victim:" -n overview
STRAY_PANE=$("${TMUX_CMD[@]}" display-message -p -t "victim:overview" '#{pane_id}')
"${TMUX_CMD[@]}" set-option -p -t "$STRAY_PANE" "@orig_session" "ghost"
label_pane "$STRAY_PANE" "STRANDED"
"${TMUX_CMD[@]}" select-window -t "victim:overview"

# Detach all clients so prune_stranded_overview considers it safe to clean.
"${TMUX_CMD[@]}" detach-client -s "victim" 2>/dev/null || true

VICTIM_ACTIVE_BEFORE=$("${TMUX_CMD[@]}" display-message -p -t "victim" '#{window_name}')
if [[ "$VICTIM_ACTIVE_BEFORE" != "overview" ]]; then
    echo "FAIL [stranded prune] precondition: victim's active window not 'overview', got '$VICTIM_ACTIVE_BEFORE'" >&2
    exit 1
fi

BASE_WIN=$("${TMUX_CMD[@]}" display-message -p -t "$HOME_SESSION:base" '#{window_id}')
"${TMUX_CMD[@]}" set-option -g @explode-scope server
run_toggle "$HOME_SESSION:base"

wait_for_pane_count "$BASE_WIN" 2 \
    || { echo "FAIL [stranded prune] explode never reached 2 panes" >&2; exit 1; }

# After explode: victim's overview window must be gone, and victim's active
# window should now be `real` (the only remaining non-overview window).
if "${TMUX_CMD[@]}" list-windows -t "victim" -F '#{window_name}' | grep -Fxq overview; then
    echo "FAIL [stranded prune] stranded overview window not removed" >&2
    "${TMUX_CMD[@]}" list-windows -t "victim" >&2
    exit 1
fi
VICTIM_ACTIVE_AFTER=$("${TMUX_CMD[@]}" display-message -p -t "victim" '#{window_name}')
if [[ "$VICTIM_ACTIVE_AFTER" != "real" ]]; then
    echo "FAIL [stranded prune] expected victim active window=real, got '$VICTIM_ACTIVE_AFTER'" >&2
    exit 1
fi
echo "PASS [stranded prune] forged stranded overview removed before nested attach"

run_toggle "$HOME_SESSION:base"
wait_for_pane_count "$BASE_WIN" 1 \
    || { echo "FAIL [stranded prune teardown] base never reduced to 1 pane" >&2; exit 1; }

"${TMUX_CMD[@]}" set-option -gu @explode-scope

# Negative case: a real user-named "overview" window with NO @orig_*
# artifacts must NOT be pruned — that's the user's window, not our artifact.
cleanup
"${TMUX_CMD[@]}" new-session -d -s "$HOME_SESSION" -n base -x 120 -y 40
label_pane "$HOME_SESSION:base.0" "HOME"
"${TMUX_CMD[@]}" new-session -d -s "owner" -n real -x 120 -y 40
label_pane "owner:real.0" "OWNER-REAL"
wait_for_markers "$HOME_SESSION" 1
wait_for_markers "owner" 1

"${TMUX_CMD[@]}" new-window -t "owner:" -n overview
USER_PANE=$("${TMUX_CMD[@]}" display-message -p -t "owner:overview" '#{pane_id}')
label_pane "$USER_PANE" "USER-OVERVIEW"
"${TMUX_CMD[@]}" select-window -t "owner:overview"
"${TMUX_CMD[@]}" detach-client -s "owner" 2>/dev/null || true

BASE_WIN=$("${TMUX_CMD[@]}" display-message -p -t "$HOME_SESSION:base" '#{window_id}')
"${TMUX_CMD[@]}" set-option -g @explode-scope server
run_toggle "$HOME_SESSION:base"
wait_for_pane_count "$BASE_WIN" 2 \
    || { echo "FAIL [stranded prune negative] explode never reached 2 panes" >&2; exit 1; }

if ! "${TMUX_CMD[@]}" list-windows -t "owner" -F '#{window_name}' | grep -Fxq overview; then
    echo "FAIL [stranded prune negative] user's own 'overview' window was wrongly pruned" >&2
    exit 1
fi
echo "PASS [stranded prune negative] user-owned 'overview' window left alone (no artifact markers)"

run_toggle "$HOME_SESSION:base"
wait_for_pane_count "$BASE_WIN" 1 \
    || { echo "FAIL [stranded prune negative teardown] base never reduced to 1 pane" >&2; exit 1; }

"${TMUX_CMD[@]}" set-option -gu @explode-scope

# Safety case: if the stranded overview is the target session's ONLY window,
# pruning it would destroy the session. The guard must keep the session
# alive even at the cost of a mis-rendered tile.
cleanup
"${TMUX_CMD[@]}" new-session -d -s "$HOME_SESSION" -n base -x 120 -y 40
label_pane "$HOME_SESSION:base.0" "HOME"
"${TMUX_CMD[@]}" new-session -d -s "lone" -n overview -x 120 -y 40
LONE_PANE=$("${TMUX_CMD[@]}" display-message -p -t "lone:overview" '#{pane_id}')
"${TMUX_CMD[@]}" set-option -p -t "$LONE_PANE" "@orig_session" "ghost"
label_pane "$LONE_PANE" "LONE-STRANDED"
wait_for_markers "$HOME_SESSION" 1
wait_for_markers "lone" 1
"${TMUX_CMD[@]}" detach-client -s "lone" 2>/dev/null || true

BASE_WIN=$("${TMUX_CMD[@]}" display-message -p -t "$HOME_SESSION:base" '#{window_id}')
"${TMUX_CMD[@]}" set-option -g @explode-scope server
run_toggle "$HOME_SESSION:base"
wait_for_pane_count "$BASE_WIN" 2 \
    || { echo "FAIL [stranded prune safety] explode never reached 2 panes" >&2; exit 1; }

if ! "${TMUX_CMD[@]}" has-session -t "lone" 2>/dev/null; then
    echo "FAIL [stranded prune safety] target session destroyed by prune of its only window" >&2
    exit 1
fi
echo "PASS [stranded prune safety] session-destroying prune refused"

run_toggle "$HOME_SESSION:base"
wait_for_pane_count "$BASE_WIN" 1 \
    || { echo "FAIL [stranded prune safety teardown] base never reduced to 1 pane" >&2; exit 1; }

"${TMUX_CMD[@]}" set-option -gu @explode-scope
