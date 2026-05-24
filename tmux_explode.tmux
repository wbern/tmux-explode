#!/usr/bin/env bash
# TPM entrypoint for tmux_explode.
# Reads user options and binds the toggle key. The toggle script itself
# re-reads runtime options on every invocation, so changes to @explode-mode
# or @explode-window-name take effect without re-sourcing tmux.conf.

CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

default_key="O"

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

key=$(get_tmux_option "@explode-key" "$default_key")

tmux bind-key "$key" run-shell "$CURRENT_DIR/scripts/overview_toggle.sh"

# Optional secondary binding that flips the attached-only filter on for one
# invocation via an env var, leaving @explode-only-attached untouched. Empty
# default → no binding installed, so existing users see no surprise keys.
attached_key=$(get_tmux_option "@explode-key-attached" "")
if [ -n "$attached_key" ]; then
    tmux bind-key "$attached_key" \
        run-shell "ONLY_ATTACHED_OVERRIDE=on $CURRENT_DIR/scripts/overview_toggle.sh"
fi
