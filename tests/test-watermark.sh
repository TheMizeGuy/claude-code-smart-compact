#!/bin/bash
# Standalone tests for context-watermark.py — synthetic transcripts + events.
# v2: tiers are relative to the EFFECTIVE ceiling (median of recent observed
# auto-compact occupancies from the flight log), not the nominal window.
# COMPACT_EVENTS_LOG redirects the flight log so tests never pollute the real
# one (the estimator LEARNS from that log — pollution literally re-tunes it).
set -u
HOOK="$HOME/.claude/hooks/context-watermark.py"
TDIR="$(mktemp -d)"
export CLAUDE_CODE_AUTO_COMPACT_WINDOW=650000
export WATERMARK_FORCE=1
export COMPACT_EVENTS_LOG="$TDIR/events.log"
PASS=0; FAIL=0

# Fixture flight log: last 5 genuine autos 531..535K (median 533000). Noise
# that the estimator MUST ignore: agent compactions, manual compacts,
# rehydrate-outcome lines, non-JSON garbage, and a 6th-oldest auto (700K)
# that falls outside the last-5 window.
python3 - "$COMPACT_EVENTS_LOG" <<'EOF'
import json, sys
lines = [
    {"ts": "x", "session_id": "s3", "trigger": "auto", "occupancy": 700000},
    {"ts": "x", "session_id": "s0", "trigger": "auto", "occupancy": 999999, "agent": True},
    {"ts": "x", "session_id": "s1", "trigger": "manual", "occupancy": 100000},
    {"ts": "x", "session_id": "s2", "event": "rehydrate", "outcome": "model"},
    {"ts": "x", "session_id": "s4", "trigger": "auto", "occupancy": 531000},
    {"ts": "x", "session_id": "s5", "trigger": "auto", "occupancy": 532000},
    {"ts": "x", "session_id": "s6", "trigger": "auto", "occupancy": 533000},
    {"ts": "x", "session_id": "s7", "trigger": "auto", "occupancy": 534000},
    {"ts": "x", "session_id": "s8", "trigger": "auto", "occupancy": 535000},
]
with open(sys.argv[1], "w") as f:
    for l in lines:
        f.write(json.dumps(l) + "\n")
    f.write("garbage not json\n")
EOF
# Ceiling C = 533000. Tier trip points: T1 75% = 399750, T2 87% = 463710,
# T3 94% = 501020. Occupancies used below sit just above each.

mk_transcript() { # path total_tokens
  python3 - "$1" "$2" <<'EOF'
import json, sys
path, total = sys.argv[1], int(sys.argv[2])
lines = [
    {"type": "user", "message": {"content": "hi"}},
    {"type": "assistant", "message": {"usage": {"input_tokens": 1000, "output_tokens": 200, "cache_read_input_tokens": 500, "cache_creation_input_tokens": 100}}},
    {"type": "assistant", "message": {"usage": {"input_tokens": 2000, "output_tokens": 400, "cache_read_input_tokens": total - 2900, "cache_creation_input_tokens": 500}}},
]
with open(path, "w") as f:
    for l in lines:
        f.write(json.dumps(l) + "\n")
EOF
}

run_hook() { # transcript event_name -> stdout
  printf '{"hook_event_name":"%s","session_id":"test-sess","cwd":"/tmp/example-project","transcript_path":"%s"}' "$2" "$1" | python3 "$HOOK"
}

check() { # desc expectation(EMPTY|substr) output
  local desc="$1" want="$2" out="$3"
  if [ "$want" = "EMPTY" ]; then
    if [ -z "$out" ]; then echo "PASS: $desc"; PASS=$((PASS+1)); else echo "FAIL: $desc — expected empty, got: ${out:0:120}"; FAIL=$((FAIL+1)); fi
  else
    if printf '%s' "$out" | grep -qF "$want"; then echo "PASS: $desc"; PASS=$((PASS+1)); else echo "FAIL: $desc — missing '$want' in: ${out:0:160}"; FAIL=$((FAIL+1)); fi
  fi
}

T1="$TDIR/main.jsonl"

mk_transcript "$T1" 215000   # 40% of C
check "40% of ceiling silent" EMPTY "$(run_hook "$T1" PostToolUse)"

mk_transcript "$T1" 406000   # 76% of C
OUT="$(run_hook "$T1" PostToolUse)"
check "76% of ceiling fires T1" "WATERMARK 75%" "$OUT"
check "nudge states the learned ceiling" "expected near ~533,000" "$OUT"
check "nudge states the nominal window" "nominal window 650,000" "$OUT"
check "76% again silent (one-shot)" EMPTY "$(run_hook "$T1" PostToolUse)"

mk_transcript "$T1" 470000   # 88% of C — BELOW the old 650K-based T2 (565K):
OUT="$(run_hook "$T1" PostToolUse)"   # proves the ladder is alive again
check "88% of ceiling fires T2" "CHECKPOINT NOW" "$OUT"
check "T2 carries ledger path" "/tmp/example-project/.claude/blackboard/test-sess/LEDGER.md" "$OUT"
check "T2 carries template" "SESSION LEDGER" "$OUT"
check "T2 valid JSON + event name" "PostToolUse" "$(printf '%s' "$OUT" | python3 -m json.tool 2>/dev/null | grep hookEventName)"

mk_transcript "$T1" 507000   # 95% of C
check "95% of ceiling fires T3" "WATERMARK 94%" "$(run_hook "$T1" PostToolUse)"

mk_transcript "$T1" 160000   # 30% -> re-arm, silent
check "30% silent + re-arm" EMPTY "$(run_hook "$T1" PostToolUse)"
mk_transcript "$T1" 406000   # 76% again -> T1 refires
check "T1 refires after re-arm" "WATERMARK 75%" "$(run_hook "$T1" PostToolUse)"

# Fresh transcript jumping straight to 95%: only T3 fires, then 88% silent.
T2F="$TDIR/jump.jsonl"
mk_transcript "$T2F" 507000
check "jump to 95% fires T3 only" "WATERMARK 94%" "$(run_hook "$T2F" PostToolUse)"
mk_transcript "$T2F" 470000
check "88% after jump silent (lower tiers marked)" EMPTY "$(run_hook "$T2F" PostToolUse)"

# UserPromptSubmit echoes its own event name.
T3F="$TDIR/ups.jsonl"
mk_transcript "$T3F" 406000
check "UserPromptSubmit event name echoed" '"hookEventName": "UserPromptSubmit"' "$(run_hook "$T3F" UserPromptSubmit | python3 -m json.tool)"

# Rate limit: without FORCE, second call within 10s is silent even on new threshold.
T4F="$TDIR/rate.jsonl"
mk_transcript "$T4F" 215000
WATERMARK_FORCE=0 run_hook "$T4F" PostToolUse >/dev/null   # stamps last_check
mk_transcript "$T4F" 406000
check "rate-limited call silent" EMPTY "$(WATERMARK_FORCE=0 run_hook "$T4F" PostToolUse)"

# Sidechain entries must be ignored: main at 76%, trailing sidechain tiny usage.
T5F="$TDIR/side.jsonl"
mk_transcript "$T5F" 406000
python3 - "$T5F" <<'EOF'
import json, sys
with open(sys.argv[1], "a") as f:
    f.write(json.dumps({"type": "assistant", "isSidechain": True, "message": {"usage": {"input_tokens": 3000, "output_tokens": 100, "cache_read_input_tokens": 0, "cache_creation_input_tokens": 0}}}) + "\n")
EOF
check "sidechain tail ignored, T1 fires from main usage" "WATERMARK 75%" "$(run_hook "$T5F" PostToolUse)"

# Subagent events (agent_id/agent_type present, parent transcript+session) must
# be ignored entirely — and must NOT consume the parent's one-shot sentinel.
T6F="$TDIR/agent.jsonl"
mk_transcript "$T6F" 406000
AOUT=$(printf '{"hook_event_name":"PostToolUse","session_id":"test-sess","cwd":"/tmp/example-project","transcript_path":"%s","agent_id":"abc123","agent_type":"Explore"}' "$T6F" | python3 "$HOOK")
check "agent event silent above threshold" EMPTY "$AOUT"
check "main event still fires after agent event (sentinel not consumed)" "WATERMARK 75%" "$(run_hook "$T6F" PostToolUse)"

# Ledger path pinned at fire time.
KEY=$(python3 -c "import hashlib,sys;print(hashlib.sha1('$T6F'.encode()).hexdigest()[:16])")
check "ledger_path pinned in state" "/tmp/example-project/.claude/blackboard/test-sess/LEDGER.md" "$(cat /tmp/claude-context-watermark/$KEY/ledger_path)"

# Post-compact window: pre-compact usage followed by a compact_boundary system
# entry must read as UNKNOWN occupancy (silent), not spuriously re-fire T3.
T7F="$TDIR/boundary.jsonl"
mk_transcript "$T7F" 507000   # 95% pre-compact usage
python3 - "$T7F" <<'EOF'
import json, sys
with open(sys.argv[1], "a") as f:
    f.write(json.dumps({"type": "system", "subtype": "compact_boundary"}) + "\n")
    f.write(json.dumps({"type": "user", "message": {"content": "post-compact tool result"}}) + "\n")
EOF
check "compact boundary suppresses stale occupancy" EMPTY "$(run_hook "$T7F" PostToolUse)"
python3 - "$T7F" <<'EOF'
import json, sys
with open(sys.argv[1], "a") as f:
    f.write(json.dumps({"type": "assistant", "message": {"usage": {"input_tokens": 1000, "output_tokens": 100, "cache_read_input_tokens": 150000, "cache_creation_input_tokens": 500}}}) + "\n")
EOF
check "fresh post-compact assistant usage resumes (low, silent)" EMPTY "$(run_hook "$T7F" PostToolUse)"
mk_transcript "$T7F" 406000   # rebuild without boundary at 76%
check "post-compact cycle re-fires at 76%" "WATERMARK 75%" "$(run_hook "$T7F" PostToolUse)"

# compacted stamp, aborted-compact shape (stamp + FIRED sentinels): a stale
# high reading stays suppressed until refill or the 30-min stamp expiry.
T8F="$TDIR/stamp.jsonl"
mk_transcript "$T8F" 470000   # 88%
K8=$(python3 -c "import hashlib;print(hashlib.sha1('$T8F'.encode()).hexdigest()[:16])")
mkdir -p "/tmp/claude-context-watermark/$K8"
touch "/tmp/claude-context-watermark/$K8/compacted" "/tmp/claude-context-watermark/$K8/t1" "/tmp/claude-context-watermark/$K8/t2" "/tmp/claude-context-watermark/$K8/t3"
check "aborted-compact shape: stamp + fired sentinels + high ratio suppressed" EMPTY "$(run_hook "$T8F" PostToolUse)"
mk_transcript "$T8F" 160000   # 30% -> refill observed, stamp+sentinels cleared
check "stamp + low ratio silent (clears)" EMPTY "$(run_hook "$T8F" PostToolUse)"
[ ! -f "/tmp/claude-context-watermark/$K8/compacted" ] && echo "PASS: stamp cleared on refill" && PASS=$((PASS+1)) || { echo "FAIL: stamp not cleared"; FAIL=$((FAIL+1)); }
mk_transcript "$T8F" 406000
check "T1 fires after stamped cycle re-arms" "WATERMARK 75%" "$(run_hook "$T8F" PostToolUse)"

# Post-REAL-compaction shape (stamp fresh, sentinels CLEARED by the
# rehydrator): a genuinely-high first reading must fire immediately — the old
# 'elif stamp_fresh: return' muted every tier for the stamp's 30-min life,
# exactly the pre-auto-compact window the nudges exist for.
T8H="$TDIR/stamp-postcompact.jsonl"
mk_transcript "$T8H" 470000   # 88% on the FIRST post-compact reading
K8H=$(python3 -c "import hashlib;print(hashlib.sha1('$T8H'.encode()).hexdigest()[:16])")
mkdir -p "/tmp/claude-context-watermark/$K8H"; touch "/tmp/claude-context-watermark/$K8H/compacted"
check "stamp + NO sentinels + 88%: fires T2 immediately" "CHECKPOINT NOW" "$(run_hook "$T8H" PostToolUse)"
[ ! -f "/tmp/claude-context-watermark/$K8H/compacted" ] && echo "PASS: stamp dropped when nothing was suppressible" && PASS=$((PASS+1)) || { echo "FAIL: stamp survived no-sentinel re-arm"; FAIL=$((FAIL+1)); }

# Widened re-arm: after a CONFIRMED compaction (stamp), any sub-T1 reading
# re-arms — a heavy post-compact context can reopen above 55% of the ceiling.
T8G="$TDIR/stamp-heavy.jsonl"
mk_transcript "$T8G" 320000   # 60% of C: above REARM_BELOW, below T1
K8G=$(python3 -c "import hashlib;print(hashlib.sha1('$T8G'.encode()).hexdigest()[:16])")
mkdir -p "/tmp/claude-context-watermark/$K8G"
touch "/tmp/claude-context-watermark/$K8G/compacted" "/tmp/claude-context-watermark/$K8G/t1" "/tmp/claude-context-watermark/$K8G/t2" "/tmp/claude-context-watermark/$K8G/t3"
check "stamp + 60% reading silent" EMPTY "$(run_hook "$T8G" PostToolUse)"
[ ! -f "/tmp/claude-context-watermark/$K8G/t3" ] && echo "PASS: stamp + sub-T1 reading cleared sentinels" && PASS=$((PASS+1)) || { echo "FAIL: sentinels survived sub-T1 re-arm"; FAIL=$((FAIL+1)); }
mk_transcript "$T8G" 406000
check "T1 fires after heavy-context re-arm" "WATERMARK 75%" "$(run_hook "$T8G" PostToolUse)"

# Over-ceiling band: the ceiling is an estimate — a mild overshoot (<=1.3x)
# clamps and still fires the highest tier; a wild ratio (>1.3x) is garbage.
T9F="$TDIR/over.jsonl"
mk_transcript "$T9F" 560000   # 105% of C
check "mild over-ceiling clamps and fires T3" "WATERMARK 94%" "$(run_hook "$T9F" PostToolUse)"
mk_transcript "$T9F" 470000
check "post-clamp lower reading silent (tiers marked)" EMPTY "$(run_hook "$T9F" PostToolUse)"
T9G="$TDIR/wild.jsonl"
mk_transcript "$T9G" 710000   # 133% of C
check "wild ratio (>1.3x ceiling) silent" EMPTY "$(run_hook "$T9G" PostToolUse)"

# Estimator fallback: <2 auto samples -> 85% of nominal window (552500).
# 406000 = 73.5% of fallback (silent) but 76% of the learned ceiling — the
# pair distinguishes fallback from learned mode.
FB1="$TDIR/fb1.jsonl"; mk_transcript "$FB1" 406000
check "missing events log: 406K silent (fallback ceiling)" EMPTY "$(COMPACT_EVENTS_LOG=$TDIR/absent.log run_hook "$FB1" PostToolUse)"
FB2="$TDIR/fb2.jsonl"; mk_transcript "$FB2" 420000   # 76% of 552500
check "missing events log: 420K fires T1 on fallback ceiling" "WATERMARK 75%" "$(COMPACT_EVENTS_LOG=$TDIR/absent.log run_hook "$FB2" PostToolUse)"
printf '%s\n' '{"ts":"x","session_id":"s","trigger":"auto","occupancy":533000}' > "$TDIR/single.log"
FB3="$TDIR/fb3.jsonl"; mk_transcript "$FB3" 406000
check "single-sample log still uses fallback (406K silent)" EMPTY "$(COMPACT_EVENTS_LOG=$TDIR/single.log run_hook "$FB3" PostToolUse)"
printf '%s\n%s\n' '{"ts":"x","session_id":"s","trigger":"auto","occupancy":520000}' '{"ts":"x","session_id":"s","trigger":"auto","occupancy":540000}' > "$TDIR/two.log"
FB4="$TDIR/fb4.jsonl"; mk_transcript "$FB4" 411000   # 76% of 540000, 74.4% of fallback
check "two-sample log engages estimator (411K fires T1)" "WATERMARK 75%" "$(COMPACT_EVENTS_LOG=$TDIR/two.log run_hook "$FB4" PostToolUse)"

# Degenerate window (typo/misconfig): the 1000-token ceiling floor keeps the
# hook silent-but-alive instead of ZeroDivision-dead for the whole session.
TW="$TDIR/tinywin.jsonl"
mk_transcript "$TW" 215000
check "window=1 typo: silent, no crash" EMPTY "$(CLAUDE_CODE_AUTO_COMPACT_WINDOW=1 run_hook "$TW" PostToolUse)"

# Malformed stdin never errors.
echo 'not json' | python3 "$HOOK"; check "malformed stdin exit 0" EMPTY "$([ $? -eq 0 ] || echo bad)"

# Perf: single forced call under 150ms (now includes the estimator read).
S=$(python3 -c 'import time; print(time.time())')
run_hook "$T1" PostToolUse >/dev/null
E=$(python3 -c 'import time; print(time.time())')
MS=$(python3 -c "print(int((${E}-${S})*1000))")
if [ "$MS" -lt 150 ]; then echo "PASS: perf ${MS}ms"; PASS=$((PASS+1)); else echo "FAIL: perf ${MS}ms >= 150ms"; FAIL=$((FAIL+1)); fi

echo "---- $PASS passed, $FAIL failed"
# Reap the /tmp watermark state dirs keyed by this run's synthetic transcripts
# (the hook's own 7-day GC would eventually get them; don't make it).
for tf in "$TDIR"/*.jsonl; do
  K=$(python3 -c "import hashlib,sys;print(hashlib.sha1(sys.argv[1].encode()).hexdigest()[:16])" "$tf")
  rm -rf "/tmp/claude-context-watermark/$K"
done
rm -rf "$TDIR"
exit $FAIL
