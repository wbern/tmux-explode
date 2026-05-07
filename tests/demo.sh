#!/usr/bin/env bash
# Live demo of tmux_explode.
#
# Builds a representative topology on an isolated tmux socket, optionally
# fires the explode toggle, and then either prints capture-pane snapshots
# (headless) or attaches the calling terminal so you can watch it live.
#
# Usage:
#     ./tests/demo.sh session         # session-scope wall (4 windows, 6 panes)
#     ./tests/demo.sh server          # server-scope wall (5 sibling sessions)
#     ./tests/demo.sh session attach  # build, explode, attach to it
#     ./tests/demo.sh server  attach  # ditto for server-scope
#     ./tests/demo.sh session capture <out-dir>  # headless: dump snapshots
#     ./tests/demo.sh server  capture <out-dir>  # headless: dump snapshots
#
# Recording (run from your real terminal, not from inside an existing tmux):
#
#   asciinema rec -c './tests/demo.sh server attach' demo.cast
#
# or, on macOS, start screen recording (Cmd+Shift+5) and run:
#
#   ./tests/demo.sh server attach
#
# Detach the demo with `prefix + d` (default `C-b d`).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SOCKET="tmux_explode_demo_$$"
TMUX_CMD=(tmux -L "$SOCKET")

mode="${1:-server}"
action="${2:-attach}"
out_dir="${3:-/tmp/tmux-explode-demo}"

cleanup() {
    "${TMUX_CMD[@]}" kill-server 2>/dev/null || true
}
case "$action" in
    attach) ;;     # leave the server alive once attached so user sees it
    *) trap cleanup EXIT ;;
esac

unset TMUX TMUX_PANE

label_pane() {
    local target="$1" label="$2" quoted marker
    quoted=$(printf '%q' "$label")
    marker=">>> $label <<<"
    "${TMUX_CMD[@]}" send-keys -t "$target" \
        "clear; printf '\\n  >>> %s <<<\\n' $quoted; cat" Enter
    # Poll until the label is actually rendered, so downstream captures
    # see the printed marker rather than the still-buffered command line.
    for _ in $(seq 1 50); do
        if "${TMUX_CMD[@]}" capture-pane -p -t "$target" 2>/dev/null \
                | grep -qF "$marker"; then
            return 0
        fi
        sleep 0.1
    done
    echo "warning: label '$label' did not render in '$target'" >&2
}

build_session_topology() {
    "${TMUX_CMD[@]}" new-session -d -s demo -n alpha -x 160 -y 48
    label_pane "demo:alpha.0" "ALPHA"

    "${TMUX_CMD[@]}" new-window -t "demo:" -n bravo
    "${TMUX_CMD[@]}" split-window -t "demo:bravo" -h
    "${TMUX_CMD[@]}" split-window -t "demo:bravo" -v
    "${TMUX_CMD[@]}" select-layout -t "demo:bravo" tiled
    label_pane "demo:bravo.0" "BRAVO-1"
    label_pane "demo:bravo.1" "BRAVO-2"
    label_pane "demo:bravo.2" "BRAVO-3"

    "${TMUX_CMD[@]}" new-window -t "demo:" -n charlie
    label_pane "demo:charlie.0" "CHARLIE"

    "${TMUX_CMD[@]}" new-window -t "demo:" -n delta
    label_pane "demo:delta.0" "DELTA"

    "${TMUX_CMD[@]}" select-window -t "demo:alpha"
}

build_server_topology() {
    # home is created last so it's the most-recently-active session, which
    # makes the script's display-message resolution land on it without an
    # attached client.
    local s
    for s in coyote dingo emu falcon goose; do
        "${TMUX_CMD[@]}" new-session -d -s "$s" -n w -x 160 -y 48
        label_pane "$s:w.0" "$(echo "$s" | tr '[:lower:]' '[:upper:]')"
    done
    "${TMUX_CMD[@]}" new-session -d -s home -n base -x 160 -y 48
    label_pane "home:base.0" "HOME"
}

wait_for_panes() {
    # Poll until $target has at least $min_panes panes.
    local target_window="$1" min_panes="$2" count
    for _ in $(seq 1 50); do
        count=$("${TMUX_CMD[@]}" list-panes -t "$target_window" 2>/dev/null \
                | wc -l | tr -d ' ')
        if [[ "$count" -ge "$min_panes" ]]; then
            return 0
        fi
        sleep 0.1
    done
    echo "warning: '$target_window' did not reach $min_panes panes" >&2
}

case "$mode" in
    session)
        build_session_topology
        "${TMUX_CMD[@]}" set-option -g @explode-mode all
        "${TMUX_CMD[@]}" run-shell -t demo:alpha "$REPO_ROOT/scripts/overview_toggle.sh"
        target="demo:overview"
        wait_for_panes "$target" 6
        ;;
    server)
        build_server_topology
        "${TMUX_CMD[@]}" set-option -g @explode-scope server
        "${TMUX_CMD[@]}" run-shell -t home:base "$REPO_ROOT/scripts/overview_toggle.sh"
        target="home:overview"
        wait_for_panes "$target" 5
        ;;
    *)
        echo "unknown mode: $mode (want 'session' or 'server')" >&2
        exit 2
        ;;
esac

case "$action" in
    attach)
        echo "Demo running on socket '$SOCKET'."
        echo "Attaching now. Press 'prefix + d' (C-b d) to detach."
        echo "After detach, run: tmux -L $SOCKET kill-server"
        echo
        exec "${TMUX_CMD[@]}" attach -t "${target%:*}"
        ;;
    capture)
        mkdir -p "$out_dir"
        echo "Capturing snapshots into $out_dir"

        # Layout summary: pane bounds + origin + first text line.
        layout_file="$out_dir/${mode}-layout.txt"
        {
            echo "# tmux_explode $mode-scope demo"
            echo "# socket: $SOCKET"
            echo "# overview window: $target"
            echo
            "${TMUX_CMD[@]}" list-panes -t "$target" \
                -F 'pane=#{pane_id} pos=(#{pane_left},#{pane_top}) size=#{pane_width}x#{pane_height} orig_window=#{@orig_window} orig_session=#{@orig_session}'
        } > "$layout_file"
        echo "  wrote $layout_file"

        # SVG "screenshot" of the tiled layout: each pane becomes a rect,
        # labelled with its origin window/session and first non-empty line
        # of content. Real positions, real proportions — what an attached
        # client would see, sans the live cursor.
        svg_file="$out_dir/${mode}-layout.svg"
        win_w=$("${TMUX_CMD[@]}" display-message -p -t "$target" '#{window_width}')
        win_h=$("${TMUX_CMD[@]}" display-message -p -t "$target" '#{window_height}')
        cell_w=10  # pixels per character column
        cell_h=20  # pixels per character row
        {
            svg_w=$((win_w * cell_w))
            svg_h=$((win_h * cell_h))
            # Pad the canvas to a square viewBox so renderers that produce
            # square thumbnails (e.g. macOS qlmanage) don't crop the right
            # edge while scaling to fit height.
            svg_box=$((svg_w > svg_h ? svg_w : svg_h))
            echo "<svg xmlns='http://www.w3.org/2000/svg' width='$svg_box' height='$svg_box' viewBox='0 0 $svg_box $svg_box' preserveAspectRatio='xMinYMin meet' font-family='Menlo, monospace'>"
            echo "<rect width='100%' height='100%' fill='#0d1117'/>"
            while IFS='|' read -r pid left top w h orig; do
                px=$((left * cell_w))
                py=$((top * cell_h))
                pw=$((w * cell_w))
                ph=$((h * cell_h))
                # First non-empty content line
                first_line=$("${TMUX_CMD[@]}" capture-pane -p -t "$pid" \
                             | grep -m1 -v '^[[:space:]]*$' \
                             | sed 's/[<>&"]/_/g' \
                             | head -c 40 || true)
                # Header bar with origin label
                echo "  <g>"
                echo "    <rect x='$px' y='$py' width='$pw' height='$ph' fill='#1f2937' stroke='#3b82f6' stroke-width='2'/>"
                echo "    <rect x='$px' y='$py' width='$pw' height='24' fill='#3b82f6'/>"
                echo "    <text x='$((px + 8))' y='$((py + 17))' fill='#fff' font-size='14' font-weight='bold'>$pid &#8594; $orig</text>"
                echo "    <text x='$((px + 8))' y='$((py + 50))' fill='#9ca3af' font-size='13'>$first_line</text>"
                echo "  </g>"
            done < <("${TMUX_CMD[@]}" list-panes -t "$target" \
                     -F '#{pane_id}|#{pane_left}|#{pane_top}|#{pane_width}|#{pane_height}|#{?@orig_window,#{@orig_window},#{@orig_session}}')
            echo "</svg>"
        } > "$svg_file"
        echo "  wrote $svg_file"

        # Per-pane plain-text capture (no ANSI).
        while IFS= read -r pid; do
            txt="$out_dir/${mode}-pane-${pid#%}.txt"
            "${TMUX_CMD[@]}" capture-pane -p -t "$pid" > "$txt"
        done < <("${TMUX_CMD[@]}" list-panes -t "$target" -F '#{pane_id}')

        # ANSI capture per pane, rendered to a single HTML page with each
        # pane in a colour-preserving <pre> block. Requires `aha` (ANSI->HTML);
        # we skip this step gracefully if it isn't installed.
        html_file=""
        if command -v aha >/dev/null 2>&1; then
            html_file="$out_dir/${mode}-overview.html"
            {
                echo "<!doctype html><html><head><meta charset='utf-8'>"
                echo "<title>tmux_explode $mode-scope</title>"
                echo "<style>body{background:#111;color:#eee;font-family:Menlo,monospace}"
                echo "h2{color:#7af} pre{border:1px solid #333;padding:8px;margin:8px 0}</style>"
                echo "</head><body><h1>tmux_explode &mdash; $mode scope</h1>"
                while IFS= read -r pid; do
                    orig=$("${TMUX_CMD[@]}" display-message -p -t "$pid" \
                        '#{?@orig_window,#{@orig_window},#{?@orig_session,#{@orig_session},?}}')
                    echo "<h2>pane $pid &mdash; orig=$orig</h2>"
                    "${TMUX_CMD[@]}" capture-pane -p -e -t "$pid" \
                        | aha --no-header --black
                done < <("${TMUX_CMD[@]}" list-panes -t "$target" -F '#{pane_id}')
                echo "</body></html>"
            } > "$html_file"
            echo "  wrote $html_file"
        else
            echo "  skipped HTML overview (install 'aha' to enable: brew install aha)"
        fi
        echo
        echo "View artifacts:"
        echo "  open '$svg_file'          # SVG of the tiled layout"
        if [[ -n "$html_file" ]]; then
            echo "  open '$html_file'         # per-pane HTML render with colours"
        fi
        ;;
    *)
        echo "unknown action: $action (want 'attach' or 'capture')" >&2
        exit 2
        ;;
esac
