#!/usr/bin/env bash
set -euo pipefail

OVERVIEW="overview"
CURRENT=$(tmux display-message -p '#W')

if [[ "$CURRENT" == "$OVERVIEW" ]]; then
  while IFS=$'\t' read -r pane_id orig_name; do
    if [[ -n "${orig_name:-}" ]]; then
      tmux break-pane -d -s "$pane_id" -n "$orig_name"
    else
      tmux break-pane -d -s "$pane_id"
    fi
  done < <(tmux list-panes -F '#{pane_id}'$'\t''#{@orig_window}')
else
  tmux new-window -n "$OVERVIEW"
  while IFS=$'\t' read -r win_id win_name; do
    [[ "$win_name" == "$OVERVIEW" ]] && continue
    active=$(tmux list-panes -t "$win_id" -F '#{pane_id} #{?pane_active,1,0}' \
             | awk '$2==1 {print $1}')
    tmux set-option -p -t "$active" "@orig_window" "$win_name"
    tmux join-pane -s "$active" -t "$OVERVIEW"
  done < <(tmux list-windows -F '#{window_id}'$'\t''#{window_name}')

  placeholder=$(tmux list-panes -t "$OVERVIEW" -F '#{pane_id} #{@orig_window}' \
                | awk 'NF==1 {print $1}' | head -1)
  [[ -n "$placeholder" ]] && tmux kill-pane -t "$placeholder"

  tmux select-layout -t "$OVERVIEW" tiled
fi
