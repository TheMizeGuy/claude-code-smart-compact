# Architecture: watermark → ledger → rehydrate

The goal: make Claude Code's compaction point land harmlessly. The model
checkpoints state to a session ledger BEFORE compaction fires, and the exact
state is re-injected AFTER, so the running chat stays sharp instead of
restarting from a lossy summary.

The core insight came from flight-recorder data: **Claude Code fires
auto-compact well BELOW the nominal `CLAUDE_CODE_AUTO_COMPACT_WINDOW`**, at a
point that moves across builds. Nudge tiers pinned to the nominal window sat
ABOVE the real trigger and never fired; most compactions landed with no ledger.
So the system learns the EFFECTIVE ceiling from its own observations and adds
a deterministic auto-ledger floor for the compactions no nudge can cover.

## Platform facts the design is built on

- Compaction CANNOT be triggered, blocked, or postponed programmatically.
  PreCompact hooks are notification-only. `/compact <focus>` is manual-only
  (which is why self-compaction has to type into a tmux pane).
- SessionStart matcher `compact` fires after every compaction and its
  `additionalContext` IS injected into the post-compact context.
- The `# Compact instructions` section of `~/.claude/CLAUDE.md` shapes both
  manual and auto summaries.
- Occupancy is computable from the transcript: the latest assistant entry's
  `message.usage` token sum.

## The three hooks

### context-watermark.py (PostToolUse + UserPromptSubmit, ~22ms/call)

- Occupancy via a bounded 256KB reverse-scan of the transcript; window W =
  `CLAUDE_CODE_AUTO_COMPACT_WINDOW` → settings.json fallback → 1M.
- **Effective ceiling**: C = median of the last 5 genuine auto-compact
  occupancies from the flight log (`COMPACT_EVENTS_LOG`; manual/agent/`event`
  lines ignored), clamped to [0.5W, W]; fewer than 2 samples → 0.85W fallback.
  Self-corrects across Claude Code updates that move the real trigger point.
  **Tiers apply to C, not W.**
- One-shot nudges (sentinel files under the state root, keyed by transcript
  hash):
  - **T1 at 75% of C**: start externalizing; create/refresh the ledger at the
    next boundary.
  - **T2 at 87% of C**: CHECKPOINT NOW; the full ledger template is injected
    with the exact path; prefer finishing the current unit; suggests manual
    `/compact`.
  - **T3 at 94% of C**: compact imminent; ensure the ledger is current.
  - Nudges state both numbers (expected ceiling and nominal window), and
    T2/T3 carry a live ledger-status line (MISSING / "updated Nm ago") so the
    nudge is self-auditing rather than assuming compliance.
- Correctness guards (each one audit-driven and regression-tested): subagent
  events are ignored entirely (they arrive with the PARENT's transcript);
  firing a tier marks all lower tiers; an exclusive-create sentinel prevents
  parallel double-fire; a `compact_boundary` in the transcript tail before any
  assistant usage means occupancy UNKNOWN (prevents post-compact stale
  re-fire); the `compacted` stamp suppresses until refill with a 30-min expiry
  (aborted compacts); a ratio band discards garbage readings (>1.3×C never
  fires; 1.0–1.3×C clamps) so a session whose true auto point exceeds the
  estimate still gets its highest tier; re-arm happens when occupancy drops
  below 55% of C or once a compaction is stamp-confirmed; the ledger path is
  pinned in the state dir at nudge time (cwd-drift-proof); 10s rate limit;
  7-day state GC; a 1000-token ceiling floor so a typo'd tiny window degrades
  silent-but-alive instead of crashing.
- State lives in `/tmp` deliberately: per-conversation and ephemeral; the
  worst a purge can cause is one repeat nudge.

### precompact-recorder.py (PreCompact, manual + auto)

Flight recorder: appends `{ts, session_id, trigger, occupancy, ledger_present,
agent}` to the events log (1MB rotation); snapshots the ledger (keeps 3);
stamps `compacted` for the watermark.

**Auto-ledger**: when the model ledger is missing or >20 min old, writes
`LEDGER.auto.md` (≤6KB), a deterministic extraction from the transcript tail:
the last genuine user messages (wrappers, meta, and sidechain entries
excluded; the post-compaction continuation blob is filtered as a runtime
artifact), files edited (Edit/Write/NotebookEdit plus symbol-editing MCP
tools, ordered-deduped), a git-commit flag, the last assistant text, the last
errored tool result, git branch + dirty count (2s timeouts), occupancy, and
memory-tool write IDs (gated on the create-response signature so retrieval
hits never masquerade as writes). A content-free extract writes NO stub so the
rehydrator falls through to recovery cleanly. Extraction is per-entry
exception-guarded (one malformed line skips that line, never the whole
extract), and every event line carries an `auto_ledger:` status so a failing
extractor is visible in the flight log. Subagent compactions are logged but
never touch parent state.

The recorder also spawns a detached verifier (`COMPACT_VERIFY_DELAY_S`) for
ANY compaction that never produces a boundary: it re-arms the watermark state
and logs a `compact-verify-failed` event. Without this, one failed compaction
consumed the sentinels and the model was never re-nudged to retry; the session
ran fat to the ceiling, where auto-compact failed at the same limit.

### compact-rehydrate.py (SessionStart, matchers `compact` + `resume`)

- **Injection lattice (16KB total cap)**: model ledger <6h → verbatim with
  age-tiered trust ("authoritative" <2h, "verify against the summary" 2–6h),
  plus a fresh (<15m) `LEDGER.auto.md` appended as a final-minutes extract
  when the model ledger is >20m old. No usable model ledger but fresh auto →
  auto alone, explicitly flagged as mechanical/lower fidelity. Neither → a
  4-line recovery protocol. The cap counts the FULL emitted context; when the
  model block spends the budget the auto block is SKIPPED, never squeezed.
- Appends a `rehydrate` event (outcome + ledger ages) to the events log, which
  tracks the ledger-miss rate; the ceiling estimator skips `event` lines.
- The `resume` matcher covers ONLY the crash window: a `compact_boundary` in
  the transcript tail with no persisted rehydration after it (the session died
  between compacting and persisting the re-injection). The boundary match is
  the UNESCAPED system-entry regex, so tool results QUOTING the string (for
  example, a session reading these very hooks) never count. Normal resumes
  stay silent.
- Clears tier sentinels; leaves `compacted` for the watermark's refill check.

## The ledger contract

`<cwd>/.claude/blackboard/<session_id>/LEDGER.md`, written by the MODEL when
nudged (the template arrives in the T2 nudge): Goal & acceptance criteria ·
Now (active task + next 3 actions) · Done so far · Decisions & constraints ·
Files/symbols touched · Verbatim critical state · Memory writes. Keep <8KB.
Git-safe: the global gitignore ignores `.claude/blackboard/` everywhere.

## Self-compaction (tmux sessions)

The model cannot compact in-band, but when the session runs INSIDE tmux,
`self-compact.sh "<focus>" "<continuation>"` gives it the real thing: a
detached watcher waits for the current turn to end (transcript quiescence AND
the busy indicator gone), types `/compact <focus>` into the session's own
pane, waits for the `compact_boundary` to land, then types the continuation
prompt, by which time the rehydrator has re-injected the ledger.

Protocol: write the ledger FIRST, then call self-compact.sh with a
continuation naming the exact next action, then end the turn. The T2/T3
nudges advertise availability automatically when `$TMUX_PANE` is set,
including the exact transcript path to pass as arg 3 (the script's own
resolution is ambiguous with two concurrent sessions in one cwd).

Guards, each of which exists because the naive version failed in practice:

- Refuses outside tmux, inside subagents, and on non-claude panes; the pane
  check accepts `claude`, `node`, or a bare version string with dotted OR
  underscore separators (tmux renders the native binary's dotted name with
  underscores on some builds), re-verified before every send.
- Turn-end detection uses transcript quiescence AND the pane busy indicator
  (mtime alone misfires on long tool calls); the busy check includes 'esc to
  interrupt', a line-leading compacting spinner checked only in the last 6
  pane lines (so scrollback prose can't wedge the watcher), and open
  permission dialogs.
- **Adoption**: an EXTERNAL compaction (auto or user-typed) landing between
  scheduling and send is detected via a size-at-schedule boundary check and
  ADOPTED: `/compact` is skipped, only the continuation is sent.
- Every transcript byte-count read is failure-guarded (an empty `wc -c` would
  make the scan rescan the whole file and match a HISTORICAL boundary).
- Boundary detection greps the unescaped `"subtype":"compact_boundary"`
  system entry (content mentions arrive escaped).
- One watcher per pane+socket (PID-liveness lock); every phase is timeboxed;
  no boundary observed → no continuation sent (never types into an
  uncompacted session); the pre-continuation pause outlasts the rehydrator's
  hook budget so the model never resumes ahead of its re-injected ledger.
- A pane root-PID anchor aborts sends when the pane's claude was REPLACED
  during an hours-long wait; every abort path notifies (tmux status message +
  desktop banner) because a silently-missed self-compact means auto-compact
  later lands mid-task.

### Usage-limit hardening

`/compact` is a MODEL call: at usage-limit exhaustion the typed command
executes (PreCompact fires, a phantom "manual" line lands in the flight log)
but the summarize request is rejected and no boundary ever lands. The watcher
therefore scans new transcript bytes for the explicit failure shapes ("Error
during compaction", "Not enough messages to compact"; boundary checked FIRST,
and the failure texts stay explicit because a generic match would
false-positive on success output racing the boundary). On a parseable
usage-limit reset time it waits the reset out (heartbeats, adopts an external
boundary, aborts if the pane dies) and re-sends `/compact` ONCE through the
same turn-end gate as the original send. A visible limit banner with a
still-future reset means NOT idle, so the watcher never types into a stalled
TUI; a TIMELESS banner (credit-exhaustion shapes) aborts instead of queueing
a latent `/compact`. Timers: the boundary timeout defaults to 1800s because a
typed `/compact` QUEUES until the real turn end and Stop hooks legitimately
extend turns past 10 minutes; the recorder's verifier keeps its own 600s
because it counts from PreCompact (execution), not from the keystroke.

### The launcher (claude-tmux.sh / `ctm`)

Sessions must be LAUNCHED inside tmux to have self-compaction. The launcher
gives each session its OWN tmux server on an explicit socket (no shared
server, so nothing can cross sessions), scrubs Claude identity env vars at
three layers (a server born inside a Claude session would otherwise freeze
that session's identity into the tmux global environment, and every wrapped
launch would boot believing it is a nested child of a dead session, with a
degraded runtime configuration and wrong context ceiling), pins the session identity via
`--session-id`, and GCs dead sockets/registry rows at every launch. Named
`ctm <name>` sessions persist and reattach; the scrub layers are update-proof
(any `CLAUDE_CODE_*` var a future Claude Code update stamps into the global
env is discovered dynamically and scrubbed too).

## Surviving Claude Code updates

Documented APIs (hook events/matchers, additionalContext shapes, the window
env, `/compact`) are stable surface. The UNDOCUMENTED internals this system
reads (transcript `message.usage`, `compact_boundary`, `isSidechain`,
hook-event `agent_id`/`agent_type`, versioned pane names, and the flight-log
record schema the ceiling estimator learns from) all fail SAFE: a format
change disarms a feature (watermark silent or reverted to the nominal
fallback, no continuation typed) but never breaks a session. Silent
disarmament is then caught by `check-harness-assumptions.py`: it validates
the usage-signal against real recent transcripts, that hooks are still
creating watermark state, and that the ceiling estimator can still parse
occupancy out of the flight log's auto records, naming the current claude
version in its failure output. Run it after Claude Code updates or on a
periodic cadence.

## Verification

The shipped state passed 189 regression checks across four suites (see
SETUP.md §3), an end-to-end run of the real self-compact script against a
stub tmux (schedule → /compact → limit failure → reset retry → boundary →
continuation), live self-compactions on real sessions, and multiple
independent adversarial review passes during development. One design lesson
those reviews earned the hard way: a guard premised on "state X always
changes" is unsound when an earlier phase explicitly WAITS for X to stop
changing; a plausible-looking dead-session check with exactly that premise
disabled self-compaction entirely until flight-log data exposed it, and a
regression test now asserts the healthy case proceeds.

## Known accepted limitations

- A context window far below the configured nominal window means nudges never
  fire; the system degrades to the pre-system status quo.
- An OS purge of `/tmp` after multi-day idle costs at most one repeat nudge.
- Subagent-internal compaction gets no ledger protocol of its own (logged
  only).
- A ledger written inside a since-deleted git worktree dies with the
  worktree.
- Blackboard session dirs accumulate (git-ignored); deliberately not
  auto-GC'd.
- The nudge→ledger step depends on model compliance; the ledger-status line,
  the compact instructions, and the recovery protocol are the layered
  mitigations, and the deterministic auto-ledger removes the total-loss case.
- The effective ceiling is an estimate learned from ≤5 samples; per-session
  variance is absorbed by the clamp band, and estimator failure degrades to
  the 0.85W fallback, never to silence.
