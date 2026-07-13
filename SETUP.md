# SETUP: install, verification, and operation

Follow in order; verify each step before the next. Assumes macOS with Claude
Code already installed and signed in.

## 1. Prerequisites

| Requirement | Check | Install |
|---|---|---|
| python3 (stdlib only) | `python3 --version` | `xcode-select --install` |
| tmux ≥ 3.3 (allow-passthrough) | `tmux -V` | `brew install tmux` |
| git | `git --version` | preinstalled |
| Claude Code | `claude --version` | code.claude.com |
| terminal-notifier (optional) | `command -v terminal-notifier` | `brew install terminal-notifier`; self-compact abort banners degrade to tmux messages without it |

## 2. Install

```bash
git clone https://github.com/TheMizeGuy/claude-code-smart-compact.git
cd claude-code-smart-compact
./install.sh
```

Pass `--window <tokens>` if your sessions don't run the standard 200K context
window (for example `--window 1000000` on an extended-context model config).
The value anchors the watermark tiers until the system has observed enough
real compactions to learn your effective ceiling from its own flight log.

`install.sh` is idempotent and backs up anything it overwrites
(`*.pre-smart-compact-<ts>`). What it does, in case you need to do any step by
hand:

1. Copies the 3 hooks to `~/.claude/hooks/` and the 4 scripts to
   `~/.claude/scripts/`; `chmod +x` on all.
2. Creates `~/.claude/logs` and `~/.claude/state/tmux-{sockets,sessions}`.
3. Merges `settings/settings-fragment.json` into `~/.claude/settings.json`:
   `CLAUDE_CODE_AUTO_COMPACT_WINDOW` in `env`, context-watermark on
   PostToolUse + UserPromptSubmit, precompact-recorder on PreCompact,
   compact-rehydrate on SessionStart matchers `compact` and `resume`. Existing
   entries and env values are never clobbered.
4. Ensures the global gitignore ignores `.claude/blackboard/` (ledgers must
   never be committed).
5. Appends `config/tmux.conf.snippet` to `~/.tmux.conf` unless the identity
   scrub is already there.
6. Appends the `ctm` alias to `~/.zshrc` unless present.
7. Appends the `# Compact instructions` section to `~/.claude/CLAUDE.md`
   unless present (it shapes what both manual and auto compaction preserve).

Then restart any running Claude Code sessions; hooks load at session start.

## 3. Verify

```bash
cd tests && for t in test-*.sh; do bash "$t"; done
```

The suites test the INSTALLED copies under `$HOME`, not the repo copies; on a
machine without step 2 they fail, they don't skip. Expected:

| Suite | Checks | Covers |
|---|---|---|
| `test-watermark.sh` | 42 | ceiling estimator, tier thresholds, ratio band, re-arm, fallbacks |
| `test-compact-hooks.sh` | 69 | auto-ledger extraction, rehydration lattice, 16KB cap, verifier spawn, log rotation, agent guards |
| `test-self-compact-logic.sh` | 71 | pane-busy/limit-banner parsing, adoption semantics, reset-time folding |
| `test-self-compact-e2e.sh` | 7 | the real script against a stub tmux: schedule → /compact → limit failure → reset retry → boundary → continuation |

All suites use `mktemp` sandboxes and set `COMPACT_EVENTS_LOG` so they never
pollute the real flight log (the ceiling estimator LEARNS from that log;
pollution literally re-tunes it).

Smoke test the live wiring:

```bash
source ~/.zshrc
ctm scratch                 # a Claude session inside its own tmux server
```

In that session do a few tool calls, then from another terminal confirm the
watermark hook is creating state: `ls /tmp/claude-context-watermark/`. After a
day of real usage, run `python3 ~/.claude/scripts/check-harness-assumptions.py`;
exit 0 means the harness internals the system reads still hold.

## 4. How it operates (the short version)

Full design and rationale: `docs/ARCHITECTURE.md`.

- **Watermark**: occupancy is computed from the transcript's latest assistant
  `message.usage`. Tiers fire at 75% (T1: start externalizing), 87% (T2:
  write the ledger NOW, template + exact path injected), and 94% (T3:
  imminent) of the EFFECTIVE ceiling: the median of the last 5 observed
  auto-compact occupancies from the flight log, not the nominal window (the
  harness fires well below it, and the trigger point moves across builds).
- **Ledger contract**: `<cwd>/.claude/blackboard/<session_id>/LEDGER.md`,
  written by the model when nudged. Goal & acceptance criteria · Now · Done so
  far · Decisions & constraints · Files/symbols touched · Verbatim critical
  state · Memory writes. Keep <8KB.
- **Auto-ledger floor**: if the model ledger is missing or >20 min old at
  compaction, the recorder writes a deterministic `LEDGER.auto.md` extract
  from the transcript tail; the total-loss case is gone even when nothing
  was checkpointed.
- **Rehydration**: after every compaction (and after a crash between
  compacting and persisting), the SessionStart hook re-injects the model
  ledger (<6h, age-tiered trust), the fresh auto-ledger, or a recovery
  protocol, capped at 16KB total.
- **Self-compaction** (tmux sessions only): write the ledger FIRST, then
  `~/.claude/scripts/self-compact.sh "<focus>" "<continuation prompt>"`, then
  end the turn. A detached watcher waits for turn end, types
  `/compact <focus>` into the session's own pane, waits for the
  `compact_boundary`, then types the continuation, by which time the
  rehydrator has re-injected the ledger. T2/T3 nudges advertise this
  automatically when `$TMUX_PANE` is set. Sessions must be LAUNCHED inside
  tmux (`ctm <name>`) to have this power.
- **Usage-limit hardening**: a `/compact` typed at usage-limit exhaustion
  fails without a boundary; the watcher detects the failure shapes
  fail-fast, waits out a parseable reset and retries once, and every failure
  path re-arms the watermark so the model gets re-nudged.

## 5. Env knobs

All optional; defaults are the tested configuration.

| Var | Default | Meaning |
|---|---|---|
| `CLAUDE_CODE_AUTO_COMPACT_WINDOW` | `200000` via `--window` (settings env) | Nominal compaction window; estimator fallback anchor (0.85W when <2 flight-log samples) |
| `COMPACT_EVENTS_LOG` | `~/.claude/logs/compact-events.log` | Flight log path. Tests MUST override it |
| `COMPACT_VERIFY_DELAY_S` | `600` | Recorder's detached boundary-verifier delay |
| `SELF_COMPACT_TIMEOUT` | `1800` | Watcher's boundary wait (covers /compact queued behind long Stop-hook turns) |
| `SELF_COMPACT_IDLE_TIMEOUT` / `SELF_COMPACT_IDLE_S` | script defaults | Phase-1 turn-end wait / quiescence window |
| `SELF_COMPACT_LIMIT_WAIT_MAX` | 6h | Max parseable usage-limit reset the watcher will wait out |
| `SELF_COMPACT_LIMIT_RETRIES` | `1` | /compact resends after a limit-failure reset |
| `SELF_COMPACT_LOG` | `~/.claude/logs/self-compact.log` | Watcher log (1MB rotation) |
| `WATERMARK_FORCE` | unset | Test-only: bypass rate limit/sampling |
| `WATERMARK_STATE_ROOT` | `/tmp/claude-context-watermark` | Sentinel/state dir |
| `CLAUDE_TMUX_*` (`NAME`, `KEEP`, `SOCK_DIR`, `REG_DIR`, `OAUTH_WARN_N`, …) | launcher defaults | claude-tmux.sh controls; exempt from the identity scrub |

## 6. Portability caveats

- macOS-flavored: `stat -f`, `/tmp` purge semantics, terminal-notifier.
  A Linux port needs a pass over those.
- On a context window much smaller than the configured
  `CLAUDE_CODE_AUTO_COMPACT_WINDOW`, nudges never fire; the system degrades
  to stock behavior, it doesn't break. Set `--window` honestly.
- The system reads UNDOCUMENTED harness internals (`message.usage`,
  `compact_boundary`, `isSidechain`, hook `agent_id`). All fail SAFE on a
  format change (feature disarms, session unaffected);
  `check-harness-assumptions.py` catches silent disarmament; run it after
  Claude Code updates or on whatever periodic cadence you have.

## 7. Troubleshooting

| Symptom | Look at |
|---|---|
| No nudges ever fire | `/tmp/claude-context-watermark/` state exists? `CLAUDE_CODE_AUTO_COMPACT_WINDOW` set to your real window? `check-harness-assumptions.py` |
| Compactions land with no rehydration | `~/.claude/logs/compact-events.log`: `rehydrate` lines and their `outcome`; ledger age at compaction |
| self-compact.sh aborts | `~/.claude/logs/self-compact.log`: every abort path logs + notifies; common: not in tmux, pane not claude, permission dialog open, usage-limit banner |
| Tiers feel mistuned after a Claude Code update | Flight log auto lines still parseable? Estimator falls back to 0.85W on schema drift; run the drift checker |
| Wrapped session boots degraded / wrong context ceiling | Identity scrub missing: `~/.tmux.conf` block present? `tmux-global-env-scrub.sh` executable? |
