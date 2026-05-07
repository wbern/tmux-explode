#!/usr/bin/env bash
# Record the README demo: 8 sibling sessions, a quick survey of each, then an
# in-place explode. Outputs tests/demo.cast and (if agg is on PATH) docs/demo.gif.
#
# Usage: ./tests/record_demo.sh [--no-gif]
#
# Requires: asciinema, tmux, bash 4+. agg is optional but needed for the gif.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOCKET="explode_demo_$$"
TMUX_BIN=${TMUX_BIN:-tmux}
PAINTER="$REPO_ROOT/tests/fixtures/demo_painter.sh"
CAST="$REPO_ROOT/tests/demo.cast"
GIF="$REPO_ROOT/docs/demo.gif"

WANT_GIF=1
[[ "${1:-}" == "--no-gif" ]] && WANT_GIF=0

# Inherited TMUX/TMUX_PANE would otherwise route our control commands at the
# caller's tmux instead of our private socket. Clear before defining the array.
unset TMUX TMUX_PANE
TX=("$TMUX_BIN" -L "$SOCKET")

cleanup() { "${TX[@]}" kill-server 2>/dev/null || true; }
trap cleanup EXIT

ORDER=(api worker db-migrate dev-server tests logs notebook agent)
COLS=180
ROWS=50

# Spin up a sibling session per painter. Each pane runs the painter as its
# top-level command so the pane persists for the entire recording.
for s in "${ORDER[@]}"; do
    "${TX[@]}" new-session -d -s "$s" -n w -x "$COLS" -y "$ROWS" \
        "bash '$PAINTER' '$s'"
done

# Anchor session — plain interactive shell, no startup file noise.
"${TX[@]}" new-session -d -s home -n base -x "$COLS" -y "$ROWS" \
    "PS1='\$ ' bash --norc --noprofile"
"${TX[@]}" set-option -g status off
"${TX[@]}" set-option -g @explode-scope server

# Pane id of the home anchor, captured before explode (pane indices can move
# after split-window; pane ids stay stable).
HOME_PANE=$("${TX[@]}" display-message -p -t home:base.0 '#{pane_id}')

# Type a string into the home anchor pane character-by-character so the
# recording shows it being "typed", not pasted.
type_line() {
    local text="$1"
    local i ch
    for ((i=0; i<${#text}; i++)); do
        ch="${text:i:1}"
        "${TX[@]}" send-keys -t "$HOME_PANE" -l "$ch"
        sleep 0.04
    done
    "${TX[@]}" send-keys -t "$HOME_PANE" Enter
}

# Choreography. Runs in the background while asciinema records the foreground
# tmux attach. When this driver finishes it kills the server, which exits the
# attach and ends the recording cleanly.
(
    sleep 1.8
    type_line "# 8 sessions running. let me check on each one…"
    sleep 1.0

    for s in "${ORDER[@]}"; do
        "${TX[@]}" switch-client -t "$s"
        sleep 1.4
    done

    "${TX[@]}" switch-client -t home
    sleep 0.6
    type_line "# tedious. tmux_explode →"
    sleep 0.6
    "${TX[@]}" run-shell -t "$HOME_PANE" "$REPO_ROOT/scripts/overview_toggle.sh"
    sleep 5.0
    type_line "# much better."
    sleep 3.0
    "${TX[@]}" kill-server 2>/dev/null || true
) &
DRIVER=$!

# Record. Wrapping `tmux attach` in asciinema means the cast captures whatever
# the attached client renders — including switch-client jumps and the wall.
cd "$REPO_ROOT"
asciinema rec \
    --overwrite \
    --window-size "${COLS}x${ROWS}" \
    --idle-time-limit 1.5 \
    --command "$TMUX_BIN -L $SOCKET attach -t home" \
    "$CAST"

wait "$DRIVER" 2>/dev/null || true

echo "wrote $CAST"

if [[ "$WANT_GIF" -eq 1 ]]; then
    if command -v agg >/dev/null 2>&1; then
        agg --theme monokai --font-size 14 "$CAST" "$GIF"
        echo "wrote $GIF"
    else
        echo "agg not installed — skipping gif. brew install agg" >&2
    fi
fi
