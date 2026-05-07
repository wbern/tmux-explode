# Contributing to tmux_explode

Thanks for your interest. This is a small project — issues and PRs are
welcome.

## Quick start

```sh
git clone https://github.com/wbern/tmux-explode
cd tmux-explode
./scripts/install-hooks.sh   # one-time: enables commit-msg policy
./tests/visual.sh            # run the full snapshot test suite
```

You'll need `bash 4+` (`brew install bash` on macOS), `tmux 3.3+`, and
`shellcheck` (optional — CI will catch lint issues either way).

## Conventional commits

Commit subjects must follow the
[Conventional Commits](https://www.conventionalcommits.org/) spec. The local
`commit-msg` hook enforces this, and
[semantic-release](https://github.com/semantic-release/semantic-release)
uses commit messages to compute the next version number on every push to
`main`.

```
<type>(<optional-scope>)!: <subject>

<optional body>

<optional footer(s)>
```

| Type       | Bumps   | Use for                                                        |
| ---------- | ------- | -------------------------------------------------------------- |
| `feat`     | minor   | A user-visible new capability or option                        |
| `fix`      | patch   | A user-visible bug fix                                         |
| `perf`     | patch   | A performance improvement                                      |
| `docs`     | none    | README / CHANGELOG / comments                                  |
| `refactor` | none    | Code change that neither adds a feature nor fixes a bug        |
| `test`     | none    | Adding or correcting tests                                     |
| `chore`    | none    | Maintenance (deps, repo housekeeping)                          |
| `build`    | none    | Build system, packaging, install scripts                       |
| `ci`       | none    | CI configuration                                               |
| `style`    | none    | Whitespace / formatting                                        |
| `revert`   | varies  | Reverts a previous commit (body should reference the SHA)      |

Append `!` after the type/scope (or include a `BREAKING CHANGE:` footer)
to bump the major version.

Examples:

```
feat(wall): add @explode-target-aspect knob
fix: don't dim panes the user is in copy-mode on
fix(wall)!: rename @explode-mode 'all' to 'every-pane'
```

## Code style

- Bash with `set -euo pipefail`.
- No comments explaining *what* the code does — names should carry that.
  Comments only for non-obvious *why* (a tmux quirk, a workaround, an
  invariant that isn't visible from the code).
- Prefer editing existing files over creating new ones.
- `shellcheck -S warning` must pass on `scripts/`, `tests/`, and `hooks/`.

## Tests

Every behavioural change should ship with a scenario in `tests/visual.sh`.
Scenarios run on an isolated tmux socket and assert against captured pane
output, so they're cheap and reliable.

```sh
./tests/visual.sh                # full suite
./tests/demo.sh server attach    # poke at it interactively
```

## What lands and what doesn't

- AI-attribution trailers (`Co-Authored-By: Claude`, `🤖 Generated with`,
  `Generated with Claude`) are rejected by the commit-msg hook.
- PRs that add a feature without a test, or that don't follow Conventional
  Commits, will be sent back for changes.

## Releases

Pushes to `main` trigger
[semantic-release](https://github.com/semantic-release/semantic-release),
which:

1. Reads commits since the last `vX.Y.Z` tag.
2. Computes the next version from the commit types.
3. Appends a section to `CHANGELOG.md`, tags the commit, and creates a
   GitHub Release with the generated notes.

There's no manual step. If you want to skip a release for a particular
push (e.g. CI-only changes that have no user impact), use one of the
non-bumping types from the table above.
