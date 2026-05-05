# Repository conventions for Claude

## Commit messages

- Never include AI credits or co-author tags. No `Co-Authored-By: Claude …`,
  no `🤖 Generated with [Claude Code]`, no "Generated with Claude" line.
  The `commit-msg` hook in `hooks/commit-msg` rejects them anyway — write
  the message as if you wrote it yourself.
- One short subject line, then a blank line, then a body that explains the
  *why*. Keep it terse.

## Hook setup

Run `./scripts/install-hooks.sh` once after cloning to point this clone at
the tracked `hooks/` directory.

## Code style

- Bash with `set -euo pipefail`.
- No comments explaining *what* the code does — names should carry that.
  Comments only for non-obvious *why* (a workaround, a tmux quirk, an
  invariant that isn't visible from the code).
- Prefer editing existing files over creating new ones.

## Heads-up for future sessions

- **Author identity**: commits must be `wbern <wbern@users.noreply.github.com>`.
  Local repo config is already set; if you're in a fresh clone, set it before
  committing or you'll inherit whatever the surrounding harness configured.
- **Repo name quirk**: the directory and local `origin` URL say `tmux_explore`,
  but the canonical GitHub repo is `wbern/tmux-explode` (GitHub redirects the
  old name). Use `tmux-explode` in any user-facing snippet (README, install
  instructions, CI badges).
- **Gas Town artifacts in the working tree**: `.beads/`, `.claude/`,
  `.runtime/`, `mail/`, and `state.json` are runtime state from the agent
  harness that authored this branch. Gitignored. Don't try to "tidy" them
  into the repo — they don't belong.
