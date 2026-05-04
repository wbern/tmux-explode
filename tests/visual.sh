#!/usr/bin/env bash
# Visual snapshot test for tmux_explode.
#
# Builds a known topology (alpha + bravo×3 + charlie + delta = 6 panes across
# 4 windows), explodes in 'all' mode, and emits a structural snapshot of the
# resulting overview window: one line per pane, mapping its origin window and
# grid-position bucket to the first non-empty line of pane content.
#
# The snapshot is diffed against tests/fixtures/explode_6_panes.txt. Asserts
# what actually matters for users (identity → visual position) without being
# brittle to terminal rendering quirks across tmux versions.
#
# Run from anywhere: ./tests/visual.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}" )" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FIXTURE="$SCRIPT_DIR/fixtures/explode_6_panes.txt"
SOCKET="tmux_explode_visual_test"
SESSION="vtest"

# Use an isolated socket so we never touch the user's running tmux. Also
# unset TMUX so tmux won't refuse to nest, and clear TMUX_PANE so the
# toggle script's display-message context isn't poisoned by a leaked id.
unset TMUX TMUX_PANE
TMUX_CMD=(tmux -L "$SOCKET")

cleanup() {
    "${TMUX_CMD[@]}" kill-server 2>/dev/null || true
}
trap cleanup EXIT

cleanup  # ensure no stale server from a prior failed run

# Width/height chosen to give enough room for a 3x2 tiled layout without any
# pane-too-small errors during join.
"${TMUX_CMD[@]}" new-session -d -s "$SESSION" -n alpha -x 120 -y 40

# Helper: stamp a pane with a labelled banner so we can identify it later.
label_pane() {
    local pane="$1" label="$2"
    "${TMUX_CMD[@]}" send-keys -t "$pane" \
        "clear; printf '\\n  >>> %s <<<\\n' '$label'; cat" Enter
}

label_pane "$SESSION:alpha.0" "ALPHA"

"${TMUX_CMD[@]}" new-window -t "$SESSION:" -n bravo
"${TMUX_CMD[@]}" split-window -t "$SESSION:bravo" -h
"${TMUX_CMD[@]}" split-window -t "$SESSION:bravo" -v
"${TMUX_CMD[@]}" select-layout -t "$SESSION:bravo" tiled
label_pane "$SESSION:bravo.0" "BRAVO-1"
label_pane "$SESSION:bravo.1" "BRAVO-2"
label_pane "$SESSION:bravo.2" "BRAVO-3"

"${TMUX_CMD[@]}" new-window -t "$SESSION:" -n charlie
label_pane "$SESSION:charlie.0" "CHARLIE"

"${TMUX_CMD[@]}" new-window -t "$SESSION:" -n delta
label_pane "$SESSION:delta.0" "DELTA"

# Give the labels a moment to render before we capture.
sleep 0.5

# Run the toggle script with the test session as its tmux context.
"${TMUX_CMD[@]}" select-window -t "$SESSION:alpha"
TMUX_TARGET=$("${TMUX_CMD[@]}" display-message -p '#{socket_path}')
export TMUX="$TMUX_TARGET,0,0"
TMUX_EXPLODE_MODE=all \
    "${TMUX_CMD[@]}" set-option -g @explode-mode all
"${TMUX_CMD[@]}" run-shell "$REPO_ROOT/scripts/overview_toggle.sh"
unset TMUX

sleep 0.3

OVERVIEW_WIN=$("${TMUX_CMD[@]}" list-windows -t "$SESSION" \
               -F '#{window_id} #{window_name}' | awk '$2=="overview" {print $1; exit}')

if [[ -z "$OVERVIEW_WIN" ]]; then
    echo "FAIL: no overview window after explode" >&2
    "${TMUX_CMD[@]}" list-windows -t "$SESSION" >&2
    exit 1
fi

# Build rank tables for distinct top/left coordinates so bucketing adapts to
# tmux's actual layout (rows can be unequal heights).
PANE_DATA=$("${TMUX_CMD[@]}" list-panes -t "$OVERVIEW_WIN" \
            -F '#{pane_id}|#{pane_left}|#{pane_top}|#{@orig_window}')

ROW_LABELS=(top middle bottom)
COL_LABELS=(left right)

declare -A row_for_top col_for_left
i=0
while IFS= read -r t; do
    row_for_top[$t]="${ROW_LABELS[$i]:-row$i}"
    i=$((i + 1))
done < <(awk -F'|' '{print $3}' <<< "$PANE_DATA" | sort -nu)

i=0
while IFS= read -r l; do
    col_for_left[$l]="${COL_LABELS[$i]:-col$i}"
    i=$((i + 1))
done < <(awk -F'|' '{print $2}' <<< "$PANE_DATA" | sort -nu)

SNAPSHOT=$(
    while IFS='|' read -r pid left top orig; do
        bucket="${row_for_top[$top]}-${col_for_left[$left]}"
        content=$("${TMUX_CMD[@]}" capture-pane -p -t "$pid" \
                  | grep -oE '>>> [^<]+ <<<' \
                  | head -1 \
                  | sed -E 's/^>>> (.+) <<<$/\1/')
        printf '%-13s | orig=%-8s | content="%s"\n' "$bucket" "$orig" "$content"
    done <<< "$PANE_DATA" | sort
)

EXPECTED=$(sort "$FIXTURE")

if diff <(echo "$EXPECTED") <(echo "$SNAPSHOT") > /tmp/visual-test-diff.txt; then
    echo "PASS: snapshot matches $FIXTURE"
    echo "$SNAPSHOT"
    exit 0
else
    echo "FAIL: snapshot diverges from $FIXTURE" >&2
    echo "--- expected" >&2
    echo "$EXPECTED" >&2
    echo "--- actual" >&2
    echo "$SNAPSHOT" >&2
    echo "--- diff" >&2
    cat /tmp/visual-test-diff.txt >&2
    exit 1
fi
