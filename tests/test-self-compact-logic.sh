#!/bin/bash
# Offline logic tests for ~/.claude/scripts/self-compact.sh.
# The script is un-sourceable (top-level arg checks + scheduling side effects),
# so pane_busy/send_line are EXTRACTED from the file at runtime and evaluated
# against stubbed tmux/pane_is_claude — the tests always exercise the shipped
# definitions, never a hand-copied snapshot that can drift.
set -u
SRC="$HOME/.claude/scripts/self-compact.sh"
P=0; F=0
ok(){ P=$((P+1)); printf 'PASS: %s\n' "$1"; }
bad(){ F=$((F+1)); printf 'FAIL: %s\n' "$1"; }

extract_fn() { sed -n "/^$1() {/,/^}/p" "$SRC"; }
for fn in pane_busy send_line notify_fail; do
  [ -n "$(extract_fn "$fn")" ] || { bad "cannot extract $fn() from $SRC"; echo "---- $P passed, $F failed"; exit 1; }
done

# --- stubs the extracted functions call into ---
PANE="%0"; LOG=/dev/null; PANE_CONTENT=""; TMUXLOG=""; VERDICTS=""
ts(){ echo T; }
sleep(){ :; }
tmux() {
  case "$1" in
    capture-pane) printf '%s\n' "$PANE_CONTENT" ;;
    display-message) TMUXLOG="$TMUXLOG|display:$*"; case "$*" in *pane_pid*) printf '%s\n' "${PANE_PID_NOW:-}";; esac ;;
    send-keys) TMUXLOG="$TMUXLOG|$*"; case "$*" in *"-l -- FAILSEND"*) return 1;; esac ;;
  esac
  return 0
}
pane_is_claude(){ local v="${VERDICTS:0:1}"; VERDICTS="${VERDICTS:1}"; [ "$v" = "y" ]; }
eval "$(extract_fn pane_busy)"
eval "$(extract_fn send_line)"

echo "== A) pane_busy: turn-active, compaction, permission dialogs, idle =="
PANE_CONTENT="esc to interrupt";                          pane_busy && ok "active turn busy" || bad "active turn"
PANE_CONTENT="✻ Compacting…";                             pane_busy && ok "spinner Compacting busy" || bad "spinner compacting"
PANE_CONTENT="Compacting conversation";                   pane_busy && ok "bare Compacting busy" || bad "bare compacting"
PANE_CONTENT="⏺ Auto-compacting…";                        pane_busy && ok "Auto-compacting variant busy" || bad "auto-compacting"
PANE_CONTENT="we will be compacting the session later";   pane_busy && bad "prose 'compacting' false-positive" || ok "mid-line prose not busy"
PANE_CONTENT=$'- compacting the vault later\nl2\nl3\nl4\nl5\nl6\nl7\n> '
pane_busy && bad "old scrollback 'compacting' bullet wedged the watcher" || ok "compacting bullet beyond last-6 lines not busy"
PANE_CONTENT=$'x\n- compacting soon\n> '
pane_busy && ok "line-leading compacting within last-6 busy (safe direction)" || bad "bottom compacting line missed"
PANE_CONTENT="Do you want to proceed?";                   pane_busy && ok "permission dialog busy" || bad "perm dialog"
PANE_CONTENT="  2. Yes, and don't ask again";             pane_busy && ok "don't-ask-again busy" || bad "dont-ask"
PANE_CONTENT="  3. No, and tell Claude what to do differently"; pane_busy && ok "no-and-tell busy" || bad "no-and-tell"
PANE_CONTENT="> ";                                        pane_busy && bad "idle prompt busy" || ok "idle prompt not busy"
PANE_CONTENT="? for shortcuts     tokens: 0";             pane_busy && bad "shortcuts line busy" || ok "shortcuts not busy"
# 2026-07-17 live-caught renders: the 2.1.20x TUI renders
# per-state esc-hints and a timer status line WITHOUT 'esc to interrupt'. All
# of the busy ones below were on screen while a /goal turn was ACTIVE — the old
# pane_busy said idle and the typed /compact ENQUEUED into queued messages,
# where it sat (a blocked Stop does NOT flush the queue) until hand-recalled.
PANE_CONTENT="     Waiting for task (esc to give additional instructions)"
pane_busy && ok "task-wait esc-variant busy" || bad "task-wait esc-variant missed"
PANE_CONTENT="✢ Wibbling… (1h 17m 43s · ↓ 162.0k tokens)"
pane_busy && ok "running timer status line busy" || bad "running timer status missed"
PANE_CONTENT="✻ Hatching… (3s)"
pane_busy && ok "short timer status line busy" || bad "short timer status missed"
PANE_CONTENT="✻ Baking… (esc to interrupt)"
pane_busy && ok "legacy spinner esc-hint still busy" || bad "legacy spinner regressed"
PANE_CONTENT="❯ Press up to edit queued messages"
pane_busy && ok "queued-messages hint busy (input already queued)" || bad "queued-messages hint missed"
PANE_CONTENT="✻ Brewed for 49s · 1 monitor still running"
pane_busy && bad "idle past-tense summary (monitor) false-positive" || ok "idle summary w/ background monitor not busy"
PANE_CONTENT="✻ Crunched for 1m 24s · 1 shell still running"
pane_busy && bad "idle past-tense summary (shell) false-positive" || ok "idle summary w/ background shell not busy"
PANE_CONTENT="  ◯ release  Autonomous release pipeline    9/10 agents done · 46m 10s · ↓ 1.1m tokens"
pane_busy && bad "agent-status footer false-positive" || ok "agent-status footer not busy"

echo "== B) send_line: Enter ONLY when pane is claude before AND after typing =="
VERDICTS="yy"; TMUXLOG=""; send_line "hello" "t"; rc=$?
{ [ $rc -eq 0 ] && case "$TMUXLOG" in *Enter*) true;; *) false;; esac; } && ok "both-claude: Enter sent, rc0" || bad "both-claude (rc=$rc log=$TMUXLOG)"
VERDICTS="n"; TMUXLOG=""; send_line "hello" "t"; rc=$?
{ [ $rc -eq 1 ] && [ -z "$TMUXLOG" ]; } && ok "pre-check shell: nothing typed, rc1" || bad "pre-check shell (rc=$rc log=$TMUXLOG)"
VERDICTS="yn"; TMUXLOG=""; send_line "hello" "t"; rc=$?
{ [ $rc -eq 1 ] && case "$TMUXLOG" in *Enter*) false;; *"-l -- hello"*) true;; *) false;; esac; } && ok "post-type shell: typed, Enter NOT sent, rc1" || bad "post-type shell (rc=$rc log=$TMUXLOG)"
VERDICTS="yy"; TMUXLOG=""; send_line "FAILSEND" "t"; rc=$?
{ [ $rc -eq 1 ] && case "$TMUXLOG" in *Enter*) false;; *) true;; esac; } && ok "literal-send fails: Enter NOT sent, rc1" || bad "literal-fail (rc=$rc log=$TMUXLOG)"
PANE_PID0=123 PANE_PID_NOW=456 VERDICTS="y"; TMUXLOG=""; send_line "hello" "t"; rc=$?
{ [ $rc -eq 1 ] && case "$TMUXLOG" in *"-l -- hello"*) false;; *) true;; esac; } && ok "pane root PID changed (session replaced): nothing typed, rc1" || bad "pid-change guard (rc=$rc log=$TMUXLOG)"
PANE_PID0=123 PANE_PID_NOW=123 VERDICTS="yy"; TMUXLOG=""; send_line "hello" "t"; rc=$?
{ [ $rc -eq 0 ] && case "$TMUXLOG" in *Enter*) true;; *) false;; esac; } && ok "pane root PID unchanged: send proceeds" || bad "pid-match send (rc=$rc log=$TMUXLOG)"
unset PANE_PID0 PANE_PID_NOW

echo "== C) adoption + boundary grep semantics =="
B_RE='"subtype"[[:space:]]*:[[:space:]]*"compact_boundary"'
[ "$(grep -c '^B_RE=' "$SRC")" -eq 1 ] && ok "boundary regex defined ONCE as B_RE" || bad "B_RE definition count != 1 (drift)"
[ "$(grep -c '"\$B_RE"' "$SRC")" -ge 3 ] && ok "adoption + phase-3 + reset-wait share \$B_RE (>=3 sites)" || bad "\$B_RE usage sites < 3"
TF=$(mktemp)
printf '%s\n' '{"type":"user","x":1}' > "$TF"
size_sched=$(wc -c < "$TF" | tr -dc '0-9')
tail -c +$(( size_sched + 1 )) "$TF" | grep -Eq "$B_RE" && bad "no new bytes adopted" || ok "no new bytes: no adoption"
printf '%s\n' '{"type":"system","subtype":"compact_boundary"}' >> "$TF"
tail -c +$(( size_sched + 1 )) "$TF" | grep -Eq "$B_RE" && ok "external boundary since baseline: adopts" || bad "boundary missed"
printf '%s\n' '{"type":"user","x":1}' > "$TF"; size_sched=$(wc -c < "$TF" | tr -dc '0-9')
printf '%s\n' 'result mentioning \"subtype\":\"compact_boundary\" inside a string' >> "$TF"
tail -c +$(( size_sched + 1 )) "$TF" | grep -Eq "$B_RE" && bad "escaped mention adopted" || ok "escaped mention rejected"
rm -f "$TF"

# REGRESSION (2026-07-08): a "size_before == size_sched => session dead/replaced"
# abort disabled self-compaction entirely (6/6 real attempts aborted). Phase 1
# waits for QUIESCENCE and the model calls the script as the last turn action,
# so an unchanged size at turn-end is the NORMAL case and MUST proceed to
# /compact. Replicate the exact post-Phase-1 branch (minus the removed abort).
decide_branch(){ # size_sched filesize transcript -> ABORT|ADOPT|COMPACT
  local ss="$1" sb="$2" tf="$3"
  [ -z "$sb" ] && { echo ABORT; return; }
  if [ "$sb" -ge "$ss" ] && tail -c +$(( ss + 1 )) "$tf" 2>/dev/null | grep -Eq "$B_RE"; then echo ADOPT; else echo COMPACT; fi
}
TF2=$(mktemp); printf '%s\n' '{"type":"assistant","x":1}' > "$TF2"; sz=$(wc -c < "$TF2" | tr -dc '0-9')
[ "$(decide_branch "$sz" "$sz" "$TF2")" = "COMPACT" ] && ok "equal size (quiescent at schedule) -> /compact, NOT frozen-abort" || bad "equal-size case regressed to abort/adopt"
printf '%s\n' '{"type":"system","subtype":"compact_boundary"}' >> "$TF2"; sz2=$(wc -c < "$TF2" | tr -dc '0-9')
[ "$(decide_branch "$sz" "$sz2" "$TF2")" = "ADOPT" ] && ok "grown + new boundary -> adopt" || bad "adoption regressed"
[ "$(decide_branch "$sz" "" "$TF2")" = "ABORT" ] && ok "empty size read -> abort (read-failure guard kept)" || bad "size read-failure guard lost"
rm -f "$TF2"

echo "== D) CONTINUATION sanitize chain (replicated from top-level lines) =="
grep -qF 'CONTINUATION="Continue: $CONTINUATION"' "$SRC" || bad "slash-guard line missing from script (drift)"
sanitize(){ local C; C=$(printf '%s' "$1" | tr '\n\r' '  '); C="${C#"${C%%[![:space:]]*}"}"
  [ -z "$C" ] && { echo REFUSE; return; }; case "$C" in /*|!*|'#'*) C="Continue: $C";; esac; echo "RESULT|$C"; }
[ "$(sanitize '   /clear')" = "RESULT|Continue: /clear" ] && ok "padded /clear neutralized" || bad "padded /clear"
[ "$(sanitize '     ')" = "REFUSE" ] && ok "all-whitespace refused" || bad "all-ws"
[ "$(sanitize '!ls')" = "RESULT|Continue: !ls" ] && ok "bang-prefix neutralized" || bad "bang"
[ "$(sanitize 'resume work now')" = "RESULT|resume work now" ] && ok "normal text passes" || bad "normal"

echo "== E) lock pid-liveness: live pid refuses, dead pid reclaims =="
decide(){ local L; L=$(mktemp -d); printf '%s' "$1" > "$L/pid"
  local alive=0 opid; opid=$(cat "$L/pid" 2>/dev/null || true)
  [ -n "$opid" ] && kill -0 "$opid" 2>/dev/null && alive=1
  rm -rf "$L"; [ "$alive" -eq 1 ] && echo REFUSE || echo RECLAIM; }
[ "$(decide $$)" = "REFUSE" ] && ok "live pid: second watcher refused" || bad "live pid"
[ "$(decide 999999)" = "RECLAIM" ] && ok "dead pid: stale lock reclaimed" || bad "dead pid"

echo "== F) structural drift guards =="
[ "$(grep -c 'notify_fail "' "$SRC")" -ge 7 ] && ok "notify_fail wired to all abort paths (>=7)" || bad "notify_fail call sites missing"
grep -q 'size_sched' "$SRC" && ok "adoption baseline present" || bad "size_sched missing"
grep -qF -- '-l --' "$SRC" && ok "literal send uses -l --" || bad "-l -- missing"
grep -q 'compacting' "$SRC" && ok "compacting busy-state present" || bad "compacting regex missing"
grep -qF 'size_before=$(wc -c < "$TRANSCRIPT" 2>/dev/null | tr -dc '\''0-9'\'')' "$SRC" && ok "size_before read is failure-guarded" || bad "size_before guard missing"
grep -q 'ABORT: transcript frozen' "$SRC" && bad "frozen-equality false-positive abort STILL PRESENT (regression)" || ok "frozen-equality false-positive abort removed"
grep -q 'sleep 6' "$SRC" && ok "phase-4 pause outlasts the rehydrator hook budget" || bad "phase-4 pause regressed"

echo "== G) parse_reset_epoch: usage-limit banner time parsing =="
# Relative-time fixtures wrap the day near midnight; pick a banner TZ whose
# local clock sits in [01:00, 20:59] (NY and Tokyo are 13-14h apart — both
# can never be near midnight at once), so the fixtures stay deterministic.
TZP="America/New_York"
h=$(TZ="$TZP" date +%H | sed 's/^0//'); { [ "$h" -ge 21 ] || [ "$h" -eq 0 ] || [ -z "$h" ]; } && TZP="Asia/Tokyo"
lc_time(){ TZ="$TZP" date "$1" '+%l:%M%p' | tr -d ' ' | tr 'APM' 'apm'; }
if [ -z "$(extract_fn parse_reset_epoch)" ]; then
  bad "cannot extract parse_reset_epoch() from $SRC"
else
  LIMIT_WAIT_MAX=21600; LIMIT_GRACE=180
  eval "$(extract_fn parse_reset_epoch)"
  now=$(date +%s)
  ep=$(parse_reset_epoch "You've hit your session limit · resets $(lc_time -v+2H) ($TZP)") \
    && [ $(( ep - now )) -gt 6900 ] && [ $(( ep - now )) -lt 7500 ] \
    && ok "future banner (+2h) parses to ~now+2h" || bad "future banner parse (got ep=${ep:-none})"
  ep=$(parse_reset_epoch "You've hit your session limit · resets $(lc_time -v-5M) ($TZP)") \
    && [ "$ep" -le "$now" ] && ok "just-elapsed reset kept in the past (retry-now signal)" || bad "recent-past reset (got ep=${ep:-none})"
  parse_reset_epoch "You've hit your session limit · resets $(lc_time -v-3H) ($TZP)" >/dev/null \
    && bad "3h-stale banner accepted (wrong-day parse must be rejected)" || ok "stale banner rejected (> LIMIT_WAIT_MAX ahead)"
  parse_reset_epoch "You've reached your Fable 5 limit. Run /usage-credits to continue or switch models with /model." >/dev/null \
    && bad "time-less model-limit banner accepted" || ok "time-less banner rejected"
  nomin=$(TZ="$TZP" date -v+3H '+%l%p' | tr -d ' ' | tr 'APM' 'apm')
  ep=$(parse_reset_epoch "resets $nomin ($TZP)") \
    && [ $(( ep - now )) -gt 7000 ] && [ $(( ep - now )) -lt 11100 ] \
    && ok "minute-less time (9pm form) normalized and parsed" || bad "minute-less time (got ep=${ep:-none})"
  # Midnight fold: a reset that elapsed minutes ago but BEFORE midnight parses
  # ~24h ahead (day field is always today) and must fold back to retry-now.
  # Needs a zone whose wall clock is 00:00-00:03 right now; half-offset zones
  # widen coverage. When none qualifies, the branch is covered by inspection.
  FTZ=""
  for z in $(seq -f 'Etc/GMT+%g' 0 12) $(seq -f 'Etc/GMT-%g' 1 14) Asia/Kathmandu Asia/Kolkata Australia/Eucla Asia/Yangon Pacific/Marquesas Pacific/Chatham; do
    [ "$(TZ="$z" date +%H)" = "00" ] && [ "$(TZ="$z" date +%M)" -lt 4 ] && { FTZ="$z"; break; }
  done
  if [ -n "$FTZ" ]; then
    t=$(TZ="$FTZ" date -v-5M '+%l:%M%p' | tr -d ' ' | tr 'APM' 'apm')
    ep=$(parse_reset_epoch "resets $t ($FTZ)") && [ "$ep" -le "$(date +%s)" ] \
      && ok "just-elapsed pre-midnight reset folds back (retry-now across midnight)" || bad "midnight fold (got ep=${ep:-none})"
  else
    ok "midnight fold: no zone at 00:00-00:03 right now — skipped (fold arithmetic reviewed)"
  fi
fi

echo "== H) pane_limit_paused: limit banner means NOT idle =="
if [ -z "$(extract_fn pane_limit_paused)" ]; then
  bad "cannot extract pane_limit_paused() from $SRC"
else
  eval "$(extract_fn pane_limit_paused)"
  PANE_CONTENT="  ⎿  You've hit your session limit · resets $(lc_time -v+2H) ($TZP)"
  pane_limit_paused && [ "${LIMIT_RESET_EPOCH:-0}" -gt "$(date +%s)" ] \
    && ok "future-reset banner detected as limit-paused" || bad "future-reset banner missed"
  PANE_CONTENT="  ⎿  You've hit your session limit · resets $(lc_time -v-3H) ($TZP)"
  pane_limit_paused && bad "stale banner (reset long past) treated as paused" || ok "stale banner not paused"
  PANE_CONTENT="⏺ You've reached your Fable 5 limit. Run /usage-credits to continue."
  pane_limit_paused && bad "time-less banner treated as paused (would wait forever)" || ok "time-less banner not paused"
  [ "$LIMIT_BANNER_KIND" = "timeless" ] && ok "time-less banner flagged 'timeless' (abort signal for the caller)" || bad "timeless kind not set (got '${LIMIT_BANNER_KIND:-}')"
  PANE_CONTENT="> "
  pane_limit_paused && bad "idle prompt treated as limit-paused" || ok "idle prompt not paused"
  [ -z "$LIMIT_BANNER_KIND" ] && ok "no banner leaves kind empty" || bad "kind not reset on no-banner"
  PANE_CONTENT="[2026-07-09T20:11:02] compaction FAILED: Error during compaction: You've hit your session limit · resets $(lc_time -v+2H) ($TZP)"
  pane_limit_paused && bad "prose/log line QUOTING a banner wedged the watcher (anchoring lost)" || ok "quoted banner in prose/log tail not paused (glyph-anchored)"
fi

echo "== H2) wait_turn_end: the shared send gate =="
if [ -z "$(extract_fn wait_turn_end)" ]; then
  bad "cannot extract wait_turn_end() from $SRC"
else
  eval "$(extract_fn wait_turn_end)"
  LOCK=$(mktemp -d); TRANSCRIPT=$(mktemp)
  touch -t "$(date -v-10M +%Y%m%d%H%M)" "$TRANSCRIPT"
  IDLE_S=1; IDLE_TIMEOUT=900; LIMIT_GRACE=180
  now0=$(date +%s); deadline=$(( now0 + 60 )); limit_cap=$(( now0 + 21600 ))
  PANE_CONTENT="> "
  wait_turn_end; [ $? -eq 0 ] && ok "quiescent idle prompt -> rc0 (safe to send)" || bad "idle prompt gate"
  PANE_CONTENT="⏺ You've reached your Fable 5 limit. Run /usage-credits to continue."
  wait_turn_end; [ $? -eq 3 ] && ok "timeless limit banner -> rc3 (abort, never send)" || bad "timeless banner gate"
  PANE_CONTENT="esc to interrupt"; deadline=$(( $(date +%s) - 1 ))
  wait_turn_end; [ $? -eq 1 ] && ok "busy past deadline -> rc1 (turn never ended)" || bad "deadline gate"
  PANE_CONTENT="> "; deadline=$(( $(date +%s) - 5 ))
  wait_turn_end; [ $? -eq 0 ] && ok "idle AFTER expired deadline -> rc0 (laptop-sleep salvage pass)" || bad "salvage pass lost"
  rm -rf "$LOCK" "$TRANSCRIPT"
fi

echo "== I) E_RE: failed-compaction entry detection =="
E_RE_VAL=$(sed -n "s/^E_RE='\(.*\)'\$/\1/p" "$SRC")
if [ -z "$E_RE_VAL" ]; then
  bad "E_RE not defined in $SRC"
else
  REAL_ERR='{"type":"system","subtype":"local_command","content":"<local-command-stdout>Error during compaction: You'\''ve hit your session limit · resets 9:50pm (America/New_York)</local-command-stdout>","level":"info"}'
  printf '%s\n' "$REAL_ERR" | grep -Eq "$E_RE_VAL" && ok "real local_command error entry matches E_RE" || bad "real error entry missed"
  NOTENOUGH='{"type":"system","subtype":"local_command","content":"<local-command-stdout>Not enough messages to compact.</local-command-stdout>","level":"info"}'
  printf '%s\n' "$NOTENOUGH" | grep -Eq "$E_RE_VAL" && ok "'Not enough messages' pre-flight refusal matches E_RE (live-caught 2026-07-09)" || bad "Not-enough-messages refusal missed"
  SUCCESS_OUT='{"type":"system","subtype":"local_command","content":"<local-command-stdout>Compacted (ctrl+o to see full summary)</local-command-stdout>","level":"info"}'
  printf '%s\n' "$SUCCESS_OUT" | grep -Eq "$E_RE_VAL" && bad "SUCCESS output matched E_RE (would abort a successful compaction)" || ok "success output not matched by E_RE"
  printf '{"type":"user","content":"quoting \\"subtype\\":\\"local_command\\" plus Error during compaction prose"}\n' \
    | grep -Eq "$E_RE_VAL" && bad "escaped mention matched E_RE" || ok "escaped mention rejected by E_RE"
  printf '%s\n' '{"type":"system","subtype":"compact_boundary"}' | grep -Eq "$E_RE_VAL" && bad "boundary entry matched E_RE" || ok "boundary entry not matched by E_RE"
fi

echo "== I2) Q_RE: queued-send (enqueue) detection =="
# 2026-07-17 (live-caught): a /compact typed into a mid-turn pane doesn't
# execute — the TUI logs {"type":"queue-operation","operation":"enqueue",
# "content":"/compact …"} and the message sits in queued messages until the
# REAL turn end (a Stop blocked by /goal does NOT flush it). The watcher must
# recognize that entry: it means "queued, not lost" — hold for the turn end
# instead of timing out at COMPACT_TIMEOUT and orphaning an armed /compact.
Q1=$(sed -n "s/^Q_RE1='\(.*\)'\$/\1/p" "$SRC"); Q2=$(sed -n "s/^Q_RE2='\(.*\)'\$/\1/p" "$SRC")
if [ -z "$Q1" ] || [ -z "$Q2" ]; then
  bad "Q_RE1/Q_RE2 not defined in $SRC"
else
  REAL_ENQ='{"type":"queue-operation","operation":"enqueue","timestamp":"2026-07-17T07:35:36.147Z","sessionId":"019f4200-0000-4000-8000-0000000000e1","content":"/compact PR review gate -> test run -> merge -> version bump -> release"}'
  printf '%s\n' "$REAL_ENQ" | grep -E "$Q1" | grep -Eq "$Q2" && ok "real /compact enqueue entry detected" || bad "real enqueue entry missed"
  TASK_ENQ='{"type":"queue-operation","operation":"enqueue","timestamp":"2026-07-17T06:41:07.483Z","sessionId":"019f4200-0000-4000-8000-0000000000e1","content":"<task-notification>Agent finished</task-notification>"}'
  printf '%s\n' "$TASK_ENQ" | grep -E "$Q1" | grep -Eq "$Q2" && bad "task-notification enqueue misread as our /compact" || ok "task-notification enqueue ignored"
  DEQ='{"type":"queue-operation","operation":"dequeue","content":"/compact x"}'
  printf '%s\n' "$DEQ" | grep -E "$Q1" | grep -Eq "$Q2" && bad "non-enqueue queue op matched" || ok "non-enqueue queue op ignored"
  QUOTED='{"type":"user","content":"result quoting \"type\":\"queue-operation\" and \"operation\":\"enqueue\" and \"content\":\"/compact x\" inside a string"}'
  printf '%s\n' "$QUOTED" | grep -E "$Q1" | grep -Eq "$Q2" && bad "escaped mention matched Q_REs" || ok "escaped mention rejected"
fi

echo "== J) clear_watermark_state: failed compaction re-arms the nudge pipeline =="
if [ -z "$(extract_fn clear_watermark_state)" ]; then
  bad "cannot extract clear_watermark_state() from $SRC"
else
  eval "$(extract_fn clear_watermark_state)"
  WATERMARK_STATE_ROOT=$(mktemp -d)
  TRANSCRIPT="/tmp/sc-test-$$.jsonl"
  wkey=$(printf '%s' "$TRANSCRIPT" | shasum -a 1 | cut -c1-16)
  mkdir -p "$WATERMARK_STATE_ROOT/$wkey"
  touch "$WATERMARK_STATE_ROOT/$wkey/t1" "$WATERMARK_STATE_ROOT/$wkey/t2" "$WATERMARK_STATE_ROOT/$wkey/t3" "$WATERMARK_STATE_ROOT/$wkey/compacted"
  printf '%s' "/x/LEDGER.md" > "$WATERMARK_STATE_ROOT/$wkey/ledger_path"
  clear_watermark_state
  { [ ! -f "$WATERMARK_STATE_ROOT/$wkey/t1" ] && [ ! -f "$WATERMARK_STATE_ROOT/$wkey/t3" ] && [ ! -f "$WATERMARK_STATE_ROOT/$wkey/compacted" ]; } \
    && ok "sentinels + compacted stamp cleared" || bad "watermark state not cleared"
  [ -f "$WATERMARK_STATE_ROOT/$wkey/ledger_path" ] && ok "ledger_path pin survives the clear" || bad "ledger_path wrongly removed"
  rm -rf "$WATERMARK_STATE_ROOT"; unset WATERMARK_STATE_ROOT
fi

echo "== K) limit-handling structural drift guards =="
grep -q '^E_RE=' "$SRC" && [ "$(grep -c '^E_RE=' "$SRC")" -eq 1 ] && ok "E_RE defined exactly once" || bad "E_RE definition drift"
grep -q 'LIMIT_RETRIES=' "$SRC" && ok "limit retry budget present" || bad "LIMIT_RETRIES missing"
grep -q 'usage-limit blocked' "$SRC" && ok "retry-after-reset path present" || bad "retry-after-reset log line missing"
grep -q '^wait_for_reset() {' "$SRC" && ok "wait_for_reset helper present" || bad "wait_for_reset missing"
[ "$(grep -c 'clear_watermark_state$\|clear_watermark_state;' "$SRC")" -ge 4 ] && ok "watermark clear wired to >=4 abort paths" || bad "clear_watermark_state call sites < 4"
grep -q 'pane_limit_paused' "$SRC" && [ "$(grep -c 'pane_limit_paused' "$SRC")" -ge 2 ] && ok "phase-1 consults pane_limit_paused" || bad "pane_limit_paused not consulted"
[ "$(grep -Ec '^[[:space:]]+wait_turn_end( |$)' "$SRC")" -ge 2 ] && ok "wait_turn_end gates BOTH phase-1 and the post-reset retry" || bad "retry send not re-gated by wait_turn_end"
grep -q 'PANE_PID0=' "$SRC" && ok "pane root-PID identity anchor captured at schedule" || bad "PANE_PID0 capture missing"

echo "== L) queued-send handling structural drift guards (2026-07-17) =="
grep -q '^QUEUED_TIMEOUT=' "$SRC" && ok "QUEUED_TIMEOUT knob present" || bad "QUEUED_TIMEOUT missing"
grep -qi 'press up to edit queued messages' "$SRC" && ok "queued-input busy tell present in pane_busy" || bad "queued-messages busy tell missing"
grep -qF '\(esc to [a-z]' "$SRC" && ok "per-state esc-hint variant covered by pane_busy" || bad "esc-variant pattern missing"
grep -qF '[0-9]+[hms]' "$SRC" && ok "timer status-line busy shape present in pane_busy" || bad "timer-shape pattern missing"
grep -q 'ENQUEUED mid-turn' "$SRC" && ok "post-send enqueue detection wired into the boundary wait" || bad "enqueue detection missing"
grep -q 'flush Enter' "$SRC" && ok "swallowed-Enter flush recovery present" || bad "flush recovery missing"
grep -q 'continuation SKIPPED' "$SRC" && ok "phase-4 mid-turn skip gate present" || bad "phase-4 busy gate missing"
grep -q '^notify_note() {' "$SRC" && ok "notify_note visibility helper present" || bad "notify_note missing"

echo "---- $P passed, $F failed"
exit $F
