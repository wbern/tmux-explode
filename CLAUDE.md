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
