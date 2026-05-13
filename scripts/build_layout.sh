#!/usr/bin/env bash
# Generate a column-biased tmux layout string from a window size and a list of
# pane ids. Output is suitable for `tmux select-layout`. Standalone (no
# dependence on overview_toggle.sh) so it's easy to round-trip-test.
#
# Usage:
#   build_layout.sh <window_w> <window_h> <pane_id> [pane_id ...]
#   build_layout.sh --self-test          # round-trips through real tmux
#
# Tunables (env):
#   EXPLODE_MIN_PANE_WIDTH   default 40   floor on per-column width in cells
#   EXPLODE_TARGET_ASPECT_X10 default 5   target cell aspect ratio × 10
#                                         (5 = 0.5 = each cell ≈ 2× as tall as
#                                         it is wide; lower = taller cells)

set -euo pipefail

# Validate the two user-facing layout knobs (@explode-min-pane-width,
# @explode-target-aspect) and export them as EXPLODE_MIN_PANE_WIDTH and
# EXPLODE_TARGET_ASPECT_X10 for build_layout to consume. Shared between
# the toggle (initial wall build) and close_tile.sh (re-tile after a
# single-tile close) so both honour user configuration consistently.
#
# Strict regex validation guards against bash-arithmetic command
# substitution — see build_layout's caller comment for the threat model.
# Malformed values fall through with a status-bar warning rather than
# raising an error, matching the toggle's original behavior.
prepare_explode_layout_env() {
    local min_w aspect x10
    min_w=$(tmux show-option -gqv "@explode-min-pane-width" 2>/dev/null || true)
    aspect=$(tmux show-option -gqv "@explode-target-aspect" 2>/dev/null || true)
    if [[ -n "$min_w" ]]; then
        if [[ "$min_w" =~ ^[0-9]+$ ]]; then
            export EXPLODE_MIN_PANE_WIDTH="$min_w"
        else
            tmux display-message "tmux_explode: ignoring malformed @explode-min-pane-width" 2>/dev/null || true
        fi
    fi
    if [[ -n "$aspect" ]]; then
        if [[ "$aspect" =~ ^[0-9]*\.?[0-9]+$ ]]; then
            x10=$(awk -v v="$aspect" 'BEGIN { printf "%d", v*10 + 0.5 }')
            export EXPLODE_TARGET_ASPECT_X10="$x10"
        else
            tmux display-message "tmux_explode: ignoring malformed @explode-target-aspect" 2>/dev/null || true
        fi
    fi
}

tmux_layout_checksum() {
    local s="$1" csum=0 i c _o
    local saved_lc="${LC_CTYPE:-}"
    LC_CTYPE=C
    for (( i = 0; i < ${#s}; i++ )); do
        c="${s:i:1}"
        csum=$(( ((csum >> 1) + ((csum & 1) << 15)) & 0xffff ))
        printf -v _o '%d' "'$c"
        csum=$(( (csum + _o) & 0xffff ))
    done
    LC_CTYPE="$saved_lc"
    printf '%04x' "$csum"
}

# Pick K (column count) from window dims and pane count.
# Heuristic: K = ceil(sqrt(N · sx / (sy · target_aspect))), then clamp.
pick_columns() {
    local n=$1 sx=$2 sy=$3
    local min_w=${EXPLODE_MIN_PANE_WIDTH:-40}
    local ta=${EXPLODE_TARGET_ASPECT_X10:-5}
    # Reject anything that isn't pure digits BEFORE letting it touch a bash
    # arithmetic context — bash arithmetic resolves variable contents
    # recursively and `a[$(cmd)]` triggers command substitution. Callers
    # (overview_toggle.sh) already validate, but this is the second line of
    # defense for direct invocation of build_layout.
    [[ "$min_w" =~ ^[0-9]+$ ]] || min_w=40
    [[ "$ta" =~ ^[0-9]+$ ]] || ta=5
    # Clamp footgun inputs before they hit divisions. min_w=0 (user typo)
    # would crash on `sx / min_w`; ta=0 would crash inside the awk expr.
    (( min_w < 1 )) && min_w=1
    (( ta < 1 )) && ta=1
    local k
    k=$(awk -v n="$n" -v sx="$sx" -v sy="$sy" -v ta="$ta" \
        'BEGIN { v = n * sx * 10 / (sy * ta); k = sqrt(v); ck = int(k); if (ck < k) ck += 1; print ck }')
    (( k > n )) && k=$n
    local cap=$(( sx / min_w ))
    (( k > cap )) && k=$cap
    (( k < 1 )) && k=1
    printf '%d' "$k"
}

# Distribute total cells across n children with one-cell separators between.
# Prints n integers, one per line. First (total - n*base) get base+1, rest base.
split_cells() {
    local total=$1 n=$2
    local inner=$(( total - (n - 1) ))
    local base=$(( inner / n ))
    local rem=$(( inner % n ))
    local i
    for (( i = 0; i < n; i++ )); do
        if (( i < rem )); then printf '%d\n' $(( base + 1 ))
        else printf '%d\n' "$base"
        fi
    done
}

build_body() {
    local sx=$1 sy=$2; shift 2
    local -a panes=("$@")
    local n=${#panes[@]}

    if (( n == 1 )); then
        local id=${panes[0]#%}
        printf '%dx%d,0,0,%d' "$sx" "$sy" "$id"
        return 0
    fi

    local k
    k=$(pick_columns "$n" "$sx" "$sy")

    # Pane count per column (row-major fill: pane r*K+c lives at col c, row r)
    local -a cn
    local c
    for (( c = 0; c < k; c++ )); do
        cn[c]=$(( (n - c + k - 1) / k ))
    done

    # K=1: top-level is a single TB stack, no LR wrapper.
    if (( k == 1 )); then
        local body="${sx}x${sy},0,0["
        local -a heights
        mapfile -t heights < <(split_cells "$sy" "$n")
        local y=0 r
        for (( r = 0; r < n; r++ )); do
            local h=${heights[r]}
            local id=${panes[r]#%}
            body+="${sx}x${h},0,${y},${id}"
            (( r < n - 1 )) && body+=','
            y=$(( y + h + 1 ))
        done
        body+=']'
        printf '%s' "$body"
        return 0
    fi

    # Multi-column: outer LR of K columns, each column a leaf or TB stack.
    # Pane IDs in the layout string are assigned in DFS (depth-first) order to
    # match what tmux's select-layout writes back. tmux ignores the IDs we
    # supply when assigning real panes to slots — it walks the window's pane
    # list in TAILQ order and fills slots DFS — so any non-DFS ID order in our
    # string would round-trip as DFS anyway and break exact-match tests.
    local -a widths
    mapfile -t widths < <(split_cells "$sx" "$k")
    local body="${sx}x${sy},0,0{"
    local x=0
    local pane_idx=0
    for (( c = 0; c < k; c++ )); do
        local cw=${widths[c]} count=${cn[c]}
        if (( count == 1 )); then
            local id=${panes[pane_idx]#%}
            body+="${cw}x${sy},${x},0,${id}"
            pane_idx=$(( pane_idx + 1 ))
        else
            body+="${cw}x${sy},${x},0["
            local -a heights
            mapfile -t heights < <(split_cells "$sy" "$count")
            local y=0 r
            for (( r = 0; r < count; r++ )); do
                local h=${heights[r]}
                local id=${panes[pane_idx]#%}
                body+="${cw}x${h},${x},${y},${id}"
                pane_idx=$(( pane_idx + 1 ))
                (( r < count - 1 )) && body+=','
                y=$(( y + h + 1 ))
            done
            body+=']'
        fi
        (( c < k - 1 )) && body+=','
        x=$(( x + cw + 1 ))
    done
    body+='}'
    printf '%s' "$body"
}

build_layout() {
    local body
    body=$(build_body "$@")
    printf '%s,%s' "$(tmux_layout_checksum "$body")" "$body"
}

self_test() {
    local sock="build_layout_test_$$"
    local T=(tmux -f /dev/null -L "$sock")
    "${T[@]}" kill-server 2>/dev/null || true
    # Bake the socket name into the trap string at set-time. Referring to
    # ${T[@]} or $sock from the trap would explode under `set -u` when the
    # trap fires after self_test has returned and its locals are unset.
    # shellcheck disable=SC2064
    trap "tmux -f /dev/null -L $sock kill-server 2>/dev/null || true" EXIT

    local fail=0

    run_case() {
        local name="$1" sx="$2" sy="$3" n="$4"

        "${T[@]}" kill-server 2>/dev/null || true
        "${T[@]}" new-session -d -s s -n w -x "$sx" -y "$sy"
        local i
        for (( i = 1; i < n; i++ )); do
            "${T[@]}" split-window -t s:w -h
            "${T[@]}" select-layout -t s:w tiled >/dev/null
        done

        local pane_ids
        pane_ids=$("${T[@]}" list-panes -t s:w -F '#{pane_id}')
        local -a pids=()
        while IFS= read -r p; do pids+=("$p"); done <<< "$pane_ids"

        local layout
        layout=$(build_layout "$sx" "$sy" "${pids[@]}")
        local sent_csum=${layout%%,*}

        if ! "${T[@]}" select-layout -t s:w "$layout" 2>/tmp/build_layout_err; then
            echo "FAIL [$name] tmux rejected layout: $(cat /tmp/build_layout_err)"
            echo "  sent: $layout"
            fail=1; return
        fi

        local got
        got=$("${T[@]}" display-message -p -t s:w '#{window_layout}')
        local got_csum=${got%%,*}

        if [[ "$sent_csum" != "$got_csum" ]]; then
            echo "FAIL [$name] checksum drift after select-layout"
            echo "  sent: $layout"
            echo "  got : $got"
            fail=1; return
        fi
        if [[ "$layout" != "$got" ]]; then
            echo "FAIL [$name] layout string drifted after select-layout"
            echo "  sent: $layout"
            echo "  got : $got"
            fail=1; return
        fi

        local k
        k=$(pick_columns "$n" "$sx" "$sy")
        echo "PASS [$name] n=$n sx=$sx sy=$sy → K=$k → $layout"
    }

    run_case "tiny"           80  24  2
    run_case "tiny-six"       80  24  6
    run_case "wide-six"      200  50  6
    run_case "wide-eight"    200  50  8
    run_case "ultrawide-ten" 280  60 10
    run_case "wide-three"    200  50  3
    run_case "wide-one"      200  50  1
    run_case "tall-monitor"   80  60  6
    run_case "n-equals-k"    200  50  4

    if (( fail )); then
        echo "SELF-TEST FAILED"; return 1
    fi
    echo "SELF-TEST OK"
}

# Only run CLI dispatch when executed directly. When `source`d from
# overview_toggle.sh we just want the functions in scope.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [[ "${1:-}" == "--self-test" ]]; then
        self_test
        exit $?
    fi

    if (( $# < 3 )); then
        echo "usage: $0 <window_w> <window_h> <pane_id> [pane_id ...]" >&2
        echo "       $0 --self-test" >&2
        exit 64
    fi

    build_layout "$@"
fi
