# smart-compact for Claude Code

Hooks that make Claude Code's context compaction land harmlessly, plus tmux
self-compaction.

When a long Claude Code session hits its auto-compact point, the conversation
is replaced by a summary and the model usually loses the thread: the active
task, the failing test output, the decisions already made. This system closes
that gap from both sides:

- **Before compaction**, a watermark hook watches real context occupancy and
  nudges the model to checkpoint its working state to a small on-disk ledger.
  If the model doesn't, a recorder hook extracts a mechanical ledger from the
  transcript anyway.
- **After compaction**, a rehydration hook injects the ledger straight back
  into the fresh context, so the session resumes with its exact task state
  instead of a paraphrase.
- **Optionally, in tmux**, the model can compact *itself* at a boundary it
  chooses: a detached watcher types `/compact <focus>` into the session's own
  pane, waits for the compaction to land, then types a continuation prompt.

The nudge tiers don't trust the nominal context window: Claude Code fires
auto-compact well below it, at a point that moves across builds, so the
watermark learns the EFFECTIVE ceiling from its own flight recorder and tiers
against that.

No server, no dependencies beyond python3 + tmux + git; everything is stdlib
hooks and shell wired through `~/.claude/settings.json`.

## Requirements

| Requirement | Notes |
|---|---|
| macOS | Primary platform. Linux needs a small port pass ([caveats](#honest-caveats-up-front)) |
| Claude Code | Installed and signed in (`claude --version`) |
| python3 | Stdlib only, no pip packages |
| tmux ≥ 3.3 | Only needed for self-compaction; the hook stack works without it |
| git | Used for the global-gitignore step and the auto-ledger's branch/dirty capture |
| terminal-notifier | Optional; abort banners degrade to tmux status messages without it |

## Install

```bash
git clone https://github.com/TheMizeGuy/claude-code-smart-compact.git
cd claude-code-smart-compact
./install.sh                      # standard 200K-context sessions
# ./install.sh --window 1000000   # if you run extended-context sessions
```

Pass `--window <tokens>` matching the real context window your sessions run
with. The value anchors the nudge tiers until the system has observed enough
real compactions to learn your actual auto-compact ceiling; a value far above
your real window means nudges never fire, so set it honestly.

What `install.sh` does (each step idempotent; anything it would overwrite is
backed up first as `*.pre-smart-compact-<timestamp>`):

1. Copies the 3 hooks to `~/.claude/hooks/` and the 4 scripts to
   `~/.claude/scripts/`.
2. Merges the hook wiring and the window env var into
   `~/.claude/settings.json` — existing entries and env values are never
   clobbered.
3. Adds `.claude/blackboard/` (where ledgers live) to your global gitignore.
4. Appends the tmux identity-scrub block to `~/.tmux.conf`, the `ctm`
   launcher alias to `~/.zshrc`, and a `# Compact instructions` section to
   `~/.claude/CLAUDE.md` — each skipped if already present.

Then **restart any running Claude Code sessions** (hooks load at session
start). Every step can also be done by hand — the exact file-by-file
breakdown is in [SETUP.md](SETUP.md) §2.

## Verify

```bash
cd tests && for t in test-*.sh; do bash "$t"; done   # 215 checks, 4 suites
```

The suites test the INSTALLED copies under `$HOME`, not the repo copies, and
sandbox all their state so they never pollute the live flight log. Smoke-test
the live wiring with a few tool calls in a fresh session, then confirm
`/tmp/claude-context-watermark/` contains state. After a Claude Code update,
run `python3 ~/.claude/scripts/check-harness-assumptions.py` to catch silent
drift in the internals this system reads. Full verification walkthrough:
[SETUP.md](SETUP.md) §3.

## Components

| Path | Installs to | Role |
|---|---|---|
| `hooks/context-watermark.py` | `~/.claude/hooks/` | PostToolUse + UserPromptSubmit: occupancy watermark; one-shot nudges at 75/87/94% of the LEARNED auto-compact ceiling (T1 externalize, T2 checkpoint ledger now, T3 imminent) |
| `hooks/precompact-recorder.py` | `~/.claude/hooks/` | PreCompact: flight recorder (the events log the ceiling estimator learns from), ledger snapshots, deterministic auto-ledger fallback, detached compaction-failure verifier |
| `hooks/compact-rehydrate.py` | `~/.claude/hooks/` | SessionStart (`compact` + `resume`): re-injects the model ledger and/or auto-ledger post-compaction (16KB-capped), or a recovery protocol when neither exists |
| `scripts/self-compact.sh` | `~/.claude/scripts/` | In-tmux self-compaction watcher |
| `scripts/claude-tmux.sh` | `~/.claude/scripts/` | Launcher (`ctm` alias): runs Claude Code inside an isolated per-session tmux server with identity-env scrub — the precondition for self-compaction |
| `scripts/tmux-global-env-scrub.sh` | `~/.claude/scripts/` | Server-birth backstop: scrubs stale `CLAUDE_CODE_*` identity vars from the tmux global env |
| `scripts/check-harness-assumptions.py` | `~/.claude/scripts/` | Drift detector for the undocumented Claude Code internals this system reads; run it after updates |
| `settings/settings-fragment.json` | merged into `~/.claude/settings.json` | Exact hook wiring + context-window env |
| `config/*` | appended to `~/.tmux.conf`, `~/.zshrc`, global gitignore, `~/.claude/CLAUDE.md` | Minimum tmux block, `ctm` alias, ledger gitignore, compact-instructions section |
| `tests/` | run in place | Regression suites against the INSTALLED system — 215 checks |
| `docs/ARCHITECTURE.md` | reference | Design, platform facts, failure modes, known limitations |

## Configuration

Everything ships with tested defaults; nothing needs tuning to start. The
knobs that exist (`CLAUDE_CODE_AUTO_COMPACT_WINDOW`, flight-log path, watcher
timeouts including the queued-send and usage-limit waits, state/log paths)
are tabulated in [SETUP.md](SETUP.md) §5, and the ledger contract the model
writes to is in §4.

## Uninstall

Remove the pieces in reverse; nothing else on the machine is touched:

1. Delete the three hook entries this repo added from the `hooks` section of
   `~/.claude/settings.json` (they reference `context-watermark.py`,
   `precompact-recorder.py`, `compact-rehydrate.py`), and the
   `CLAUDE_CODE_AUTO_COMPACT_WINDOW` env entry if you don't want to keep it.
2. Delete the installed files from `~/.claude/hooks/` and
   `~/.claude/scripts/` (the 7 files in the Components table).
3. Remove the appended blocks from `~/.tmux.conf`, `~/.zshrc`,
   `~/.claude/CLAUDE.md`, and your global gitignore if desired — each is a
   clearly-delimited snippet matching the files under `config/`.
4. Optionally clear runtime state: `/tmp/claude-context-watermark/`,
   `~/.claude/logs/compact-events.log`, `~/.claude/logs/self-compact.log`,
   and any `.claude/blackboard/` ledger dirs in your projects.

Any file the installer overwrote has a `*.pre-smart-compact-<timestamp>`
backup beside it to restore from.

## Honest caveats, up front

- **macOS-flavored.** `stat -f`, `/tmp` purge semantics, optional
  terminal-notifier. Linux needs a small port pass (contributions welcome).
- **Reads undocumented internals.** Transcript `message.usage`,
  `compact_boundary` entries, hook `agent_id` fields. Everything is built to
  fail SAFE (a format change disarms a feature, it never breaks a session),
  and `check-harness-assumptions.py` detects silent disarmament.
  But a Claude Code update can quiet the system until the next sync.
- **The nudge→ledger step depends on model compliance.** That is why the
  deterministic auto-ledger exists: even when the model never checkpoints,
  a mechanical extract of the final minutes is injected after compaction.
- **Self-compaction requires tmux.** A bare-terminal session cannot type
  `/compact` into itself. Launch with `ctm <name>` to have the power.

## Docs

- [SETUP.md](SETUP.md) — install detail, verification, operation, env knobs,
  troubleshooting.
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — design and rationale: the
  effective-ceiling estimator, the ledger/rehydration lattice, self-compaction
  guards, failure modes, known limitations.

## License

MIT
