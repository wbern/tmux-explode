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
