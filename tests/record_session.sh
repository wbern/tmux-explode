#!/usr/bin/env bash
# Wrapper used by the recording container to produce a finite asciinema cast.
# Mirrors `./tests/demo.sh server attach` but auto-detaches after a few seconds
# so the recording terminates cleanly.
set -euo pipefail

REPO_ROOT="/repo"
SOCKET="tmux_explode_rec_$$"
TMUX_CMD=(tmux -L "$SOCKET")

cleanup() { "${TMUX_CMD[@]}" kill-server 2>/dev/null || true; }
trap cleanup EXIT

unset TMUX TMUX_PANE

banner() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

label_pane() {
    local target="$1" label="$2" quoted marker
    quoted=$(printf '%q' "$label")
    marker=">>> $label <<<"
    "${TMUX_CMD[@]}" send-keys -t "$target" \
        "clear; printf '\\n  >>> %s <<<\\n' $quoted; cat" Enter
    for _ in $(seq 1 50); do
        "${TMUX_CMD[@]}" capture-pane -p -t "$target" 2>/dev/null \
            | grep -qF "$marker" && return 0
        sleep 0.1
    done
}

banner "Building 6 sibling tmux sessions (coyote dingo emu falcon goose home)…"
for s in coyote dingo emu falcon goose; do
    "${TMUX_CMD[@]}" new-session -d -s "$s" -n w -x 160 -y 48
    label_pane "$s:w.0" "$(echo "$s" | tr '[:lower:]' '[:upper:]')"
    printf '   • created %s\n' "$s"
done
"${TMUX_CMD[@]}" new-session -d -s home -n base -x 160 -y 48
label_pane "home:base.0" "HOME"
printf '   • created home\n'

# Silence the outer status bar so the recording shows the wall, not tmux chrome.
"${TMUX_CMD[@]}" set-option -g status off

banner "Firing tmux_explode toggle (scope=server)…"
"${TMUX_CMD[@]}" set-option -g @explode-scope server
"${TMUX_CMD[@]}" run-shell -t home:base "$REPO_ROOT/scripts/overview_toggle.sh"

# Wait for overview window to materialise.
for _ in $(seq 1 50); do
    count=$("${TMUX_CMD[@]}" list-panes -t home:overview 2>/dev/null | wc -l | tr -d ' ' || echo 0)
    [[ "$count" -ge 5 ]] && break
    sleep 0.1
done
banner "Overview window has $count tiled panes — attaching for 5 seconds…"
sleep 0.7

# Auto-terminate by killing the server. send-keys C-b d would land on the
# nested tmux client (one of the tiled inner attaches), not the outer one.
( sleep 5; "${TMUX_CMD[@]}" kill-server 2>/dev/null ) &

"${TMUX_CMD[@]}" attach -t home || true

banner "Done."
