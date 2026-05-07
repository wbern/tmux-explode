#!/usr/bin/env bash
# Background poller spawned by overview_toggle.sh while an in-place wall is
# active. Every TICK seconds it captures each tile's visible buffer, hashes
# it, and — when the hash changes — updates the per-pane @pane_last_change
# epoch. Each tick it also recomputes a bucket glyph from `now -
# last_change` and stores it in @heat for pane-border-format to render.
#
# Bucket-in-poller (rather than format-arithmetic) keeps the format string
# simple and side-steps the 3.2-era format-time math. Storing a TIMESTAMP
# rather than a stateful "is it hot" flag is what lets a quiet pane visibly
# cool on the next tick without needing a fresh event.
#
# Exits silently when the wall window disappears (toggle-off, server quit,
# user kills the window) so teardown can rely on PID-stash kill + natural
# exit as belt-and-braces.

set -u

SOCKET="${1:?socket path required}"
WIN_ID="${2:?window id required}"
TICK="${3:-2}"

# Cool/cold panes get a dimmed pane-style so the user's eye can skip
# over quiet tiles without scanning. Defaults set bg= (not fg=) because
# TUIs like Claude Code emit explicit ANSI fg colors on almost every
# cell — pane-style fg only "shows through" on cells that don't set fg
# themselves, which is rare on agent walls. bg dimming is far more
# reliable: most TUIs leave bg at default, so a slight gray bg recedes
# the whole tile against the surrounding terminal black. Set
# EXPLODE_DIM_COLD=off to disable, or override the per-tier styles via
# EXPLODE_STYLE_COOL / EXPLODE_STYLE_COLD.
DIM_COLD="${EXPLODE_DIM_COLD:-on}"
STYLE_COOL="${EXPLODE_STYLE_COOL:-bg=colour234}"
STYLE_COLD="${EXPLODE_STYLE_COLD:-bg=colour237}"

T() { tmux -S "$SOCKET" "$@"; }

# Strip CSI (`ESC [ ... letter`), OSC (`ESC ] ... BEL/ST`), and a couple of
# 2-byte designators. `capture-pane -p` without `-e` already drops most
# escapes, but pipe-pane-flavored capture leaks them and the test harness
# sometimes feeds escaped content via send-keys. Better safe than every
# spinner pane reading hot forever.
ANSI_STRIP_RE=$'s/\x1b\\[[0-9;?]*[A-Za-z]//g; s/\x1b\\][^\x07\x1b]*(\x07|\x1b\\\\)//g; s/\x1b[()][AB012]//g'

while :; do
    # Window vanished → wall is gone, exit cleanly.
    T list-panes -t "$WIN_ID" >/dev/null 2>&1 || exit 0

    now=$(date +%s)

    while IFS=$'\t' read -r pane_id in_mode; do
        [[ -z "$pane_id" ]] && continue

        # Copy mode: user is reading the buffer. Don't update last_change
        # (would falsely refresh the timer on scroll) and don't recompute
        # @heat (would misleadingly cool while output may still be flowing
        # behind the scrollback view). Freeze whatever glyph is showing.
        if [[ "$in_mode" == "1" ]]; then
            continue
        fi

        content=$(T capture-pane -p -t "$pane_id" 2>/dev/null) || continue
        clean=$(printf '%s' "$content" | sed -E "$ANSI_STRIP_RE")
        hash=$(printf '%s' "$clean" | shasum 2>/dev/null | awk '{print $1}')
        [[ -z "$hash" ]] && continue

        last_hash=$(T show-options -pqv -t "$pane_id" "@pane_last_hash" 2>/dev/null) || last_hash=""
        last_change=$(T show-options -pqv -t "$pane_id" "@pane_last_change" 2>/dev/null) || last_change=""
        first_sight=$(T show-options -pqv -t "$pane_id" "@pane_first_sight" 2>/dev/null) || first_sight=""

        if [[ -z "$last_hash" ]]; then
            # First sight of this pane. Record the hash as a BASELINE only —
            # we have no prior state to compare against, so we can't honestly
            # claim activity. last_change stays unset; the glyph branch
            # below renders the "unknown" state until either a real diff
            # arrives or enough time elapses to confidently call this idle.
            T set-option -p -t "$pane_id" "@pane_last_hash" "$hash" 2>/dev/null || true
            if [[ -z "$first_sight" ]]; then
                T set-option -p -t "$pane_id" "@pane_first_sight" "$now" 2>/dev/null || true
                first_sight=$now
            fi
        elif [[ "$hash" != "$last_hash" ]]; then
            T set-option -p -t "$pane_id" "@pane_last_hash" "$hash" 2>/dev/null || true
            T set-option -p -t "$pane_id" "@pane_last_change" "$now" 2>/dev/null || true
            last_change=$now
        fi

        style=""
        if [[ -n "$last_change" ]]; then
            age=$(( now - last_change ))
            if   (( age < 5 ));   then glyph='🔥'
            elif (( age < 30 ));  then glyph='🌶'
            elif (( age < 120 )); then glyph='💤'; style="$STYLE_COOL"
            else                       glyph='❄';  style="$STYLE_COLD"
            fi
        else
            # No activity has ever been observed on this pane. Show neutral
            # while we wait, then fall through to the cool/cold buckets so a
            # genuinely idle pane doesn't sit on ⚪ forever.
            [[ -z "$first_sight" ]] && first_sight=$now
            wait=$(( now - first_sight ))
            if   (( wait < 120 )); then glyph='⚪'
            elif (( wait < 240 )); then glyph='💤'; style="$STYLE_COOL"
            else                        glyph='❄';  style="$STYLE_COLD"
            fi
        fi
        [[ "$DIM_COLD" == "off" ]] && style=""

        T set-option -p -t "$pane_id" "@heat" "$glyph" 2>/dev/null || true

        # Only re-issue pane-style when the desired style changes — every
        # set-option on pane-style triggers a redraw, and panes that sit
        # on the same bucket for many ticks shouldn't flicker.
        prev_style=$(T show-options -pqv -t "$pane_id" "@heat_style" 2>/dev/null) || prev_style=""
        if [[ "$prev_style" != "$style" ]]; then
            if [[ -n "$style" ]]; then
                T set-option -p -t "$pane_id" pane-style "$style" 2>/dev/null || true
            else
                T set-option -p -u -t "$pane_id" pane-style 2>/dev/null || true
            fi
            T set-option -p -t "$pane_id" "@heat_style" "$style" 2>/dev/null || true
        fi
    done < <(T list-panes -t "$WIN_ID" -F $'#{pane_id}\t#{pane_in_mode}' 2>/dev/null || true)

    # `refresh-client` (no -S): tmux issue #570 — `-S` doesn't redraw
    # borders when status-right is empty, which we can't assume isn't.
    T refresh-client 2>/dev/null || true

    sleep "$TICK"
done
