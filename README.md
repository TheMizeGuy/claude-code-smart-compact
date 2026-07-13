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

No server, no dependencies beyond python3 + tmux + git; everything is stdlib
hooks and shell wired through `~/.claude/settings.json`.

## Install

```bash
git clone https://github.com/TheMizeGuy/claude-code-smart-compact.git
cd claude-code-smart-compact
./install.sh                      # standard 200K-context sessions
# ./install.sh --window 1000000   # if you run extended-context sessions
```

Then restart your Claude Code sessions and see [SETUP.md](SETUP.md) for
verification, the ledger contract, env knobs, and troubleshooting.
`install.sh` is idempotent and backs up anything it overwrites.

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
| `tests/` | run in place | Regression suites against the INSTALLED system — 189 checks |
| `docs/ARCHITECTURE.md` | reference | Design, platform facts, failure modes, known limitations |

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

## License

MIT
