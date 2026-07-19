#!/bin/bash
# Self-compaction for Claude Code sessions running inside tmux.
#
# The model cannot trigger compaction in-band (verified: no tool/hook/API), but
# when the session lives in a tmux pane, a detached watcher CAN type /compact
# into that pane exactly like the user would. Called BY the model (via Bash)
# at a clean boundary:
#
#   ~/.claude/scripts/self-compact.sh "<focus instructions>" "<continuation prompt>" [transcript]
#
# Pass the transcript path (arg 3) whenever known — the watermark nudge includes
# it. With two concurrent sessions in one cwd the newest-jsonl fallback can pick
# the OTHER session's transcript and the watcher waits on the wrong file.
#
# Flow (all in a detached watcher; the call returns immediately):
#   1. Wait for the CURRENT turn to end: transcript quiescent >= IDLE_S AND the
#      pane's busy indicator gone. Transcript mtime alone is not proof — long
#      tool calls write nothing for minutes while the turn is active, and
#      background task notifications append queue-operation entries between turns.
#      If an EXTERNAL compaction (auto-compact / user /compact) landed since
#      scheduling, ADOPT it: skip steps 2-3 and go straight to the continuation.
#   2. tmux send-keys "/compact <focus>" into $TMUX_PANE.
#   3. Wait for the compact_boundary SYSTEM entry to land in new transcript bytes.
#   4. Type the continuation prompt — the compact-rehydrate.py hook has already
#      re-injected the session ledger, so the model resumes sharp.
#
# Guards: refuses outside tmux; refuses in subagents (they inherit the parent's
# TMUX_PANE — calling this from an executor would compact the PARENT session);
# refuses when the pane isn't running the claude TUI, re-verified before EVERY
# send so nothing is ever typed into a shell that took over the pane; one
# watcher per pane (lock); every phase timeboxed; logs to
# ~/.claude/logs/self-compact.log. The continuation prompt is the safety net —
# without it a self-compacted session would sit idle waiting for input.
# Known interaction: an active /goal Stop hook that keeps blocking the stop delays
# turn-end; if the turn runs past IDLE_TIMEOUT (15 min) the watcher aborts
# (notified) and no compact happens — re-schedule at the next boundary.
# Queued-send handling (2026-07-17): a /compact that lands mid-turn does NOT
# execute — the TUI enqueues it (queue-operation transcript entry) and flushes
# it only at the REAL turn end; a Stop blocked by /goal does not flush it.
# Phase 3 detects the enqueue and holds QUEUED_TIMEOUT (4h default) for the
# turn end instead of timing out blind at 30 min; with zero evidence at all it
# sends one bare Enter after FLUSH_AFTER (swallowed-Enter recovery). Phase 4
# skips the continuation when the boundary was adopted mid-turn (an active
# session needs no wake-up).
# Usage-limit awareness (2026-07-09): /compact is a MODEL call and fails
# outright at usage-limit exhaustion. Phase 1 refuses to type into a
# limit-paused pane (banner with a future reset) and waits the reset out;
# Phase 3 detects the "Error during compaction" entry, retries once after the
# stated reset, and every pre-boundary failure clears the context-watermark
# sentinels so the nudge pipeline re-arms instead of staying muted.
set -u
FOCUS="${1:?usage: self-compact.sh \"<focus>\" \"<continuation prompt>\" [transcript]}"
CONTINUATION="${2:?continuation prompt required — without it the session idles after compaction}"
TRANSCRIPT="${3:-}"
PANE="${TMUX_PANE:-}"
LOG="${SELF_COMPACT_LOG:-$HOME/.claude/logs/self-compact.log}"   # override = tests only
IDLE_S="${SELF_COMPACT_IDLE_S:-8}"                  # transcript quiet this long = turn likely ended
IDLE_TIMEOUT="${SELF_COMPACT_IDLE_TIMEOUT:-900}"    # give up waiting for turn end after 15 min
# Boundary wait: a typed /compact QUEUES until the real turn end, and Stop
# hooks (verification gate, memory check, /goal) legitimately extend turns
# past 10 minutes — a 600s timeout lost the continuation on a compaction that
# then SUCCEEDED (observed live 2026-07-09: queued 10m36s, boundary at +13m).
# Failure cases don't need this timeout anymore (E_RE fail-fasts them;
# the shrink guard catches rotation; pane/PID guards catch replacement).
# A DETECTED queue (enqueue entry in the transcript) upgrades the wait to
# QUEUED_TIMEOUT: queued messages flush only at the real turn end, a Stop
# blocked by /goal does NOT flush them (verified live 2026-07-17: a /compact
# sat queued 10+ min into a 1h+ goal turn), and /goal
# turns legitimately run hours. COMPACT_TIMEOUT keeps covering the
# no-evidence case only.
COMPACT_TIMEOUT="${SELF_COMPACT_TIMEOUT:-1800}"     # give up waiting for the boundary after 30 min
QUEUED_TIMEOUT="${SELF_COMPACT_QUEUED_TIMEOUT:-14400}"  # boundary wait once the send is KNOWN queued (4h)
FLUSH_AFTER="${SELF_COMPACT_FLUSH_AFTER:-30}"       # zero evidence this long after the send -> one bare-Enter flush
LIMIT_RETRIES="${SELF_COMPACT_LIMIT_RETRIES:-1}"    # /compact re-sends after a usage-limit reset
LIMIT_GRACE="${SELF_COMPACT_LIMIT_GRACE:-180}"      # seconds past the stated reset before acting
LIMIT_WAIT_MAX="${SELF_COMPACT_LIMIT_WAIT_MAX:-21600}"  # never wait out a reset farther than this (6h)
mkdir -p "$(dirname "$LOG")"
if [ -f "$LOG" ] && [ "$(wc -c < "$LOG")" -gt 1048576 ]; then mv -f "$LOG" "$LOG.1"; fi
ts() { date '+%Y-%m-%dT%H:%M:%S'; }

# A newline in either arg would submit a partial line early and inject the rest
# as a separate message — collapse to spaces.
FOCUS=$(printf '%s' "$FOCUS" | tr '\n\r' '  ')
CONTINUATION=$(printf '%s' "$CONTINUATION" | tr '\n\r' '  ')
# Strip leading whitespace so a padded "  /clear" can't slip past the slash-guard
# below — the TUI trims leading space, which would re-expose the command.
CONTINUATION="${CONTINUATION#"${CONTINUATION%%[![:space:]]*}"}"
# Empty/space-only after sanitizing defeats the whole safety net (the session
# would submit nothing and idle) — refuse to schedule rather than strand it.
if [ -z "$CONTINUATION" ]; then
  echo "self-compact: continuation is empty after sanitizing — refusing (would idle the session)" >&2
  exit 2
fi
# A continuation starting with / ! or # would be read by the TUI as a slash
# command / bash-mode / memory-mode instead of a prompt ("/clear" would wipe
# the session).
case "$CONTINUATION" in
  /*|!*|'#'*) CONTINUATION="Continue: $CONTINUATION" ;;
esac

if [ -n "${CLAUDE_AGENT_ID:-}${CLAUDE_CODE_AGENT_ID:-}" ]; then
  echo "self-compact: running inside a subagent — refusing (this would compact the PARENT session)" >&2
  exit 2
fi
if [ -z "$PANE" ]; then
  echo "self-compact: NOT in tmux (TMUX_PANE unset) — self-compaction unavailable. Launch claude inside tmux (ctm) to enable it." >&2
  exit 2
fi

# The TUI's pane_current_command is 'claude', 'node', or — on v2.1.x native
# installs — the version string itself (the binary under
# ~/.local/share/claude/versions/ is literally named for the version). On disk
# it's dotted ('2.1.204'), but tmux renders pane_current_command with the dots
# as underscores ('2_1_204' — observed on 2.1.204), so accept EITHER separator
# ([._]) or the guard rejects the real TUI. Shells are excluded, so if claude exits mid-wait
# the abort paths below keep keystrokes out of whatever takes over the pane.
pane_is_claude() {
  tmux display-message -p -t "$PANE" '#{pane_current_command}' 2>/dev/null \
    | grep -Eq '^(claude|node|[0-9]+[._][0-9]+[._][0-9]+)$'
}
# True while the pane is NOT safely idle-at-prompt — a turn is actively running,
# a compaction is in flight (a line-leading 'Compacting…' spinner: transcript
# goes quiet and there may be no esc-hint, so without this the watcher reads
# mid-compaction as turn-end and types /compact into it, queuing a SECOND
# compaction — raced live 2026-07-08 05:30), OR a permission/confirmation
# dialog is open and waiting on the user. The dialog case is the real hazard:
# typing /compact + Enter INTO an open dialog can auto-approve an unreviewed
# tool call. False positives here only DELAY compaction (safe direction); the
# false negatives are what we defend against.
pane_busy() {
  local cap
  cap=$(tmux capture-pane -p -t "$PANE" 2>/dev/null)
  # Dialog / esc-hint / queued-input tells. 'esc to interrupt' is the classic
  # streaming hint; '\(esc to [a-z]' catches the per-state variants newer TUIs
  # render instead — "Waiting for task (esc to give additional instructions)"
  # was on screen 2026-07-17 while a /goal turn was ACTIVE,
  # this function said idle, and the typed /compact ENQUEUED instead of
  # executing. 'press up to edit queued messages' = input is already queued
  # behind a running turn — never stack /compact behind it.
  printf '%s\n' "$cap" | tail -n 18 \
    | grep -Eqi 'esc to interrupt|\(esc to [a-z]|do you want to|no, and tell claude|don.t ask again|press up to edit queued messages' && return 0
  # Live-activity status line: "✢ Wibbling… (1h 17m 43s · ↓ 162.0k tokens)" —
  # ellipsis + parenthesized elapsed counter, matched by SHAPE because the
  # 2.1.20x TUI carries no esc-hint on this line. Past-tense idle summaries
  # ("✻ Brewed for 49s · 1 monitor still running") and agent-status footers
  # ("… 46m 10s · ↓ 1.1m tokens") have no ellipsis-paren pair and stay
  # unmatched. Prose like "retrying… (30s timeout)" in the visible tail DOES
  # false-positive — accepted: a false busy only delays.
  printf '%s\n' "$cap" | tail -n 18 \
    | grep -Eq '(…|\.\.\.)[[:space:]]*\([0-9]+[hms]' && return 0
  # Compaction spinner: only the LAST 6 lines (a live status line lives at the
  # bottom) so line-leading 'compacting' in older scrollback prose can't wedge
  # the watcher toward IDLE_TIMEOUT; optional 'auto-' prefix covers a plausible
  # TUI phrasing variant. 'compacting' is line-start-anchored (modulo spinner
  # glyphs) so prose MENTIONING compaction doesn't pin the watcher.
  printf '%s\n' "$cap" | tail -n 6 \
    | grep -Eqi '^[^a-zA-Z0-9]*(auto[- ])?compacting'
}
# Unescaped SYSTEM-entry shapes, defined once and shared by every scan site.
# Entries that merely MENTION these (task notifications, tool results quoting
# them) carry \"-escaped quotes inside JSON strings, so both regexes reject
# them; whitespace tolerance around the colon future-proofs a formatting
# change. B_RE = compaction completed. E_RE = the typed /compact FAILED — the
# only transcript evidence is a local_command entry with a known failure text
# and no boundary ever lands. Two observed shapes: "Error during compaction: …"
# (the summarize MODEL CALL was rejected — usage-limit exhaustion, API errors;
# confirmed live 2026-07-08) and "Not enough messages to
# compact." (pre-flight refusal; caught live 2026-07-09). Failure texts are
# matched EXPLICITLY — a generic any-local_command match would false-positive
# on the success output ("Compacted (ctrl+o…)") if it lands a poll before the
# boundary entry, turning a successful compaction into an abort.
B_RE='"subtype"[[:space:]]*:[[:space:]]*"compact_boundary"'
E_RE='"subtype"[[:space:]]*:[[:space:]]*"local_command".*(Error during compaction|Not enough messages to compact)'
# Q_RE1+Q_RE2 = the typed /compact went into QUEUED MESSAGES instead of
# executing: the TUI logs {"type":"queue-operation","operation":"enqueue",
# "content":"/compact …"} the moment a send lands mid-turn. Matched as a PAIR
# on one line (order-independent, both unescaped) so task-notification
# enqueues (content "<task-notification>…") and entries merely QUOTING an
# enqueue (\"-escaped) never match. A queued send is armed, not lost — it
# fires at the real turn end — so Phase 3 holds QUEUED_TIMEOUT for it.
Q_RE1='"type"[[:space:]]*:[[:space:]]*"queue-operation".*"operation"[[:space:]]*:[[:space:]]*"enqueue"'
Q_RE2='"content"[[:space:]]*:[[:space:]]*"/compact'

# Parse "resets 9:50pm (America/New_York)" out of a limit banner / error entry
# into an epoch. A past time within the last 10 min is a just-elapsed reset and
# is returned as-is (retry-now signal); older past times map to the next day.
# Results more than LIMIT_WAIT_MAX ahead are REJECTED: session-limit resets are
# <=5h out, so a farther parse is a stale banner read on the wrong day (a
# 9:50pm banner still on-screen at 1am parses 20h ahead) or a weekly-limit
# shape this watcher must never wait out. rc 1 = no usable time.
parse_reset_epoch() {
  local text="$1" t tz day epoch now
  t=$(printf '%s' "$text" | grep -Eio 'resets (at )?[0-9]{1,2}(:[0-9]{2})?[ap]m' | head -1 | grep -Eio '[0-9]{1,2}(:[0-9]{2})?[ap]m')
  [ -z "$t" ] && return 1
  case "$t" in *:*) : ;; *) t="${t%??}:00${t#"${t%??}"}" ;; esac
  tz=$(printf '%s' "$text" | sed -nE 's/.*resets[^(]*\(([A-Za-z][A-Za-z0-9_/+-]*)\).*/\1/p' | head -1)
  if [ -n "$tz" ]; then
    day=$(TZ="$tz" date +%Y-%m-%d 2>/dev/null) || return 1
    epoch=$(TZ="$tz" date -j -f '%Y-%m-%d %I:%M%p' "$day $t" +%s 2>/dev/null) || return 1
  else
    day=$(date +%Y-%m-%d 2>/dev/null) || return 1
    epoch=$(date -j -f '%Y-%m-%d %I:%M%p' "$day $t" +%s 2>/dev/null) || return 1
  fi
  case "$epoch" in ''|*[!0-9]*) return 1 ;; esac
  now=$(date +%s)
  # Midnight fold (review 2026-07-09): the day field is always TODAY, so a
  # reset that elapsed within the last 10 min but BEFORE midnight ("resets
  # 11:55pm" read at 12:03am) parses ~24h in the FUTURE. Fold it back so the
  # just-elapsed retry-now window works across the day boundary.
  if [ "$epoch" -gt "$now" ] && [ $(( epoch - now )) -gt 85800 ]; then
    epoch=$(( epoch - 86400 ))
  fi
  if [ "$epoch" -le "$now" ] && [ $(( now - epoch )) -ge 600 ]; then
    epoch=$(( epoch + 86400 ))
  fi
  [ $(( epoch - now )) -gt "$LIMIT_WAIT_MAX" ] && return 1
  printf '%s' "$epoch"
}

# The pane shows a usage-limit banner with a still-future reset: the session is
# limit-BLOCKED (mid-turn pause, or idle after a failed command), not idle —
# the transcript is quiescent and there is no esc-hint, so without this check
# Phase 1 reads it as turn-end and types /compact into a stalled TUI, where it
# queues until the reset and executes long after every watcher timeout
# (observed 42 min late on a real session, 2026-07-08). Anchored to the TUI's rendering
# (leading whitespace/glyphs only — the live banner renders '  ⎿  You've hit
# your session limit · resets …') so prose QUOTING a banner mid-line, log
# tails, and bullet lists don't wedge the watcher (review 2026-07-09). Sets
# LIMIT_BANNER_KIND: '' no banner / 'timed' carries a clock time / 'timeless'
# banner with NO parseable clock (model-credit and weekly shapes) — the caller
# must ABORT on 'timeless', because such a pane is limit-blocked for an
# unknowable duration and anything typed queues latently. rc 0 (paused) only
# for a live banner with a future reset; a stale timed banner (reset passed /
# wrong-day) is scrollback history and returns 1 with kind 'timed'.
LIMIT_RESET_EPOCH=0
LIMIT_BANNER_KIND=""
pane_limit_paused() {
  local line
  LIMIT_BANNER_KIND=""
  line=$(tmux capture-pane -p -t "$PANE" 2>/dev/null | tail -n 18 \
    | grep -Ei "^[^a-zA-Z0-9]*You.{0,3}ve (hit|reached) your [a-zA-Z0-9 .]*limit" | tail -1)
  [ -z "$line" ] && return 1
  if printf '%s' "$line" | grep -Eiq 'resets (at )?[0-9]{1,2}(:[0-9]{2})?[ap]m'; then
    LIMIT_BANNER_KIND="timed"
  else
    LIMIT_BANNER_KIND="timeless"
    return 1
  fi
  LIMIT_RESET_EPOCH=$(parse_reset_epoch "$line") || return 1
  [ "$LIMIT_RESET_EPOCH" -gt "$(date +%s)" ]
}

# Wait until the pane is safely idle-at-prompt: transcript quiescent >= IDLE_S
# AND pane not busy AND no LIVE limit pause — all true in the same iteration
# as the send decision. Called by Phase 1 AND by the post-reset retry (review
# 2026-07-09: the retry used to jump straight to send_line, bypassing the
# dialog/busy/limit gates — typing into an open permission dialog can
# auto-approve an unreviewed tool call). A detected limit pause extends the
# deadline past the parsed reset (idle clock restarts once the banner clears),
# capped at limit_cap. The break-condition check runs BEFORE the deadline
# check so a wake from laptop sleep gets one salvage pass. Uses/updates
# globals: deadline, limit_cap. rc 0 safe to send; 1 deadline expired;
# 2 transcript unreadable; 3 timeless limit banner (limit-blocked, unknowable
# reset — caller must abort, never send).
wait_turn_end() {
  local now mt nd
  while :; do
    touch "$LOCK" 2>/dev/null   # heartbeat: proves this watcher is alive
    now=$(date +%s)
    mt=$({ stat -f %m "$TRANSCRIPT" 2>/dev/null || stat -c %Y "$TRANSCRIPT"; } 2>/dev/null) || return 2
    if [ $(( now - mt )) -ge "$IDLE_S" ] && ! pane_busy; then
      if pane_limit_paused; then
        nd=$(( LIMIT_RESET_EPOCH + LIMIT_GRACE + IDLE_TIMEOUT ))
        [ "$nd" -gt "$limit_cap" ] && nd=$limit_cap
        if [ "$nd" -gt "$deadline" ]; then
          deadline=$nd
          echo "[$(ts)] limit-paused pane (resets ~$(date -r "$LIMIT_RESET_EPOCH" '+%H:%M' 2>/dev/null)) — holding /compact until after the reset" >> "$LOG"
        fi
      elif [ "$LIMIT_BANNER_KIND" = "timeless" ]; then
        return 3
      else
        return 0
      fi
    fi
    [ "$now" -gt "$deadline" ] && return 1
    sleep 2
  done
}

# A compaction that never produced a boundary leaves the watermark pipeline
# wedged: precompact-recorder stamped `compacted` (mutes nudges 30 min) and the
# t1/t2/t3 one-shot sentinels stay consumed, so the model is never re-nudged
# to retry and the session runs fat into the built-in ceiling. Clearing them
# lets the next PostToolUse re-fire the highest tier — with the self-compaction
# instruction — which IS the retry loop for every pre-boundary failure. The
# ledger_path pin is deliberately kept. Key derivation mirrors
# context-watermark.py (sha1(transcript_path)[:16]). Never fails the caller.
clear_watermark_state() {
  local key d
  key=$(printf '%s' "$TRANSCRIPT" | shasum -a 1 2>/dev/null | cut -c1-16)
  d="${WATERMARK_STATE_ROOT:-/tmp/claude-context-watermark}/$key"
  [ -n "$key" ] && rm -f "$d/t1" "$d/t2" "$d/t3" "$d/compacted" 2>/dev/null
  return 0
}

# Sleep out a usage-limit reset (target epoch + LIMIT_GRACE), keeping the lock
# heartbeat fresh. The adoption scan runs BEFORE the time check (review
# 2026-07-09): a boundary landing in the final sleep slice — or during a
# laptop sleep that overshoots the target — must be adopted, not buried by the
# caller's baseline recompute and re-compacted. Returns 0 once the reset has
# passed, 1 if the pane stopped running the claude TUI, 2 if a compact_boundary
# landed while waiting (external compaction — adopt it instead of re-sending).
wait_for_reset() {
  local tgt=$(( $1 + LIMIT_GRACE )) now
  while :; do
    touch "$LOCK" 2>/dev/null
    tail -c +$(( size_before + 1 )) "$TRANSCRIPT" 2>/dev/null | grep -Eq "$B_RE" && return 2
    pane_is_claude || return 1
    now=$(date +%s)
    [ "$now" -ge "$tgt" ] && return 0
    sleep 20
  done
}

# Type "$1" into the pane and submit it. Re-verifies the pane still runs the
# claude TUI immediately BEFORE typing AND again immediately BEFORE Enter —
# claude can exit in the sub-second gap, and typing + Enter into the shell that
# takes over the pane would EXECUTE the text. C-u clears any half-typed draft;
# `--` stops tmux parsing a leading '-' as a flag; Enter is sent only if the
# literal-text send succeeded. Returns non-zero (Enter NOT sent) on any failed
# check so the caller aborts — a half-typed line then sits harmlessly in the
# shell, unsubmitted. "$2" is a short label for the log.
send_line() {
  pane_is_claude || { echo "[$(ts)] ABORT: pane no longer runs claude — $2 NOT sent" >> "$LOG"; return 1; }
  # Session-replacement guard (review 2026-07-09): a watcher can now live for
  # hours (limit-reset waits), long enough for the user to kill claude and
  # start a FRESH session in the same pane — pane_is_claude cannot tell them
  # apart, but the pane's root PID can when claude is the pane command (how
  # claude-tmux.sh/ctm launches it). PID unchanged for the same process => no false abort.
  if [ -n "${PANE_PID0:-}" ]; then
    [ "$(tmux display-message -p -t "$PANE" '#{pane_pid}' 2>/dev/null)" = "$PANE_PID0" ] \
      || { echo "[$(ts)] ABORT: pane root process changed (session replaced) — $2 NOT sent" >> "$LOG"; return 1; }
  fi
  tmux send-keys -t "$PANE" C-u 2>>"$LOG"
  sleep 0.2
  tmux send-keys -t "$PANE" -l -- "$1" 2>>"$LOG" || { echo "[$(ts)] ABORT: $2 send failed — Enter NOT sent" >> "$LOG"; return 1; }
  sleep 0.4
  pane_is_claude || { echo "[$(ts)] ABORT: pane changed after typing — $2 Enter NOT sent" >> "$LOG"; return 1; }
  tmux send-keys -t "$PANE" Enter 2>>"$LOG"
}
# Failure visibility: aborts used to be log-only, and a silently-missed
# self-compact means the session later slams into auto-compact mid-task
# instead of compacting at the chosen boundary. tmux status-line message +
# macOS banner (terminal-notifier, when installed); the LOG line remains the
# durable record and is written by the caller. Never fails the caller.
notify_fail() {
  tmux display-message -t "$PANE" "self-compact aborted: $1" 2>/dev/null
  if command -v terminal-notifier >/dev/null 2>&1; then
    terminal-notifier -title self-compact -message "aborted: $1" -group self-compact >/dev/null 2>&1
  fi
  return 0
}
# Non-failure operator visibility (queued sends, skipped continuations): same
# channels as notify_fail without the 'aborted' framing. Never fails the caller.
notify_note() {
  tmux display-message -t "$PANE" "self-compact: $1" 2>/dev/null
  if command -v terminal-notifier >/dev/null 2>&1; then
    terminal-notifier -title self-compact -message "$1" -group self-compact >/dev/null 2>&1
  fi
  return 0
}
if ! pane_is_claude; then
  CMD=$(tmux display-message -p -t "$PANE" '#{pane_current_command}' 2>/dev/null)
  echo "self-compact: pane $PANE runs '${CMD:-?}', not a claude TUI — refusing" >&2
  exit 2
fi
# Identity anchor for send_line's session-replacement guard (see there).
PANE_PID0=$(tmux display-message -p -t "$PANE" '#{pane_pid}' 2>/dev/null)

# Resolve the transcript if not passed. Prefer the session id from the
# harness env (CLAUDE_CODE_SESSION_ID is the real exported name; legacy
# CLAUDE_SESSION_ID kept as fallback) under the project slug. Slugs convert
# EVERY non-alphanumeric to '-', not just '/'
# (verified: /X/.claude/worktrees/y -> -X--claude-worktrees-y).
if [ -z "$TRANSCRIPT" ]; then
  SLUG=$(pwd | sed 's|[^A-Za-z0-9]|-|g')
  SID="${CLAUDE_CODE_SESSION_ID:-${CLAUDE_SESSION_ID:-}}"
  if [ -n "$SID" ] && [ -f "$HOME/.claude/projects/$SLUG/${SID}.jsonl" ]; then
    TRANSCRIPT="$HOME/.claude/projects/$SLUG/${SID}.jsonl"
  else
    # No session id to disambiguate: fall back to the newest transcript, but
    # REFUSE if a second transcript was touched within 120s of it. With two live
    # sessions in one cwd the newest-file guess can latch the WRONG one, and
    # Phase 3 would then poll a file that never receives THIS pane's boundary — a
    # guaranteed timeout with /compact already sent. Better to not compact than
    # to compact against the wrong transcript.
    TRANSCRIPT=$(ls -t "$HOME/.claude/projects/$SLUG"/*.jsonl 2>/dev/null | head -1)
    second=$(ls -t "$HOME/.claude/projects/$SLUG"/*.jsonl 2>/dev/null | head -2 | tail -1)
    if [ -n "$TRANSCRIPT" ] && [ -n "$second" ] && [ "$TRANSCRIPT" != "$second" ]; then
      mt1=$({ stat -f %m "$TRANSCRIPT" 2>/dev/null || stat -c %Y "$TRANSCRIPT"; } 2>/dev/null || echo 0)
      mt2=$({ stat -f %m "$second" 2>/dev/null || stat -c %Y "$second"; } 2>/dev/null || echo 0)
      if [ $(( mt1 - mt2 )) -lt 120 ]; then
        echo "self-compact: ambiguous transcript (2 recently-active sessions in this cwd) — pass the transcript path as arg 3; refusing to guess" >&2
        exit 2
      fi
    fi
  fi
fi
if [ -z "$TRANSCRIPT" ] || [ ! -f "$TRANSCRIPT" ]; then
  echo "self-compact: cannot resolve transcript (pass it as arg 3 — the watermark nudge includes it)" >&2
  exit 2
fi

# One watcher per pane: a second concurrent watcher would double-send /compact
# and the continuation. mkdir is the atomic take. Liveness of the holder is by
# its recorded PID (written below via the parent's $!, since $BASHPID doesn't
# exist in macOS /bin/bash 3.2); the per-iteration `touch` keeps the lock mtime
# fresh only as a fallback for the brief window before the pidfile is written.
# The lock key includes the tmux socket ($TMUX), not just the pane id: isolated
# per-launch `-S` servers each restart pane ids from %0, so pane id alone
# collides across unrelated sessions (two %0s -> one lock path -> a false
# "already scheduled" refusal). $TMUX is the socket,pid,session triple, unique
# per server.
LOCK="/tmp/self-compact-lock-$(printf '%s|%s' "${TMUX:-default}" "$PANE" | tr -c 'A-Za-z0-9' '_')"
# Liveness is decided by the watcher's real PID (kill -0), not wall-clock mtime.
# A laptop that sleeps mid-wait, or a hung tmux call, freezes the heartbeat past
# any mtime window while the watcher is still perfectly alive — a mtime-only
# check would then let a second invocation false-reclaim the lock and double-send
# /compact. kill -0 survives suspension. mtime is kept only as a fallback for the
# microscopic window between mkdir and writing the pidfile.
if ! mkdir "$LOCK" 2>/dev/null; then
  alive=0
  opid=$(cat "$LOCK/pid" 2>/dev/null || true)
  if [ -n "$opid" ]; then
    kill -0 "$opid" 2>/dev/null && alive=1
  else
    lock_mt=$({ stat -f %m "$LOCK" 2>/dev/null || stat -c %Y "$LOCK"; } 2>/dev/null || echo 0)
    [ $(( $(date +%s) - lock_mt )) -lt 60 ] && alive=1
  fi
  if [ "$alive" -eq 1 ]; then
    echo "self-compact: a watcher is already scheduled for pane $PANE — not scheduling a second" >&2
    exit 2
  fi
  rm -rf "$LOCK"
  mkdir "$LOCK" 2>/dev/null || { echo "self-compact: cannot take lock $LOCK" >&2; exit 2; }
fi

echo "[$(ts)] scheduling: pane=$PANE transcript=$TRANSCRIPT focus='$FOCUS'" >> "$LOG"

(
  trap 'rm -rf "$LOCK"' EXIT
  # Adoption baseline: bytes appended after THIS point may carry a
  # compact_boundary from an EXTERNAL compaction (auto-compact, or the user's
  # own /compact) racing the watcher — observed live 2026-07-08 05:30, where
  # the watcher's "boundary" was really someone else's.
  size_sched=$(wc -c < "$TRANSCRIPT" 2>/dev/null | tr -dc '0-9'); [ -z "$size_sched" ] && size_sched=0

  # Phase 1: wait for the current turn to end — the full gate lives in
  # wait_turn_end (shared with the post-reset retry): transcript quiescent AND
  # pane not busy AND no live limit pause, with the deadline extended past a
  # detected limit reset (capped at LIMIT_WAIT_MAX from scheduling).
  start=$(date +%s)
  deadline=$(( start + IDLE_TIMEOUT ))
  limit_cap=$(( start + LIMIT_WAIT_MAX ))
  wait_turn_end
  case $? in
    1) echo "[$(ts)] ABORT: turn never ended" >> "$LOG"; notify_fail "turn never ended"; clear_watermark_state; exit 1 ;;
    2) echo "[$(ts)] ABORT: transcript unreadable" >> "$LOG"; notify_fail "transcript unreadable"; clear_watermark_state; exit 1 ;;
    3) echo "[$(ts)] ABORT: limit banner without a parseable reset — pane is limit-blocked, /compact NOT typed (it would queue latently)" >> "$LOG"; notify_fail "limit-blocked pane, no parseable reset — /compact NOT sent"; clear_watermark_state; exit 1 ;;
  esac
  # Same read-failure guard as size_sched/cur_size — an empty size_before
  # would make Phase 3 rescan the WHOLE transcript ("tail -c +1") and match a
  # HISTORICAL boundary instantly. There is no safe numeric stand-in for "the
  # byte count right now", so an unreadable read aborts instead of defaulting.
  size_before=$(wc -c < "$TRANSCRIPT" 2>/dev/null | tr -dc '0-9')
  if [ -z "$size_before" ]; then
    echo "[$(ts)] ABORT: transcript size unreadable at turn end" >> "$LOG"; notify_fail "transcript size unreadable — /compact NOT sent"; clear_watermark_state; exit 1
  fi
  # NOTE (2026-07-08): a "transcript frozen at baseline => session dead/replaced"
  # abort lived here for a few hours and disabled self-compaction entirely
  # (6/6 real attempts aborted). It was WRONG: Phase 1 waits for the transcript
  # to go QUIESCENT, and the model calls this script as the LAST action of a
  # turn, so the transcript is routinely already at its final size when the
  # watcher captures size_sched. size_before == size_sched is the NORMAL healthy
  # case, not a dead session (proven: sessions flagged "dead" went on to
  # auto-compact alive). Detecting an in-pane session REPLACEMENT needs real
  # identity (declined: false-abort risk); the size proxy cannot and must not
  # try. send_line's pane_is_claude re-check remains the guard against typing
  # into a non-claude pane.

  # An external compaction that landed since scheduling makes /compact WRONG:
  # it would re-compact the freshly-compacted session. Adopt it instead — the
  # rehydrator already ran for it; only the continuation is still owed.
  # (size_before < size_sched = rotated transcript: adoption undecidable,
  # proceed normally and let Phase 3's shrink guard arbitrate.)
  if [ "$size_before" -ge "$size_sched" ] && tail -c +$(( size_sched + 1 )) "$TRANSCRIPT" 2>/dev/null | grep -Eq "$B_RE"; then
    echo "[$(ts)] external compaction detected since scheduling (${size_sched}B baseline) — adopting it, skipping /compact" >> "$LOG"
  else

  # Phase 2+3: type /compact (send_line re-verifies the pane runs claude both
  # before typing AND before Enter, so the focus text is never typed-and-
  # executed into a shell that took over the pane), then wait for the
  # compact_boundary SYSTEM entry in NEW transcript bytes. One outer iteration
  # per /compact send: when the model call FAILS at usage-limit exhaustion
  # (E_RE entry instead of a boundary), the watcher waits out the stated reset
  # and re-sends ONCE instead of burning the timeout blind.
  attempt=0
  while :; do
  send_line "/compact $FOCUS" "/compact" || { notify_fail "pane guard stopped the /compact send"; clear_watermark_state; exit 1; }
  echo "[$(ts)] /compact sent (transcript was ${size_before}B)" >> "$LOG"

  QUEUED_SEEN=0
  FLUSHED=0
  start=$(date +%s)
  while :; do
    touch "$LOCK" 2>/dev/null   # heartbeat
    # Scan order matters (review 2026-07-09): boundary FIRST — a success must
    # never be misread as a failure when both strings appear in one window —
    # and the timeout LAST, so a wake from laptop sleep that overshoots
    # COMPACT_TIMEOUT still gets one full scan before aborting (a compaction
    # that SUCCEEDED during the sleep must send its continuation).
    if tail -c +$(( size_before + 1 )) "$TRANSCRIPT" 2>/dev/null | grep -Eq "$B_RE"; then
      break 2
    fi
    errline=$(tail -c +$(( size_before + 1 )) "$TRANSCRIPT" 2>/dev/null | grep -E "$E_RE" | tail -1)
    if [ -n "$errline" ]; then
      errmsg=$(printf '%s' "$errline" | grep -Eo '<local-command-stdout>[^<]*' | head -1 | sed 's/^<local-command-stdout>//')
      echo "[$(ts)] compaction FAILED: ${errmsg:-unknown reason}" >> "$LOG"
      reset_epoch=$(parse_reset_epoch "$errline") || reset_epoch=""
      if [ "$attempt" -lt "$LIMIT_RETRIES" ] && [ -n "$reset_epoch" ]; then
        attempt=$(( attempt + 1 ))
        echo "[$(ts)] usage-limit blocked — retry $attempt/$LIMIT_RETRIES after the reset (~$(date -r "$reset_epoch" '+%H:%M' 2>/dev/null))" >> "$LOG"
        wait_for_reset "$reset_epoch"
        case $? in
          1) echo "[$(ts)] ABORT: pane no longer runs claude during the reset wait" >> "$LOG"; notify_fail "pane gone during limit-reset wait"; clear_watermark_state; exit 1 ;;
          2) echo "[$(ts)] external compaction landed during the reset wait — adopting it" >> "$LOG"; break 2 ;;
        esac
        # Re-gate exactly like Phase 1 before re-sending (review 2026-07-09):
        # the session may have auto-resumed at the reset and be mid-turn,
        # showing a permission dialog, or already auto-compacting — the
        # hazards pane_busy/wait_turn_end exist for. Fresh idle window;
        # limit_cap keeps the schedule-absolute ceiling.
        deadline=$(( $(date +%s) + IDLE_TIMEOUT ))
        wait_turn_end || { echo "[$(ts)] ABORT: pane never became safely idle after the reset (rc $?)" >> "$LOG"; notify_fail "post-reset idle wait failed — retry NOT sent"; clear_watermark_state; exit 1; }
        # Adoption re-check against the OLD baseline before rebaselining: a
        # boundary that landed during the idle wait (e.g. the resumed session
        # auto-compacted) means the work is already done.
        if tail -c +$(( size_before + 1 )) "$TRANSCRIPT" 2>/dev/null | grep -Eq "$B_RE"; then
          echo "[$(ts)] external compaction landed after the reset — adopting it" >> "$LOG"
          break 2
        fi
        # Fresh baseline for the retry: the failed attempt's bytes (error entry
        # included) must not satisfy or poison the next scan.
        size_before=$(wc -c < "$TRANSCRIPT" 2>/dev/null | tr -dc '0-9')
        [ -z "$size_before" ] && { echo "[$(ts)] ABORT: transcript size unreadable at retry" >> "$LOG"; notify_fail "transcript size unreadable — retry NOT sent"; clear_watermark_state; exit 1; }
        continue 2
      fi
      notify_fail "compaction failed: ${errmsg:-Error during compaction} — continuation NOT sent"
      clear_watermark_state
      exit 1
    fi
    # The send may have landed mid-turn and ENQUEUED instead of executing
    # (pane-render false-negatives race turn starts; live-caught 2026-07-17).
    # The enqueue entry means armed-not-lost: the /compact fires at the REAL
    # turn end — which a /goal Stop hook can push out for hours — so switch
    # this wait to QUEUED_TIMEOUT and hold rather than orphaning it.
    if [ "$QUEUED_SEEN" -eq 0 ] \
       && tail -c +$(( size_before + 1 )) "$TRANSCRIPT" 2>/dev/null | grep -E "$Q_RE1" | grep -Eq "$Q_RE2"; then
      QUEUED_SEEN=1
      echo "[$(ts)] /compact ENQUEUED mid-turn (queue-operation logged) — holding up to ${QUEUED_TIMEOUT}s for the real turn end" >> "$LOG"
      notify_note "/compact queued mid-turn — holding for the real turn end"
    fi
    # Zero evidence (no boundary, no failure entry, no enqueue) FLUSH_AFTER
    # seconds after the send: the submit-Enter was likely swallowed by a render
    # race and the text sits UNSUBMITTED in the input box. One bare Enter
    # flushes it; on an empty input it is a no-op, and a flush that lands
    # mid-turn merely enqueues — which the scan above then sees next poll.
    if [ "$FLUSHED" -eq 0 ] && [ "$QUEUED_SEEN" -eq 0 ] && [ $(( $(date +%s) - start )) -ge "$FLUSH_AFTER" ]; then
      FLUSHED=1
      if pane_is_claude \
         && { [ -z "${PANE_PID0:-}" ] || [ "$(tmux display-message -p -t "$PANE" '#{pane_pid}' 2>/dev/null)" = "$PANE_PID0" ]; } \
         && ! pane_busy \
         && tmux capture-pane -p -t "$PANE" 2>/dev/null | tail -n 18 | grep -qF '/compact'; then
        tmux send-keys -t "$PANE" Enter 2>>"$LOG"
        echo "[$(ts)] no execution evidence ${FLUSH_AFTER}s after the send, '/compact' still visible in an idle claude pane — flush Enter sent (swallowed-Enter recovery)" >> "$LOG"
      fi
    fi
    # A transcript that SHRANK below the pre-/compact size was rotated/truncated
    # (compaction only appends, so this is abnormal): the byte-offset scans
    # above read past EOF forever and would never see the boundary. Abort
    # fail-safe rather than burn the full timeout and blind-send the
    # continuation.
    cur_size=$(wc -c < "$TRANSCRIPT" 2>/dev/null | tr -dc '0-9'); [ -z "$cur_size" ] && cur_size="$size_before"
    [ "$cur_size" -lt "$size_before" ] && { echo "[$(ts)] ABORT: transcript shrank (${cur_size}B < ${size_before}B) — rotated/truncated, NOT sending continuation" >> "$LOG"; notify_fail "transcript rotated/truncated — continuation NOT sent"; clear_watermark_state; exit 1; }
    now=$(date +%s)
    tmo="$COMPACT_TIMEOUT"; [ "$QUEUED_SEEN" -eq 1 ] && tmo="$QUEUED_TIMEOUT"
    if [ $(( now - start )) -gt "$tmo" ]; then
      if [ "$QUEUED_SEEN" -eq 1 ]; then
        echo "[$(ts)] ABORT: no compact_boundary within ${tmo}s — the queued /compact is STILL ARMED in that session (recall it: press Up then Ctrl+U in the pane) — NOT sending continuation" >> "$LOG"
        notify_fail "queued /compact never fired within ${tmo}s — STILL ARMED in the pane (Up then Ctrl+U recalls it)"
      else
        echo "[$(ts)] ABORT: no compact_boundary within ${tmo}s — NOT sending continuation" >> "$LOG"
        notify_fail "no boundary within ${tmo}s — continuation NOT sent"
      fi
      clear_watermark_state
      exit 1
    fi
    sleep 3
  done
  done
  echo "[$(ts)] compact_boundary observed" >> "$LOG"

  fi

  # Phase 4: continuation. The 6s pause outlasts the rehydrator hook's 5000ms
  # settings.json budget, so its injected ledger context is in place before
  # the continuation submits — 2s raced it and could resume the model blind
  # on the one turn the rehydration exists for. If claude is GONE, abort.
  sleep 6
  # The boundary may be an ADOPTED external one (auto-compact mid-turn): the
  # session is then still actively working, and a continuation typed now would
  # only enqueue and fire — stale — at the eventual turn end. The net exists
  # to wake an IDLE post-compact session: give a busy pane up to 120s to go
  # idle (post-compact turns from queued task notifications resolve fast) and
  # skip the wake-up if it stays mid-turn.
  p4_deadline=$(( $(date +%s) + 120 ))
  while pane_busy && [ "$(date +%s)" -lt "$p4_deadline" ]; do
    touch "$LOCK" 2>/dev/null
    sleep 3
  done
  if pane_busy; then
    echo "[$(ts)] session still mid-turn 120s after the boundary — continuation SKIPPED (an active session needs no wake-up)" >> "$LOG"
    notify_note "boundary landed mid-turn — continuation skipped"
  else
    send_line "$CONTINUATION" "continuation" || { notify_fail "pane guard stopped the continuation send"; exit 1; }
    echo "[$(ts)] continuation sent" >> "$LOG"
  fi
) >/dev/null 2>&1 &
# Record the watcher's real PID so a later invocation's lock check (kill -0) can
# tell a live-but-suspended watcher from a dead one. The subshell's EXIT trap
# removes the whole lock dir (pidfile included) when it finishes.
printf '%s' "$!" > "$LOCK/pid" 2>/dev/null || true
disown 2>/dev/null || true
echo "self-compact: scheduled — after this turn ends the pane will receive '/compact $FOCUS', wait for the boundary, then receive the continuation prompt. Log: $LOG"
exit 0
