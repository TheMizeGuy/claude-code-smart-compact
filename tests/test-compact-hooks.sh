#!/bin/bash
# Consolidated tests for precompact-recorder.py + compact-rehydrate.py,
# including the subagent-guard and pinned-ledger-path regression cases,
# the auto-ledger extractor, and the rehydration lattice.
set -u
REC="$HOME/.claude/hooks/precompact-recorder.py"
REH="$HOME/.claude/hooks/compact-rehydrate.py"
TD=$(mktemp -d)
# NEVER the real log: the watermark's effective-ceiling estimator LEARNS from
# it — synthetic occupancies would re-tune production thresholds (this exact
# pollution shipped 60 bogus lines before 2026-07-08).
export COMPACT_EVENTS_LOG="$TD/events.log"
PASS=0; FAIL=0
ok()  { echo "PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

python3 -c "
import json
open('$TD/t.jsonl','w').write(json.dumps({'type':'assistant','message':{'usage':{'input_tokens':2000,'output_tokens':400,'cache_read_input_tokens':497100,'cache_creation_input_tokens':500}}})+'\n')"
mkdir -p "$TD/projA/.claude/blackboard/sess-1"
printf '# SESSION LEDGER\n## Goal\npinned-path test\n' > "$TD/projA/.claude/blackboard/sess-1/LEDGER.md"
KEY=$(python3 -c "import hashlib;print(hashlib.sha1('$TD/t.jsonl'.encode()).hexdigest()[:16])")
STATE="/tmp/claude-context-watermark/$KEY"
rm -rf "$STATE"; mkdir -p "$STATE"

EV_MAIN="{\"hook_event_name\":\"PreCompact\",\"trigger\":\"auto\",\"session_id\":\"sess-1\",\"cwd\":\"$TD/projA\",\"transcript_path\":\"$TD/t.jsonl\"}"
EV_AGENT="{\"hook_event_name\":\"PreCompact\",\"trigger\":\"auto\",\"session_id\":\"sess-1\",\"cwd\":\"$TD/projA\",\"transcript_path\":\"$TD/t.jsonl\",\"agent_id\":\"xyz\",\"agent_type\":\"Explore\"}"

# 1. Agent PreCompact: logged with agent flag, NO snapshot, NO re-arm stamp.
printf '%s' "$EV_AGENT" | python3 "$REC"
tail -1 "$COMPACT_EVENTS_LOG" | grep -q '"agent": true' && ok "agent compact logged with flag" || bad "agent log flag"
ls "$TD/projA/.claude/blackboard/sess-1/" | grep -q pre-compact && bad "agent event snapshotted parent ledger" || ok "no snapshot on agent event"
[ ! -f "$STATE/compacted" ] && ok "no re-arm stamp on agent event" || bad "agent event stamped compacted"

# 2. Main PreCompact: snapshot + stamp.
printf '%s' "$EV_MAIN" | python3 "$REC"
ls "$TD/projA/.claude/blackboard/sess-1/" | grep -q pre-compact && ok "main event snapshots ledger" || bad "main snapshot missing"
[ -f "$STATE/compacted" ] && ok "main event stamps compacted" || bad "main stamp missing"

# 3. Rehydrate on agent event: completely silent, sentinels untouched.
touch "$STATE/t1"
EV_REH_AGENT="{\"hook_event_name\":\"SessionStart\",\"source\":\"compact\",\"session_id\":\"sess-1\",\"cwd\":\"$TD/projA\",\"transcript_path\":\"$TD/t.jsonl\",\"agent_id\":\"xyz\"}"
OUT=$(printf '%s' "$EV_REH_AGENT" | python3 "$REH")
[ -z "$OUT" ] && ok "rehydrate silent on agent event" || bad "rehydrate output on agent event"
[ -f "$STATE/t1" ] && ok "sentinels untouched by agent event" || bad "agent event cleared sentinels"

# 4. Pinned ledger path: cwd drifted to projB, pin points at projA ledger.
printf '%s' "$TD/projA/.claude/blackboard/sess-1/LEDGER.md" > "$STATE/ledger_path"
mkdir -p "$TD/projB"
EV_REH_B="{\"hook_event_name\":\"SessionStart\",\"source\":\"compact\",\"session_id\":\"sess-1\",\"cwd\":\"$TD/projB\",\"transcript_path\":\"$TD/t.jsonl\"}"
OUT=$(printf '%s' "$EV_REH_B" | python3 "$REH")
printf '%s' "$OUT" | grep -q "pinned-path test" && ok "rehydrate follows pinned path across cwd drift" || bad "pinned path not used"
[ ! -f "$STATE/t1" ] && ok "rehydrate cleared tier sentinels" || bad "tier sentinels not cleared"
[ -f "$STATE/compacted" ] && ok "compacted stamp persists through rehydrate (suppress-until-refill)" || bad "compacted stamp wrongly cleared"
rm -f "$STATE/compacted"

# 5. Recorder prefers pinned path too (snapshot from projB cwd).
rm -f "$TD/projA/.claude/blackboard/sess-1/"LEDGER.pre-compact-*
EV_REC_B="{\"hook_event_name\":\"PreCompact\",\"trigger\":\"auto\",\"session_id\":\"sess-1\",\"cwd\":\"$TD/projB\",\"transcript_path\":\"$TD/t.jsonl\"}"
printf '%s' "$TD/projA/.claude/blackboard/sess-1/LEDGER.md" > "$STATE/ledger_path"
printf '%s' "$EV_REC_B" | python3 "$REC"
ls "$TD/projA/.claude/blackboard/sess-1/" | grep -q pre-compact && ok "recorder snapshots via pinned path" || bad "recorder missed pinned path"

# 6. Truncation marker on oversized ledger.
python3 -c "open('$TD/projA/.claude/blackboard/sess-1/LEDGER.md','w').write('# big\n'+'x'*20000)"
printf '%s' "$EV_REH_B" | python3 "$REH" | grep -q "TRUNCATED at " && ok "truncation marker" || bad "truncation marker missing"

# 7. Stale ledger (7h) -> recovery protocol.
printf '# ledger\n' > "$TD/projA/.claude/blackboard/sess-1/LEDGER.md"
touch -t $(date -v-7H +%Y%m%d%H%M) "$TD/projA/.claude/blackboard/sess-1/LEDGER.md"
printf '%s' "$EV_REH_B" | python3 "$REH" | grep -q "POST-COMPACT RECOVERY" && ok "stale ledger -> recovery" || bad "stale branch broken"

# 8. Resume semantics (crash-window only).
printf '# SESSION LEDGER\n## Goal\nresume-window test\n' > "$TD/projA/.claude/blackboard/sess-1/LEDGER.md"
printf '%s' "$TD/projA/.claude/blackboard/sess-1/LEDGER.md" > "$STATE/ledger_path"
EV_RESUME="{\"hook_event_name\":\"SessionStart\",\"source\":\"resume\",\"session_id\":\"sess-1\",\"cwd\":\"$TD/projA\",\"transcript_path\":\"$TD/t.jsonl\"}"
OUT=$(printf '%s' "$EV_RESUME" | python3 "$REH")
[ -z "$OUT" ] && ok "resume without boundary: silent" || bad "resume injected without boundary"
python3 -c "
import json
open('$TD/t.jsonl','a').write(json.dumps({'type':'system','subtype':'compact_boundary'})+'\n')"
OUT=$(printf '%s' "$EV_RESUME" | python3 "$REH")
printf '%s' "$OUT" | grep -q "resume-window test" && ok "resume with unrehydrated boundary: injects ledger" || bad "crash-window resume missed"
python3 -c "
import json
open('$TD/t.jsonl','a').write(json.dumps({'type':'user','message':{'content':'POST-COMPACT REHYDRATION marker present'}})+'\n')"
OUT=$(printf '%s' "$EV_RESUME" | python3 "$REH")
[ -z "$OUT" ] && ok "resume with persisted rehydration: silent" || bad "resume double-injected"
rm "$TD/projA/.claude/blackboard/sess-1/LEDGER.md"
python3 -c "
import json
open('$TD/t.jsonl','a').write(json.dumps({'type':'system','subtype':'compact_boundary'})+'\n')"
OUT=$(printf '%s' "$EV_RESUME" | python3 "$REH")
[ -z "$OUT" ] && ok "resume crash-window without ledger: silent (no RECOVERY)" || bad "resume emitted RECOVERY"

# 9. Age-tiered trust language.
printf '# SESSION LEDGER\ntrust-tier test\n' > "$TD/projA/.claude/blackboard/sess-1/LEDGER.md"
printf '%s' "$EV_REH_B" | python3 "$REH" | grep -q "trust the ledger" && ok "fresh ledger gets strong trust" || bad "strong trust missing"
touch -t $(date -v-3H +%Y%m%d%H%M) "$TD/projA/.claude/blackboard/sess-1/LEDGER.md"
printf '%s' "$EV_REH_B" | python3 "$REH" | grep -q "prefer the summary" && ok "3h ledger gets softened trust" || bad "softened trust missing"

# 10. Malformed stdin exits 0 silently.
echo garbage | python3 "$REC" && echo garbage | python3 "$REH" && ok "malformed stdin exit 0" || bad "malformed stdin"

# 11. Auto-ledger extraction: rich transcript, NO model ledger.
python3 - "$TD/rich.jsonl" <<'EOF'
import json, sys
entries = [
    {"type": "system", "subtype": "compact_boundary"},
    {"type": "user", "message": {"role": "user", "content": "<command-name>/goal</command-name>\n<command-message>goal</command-message>\n<command-args>make the smart compact genuinely good</command-args>"}},
    {"type": "user", "message": {"role": "user", "content": "Caveat: the messages below were generated while running local commands"}},
    {"type": "user", "message": {"role": "user", "content": "<system-reminder>wrapper noise</system-reminder>"}},
    {"type": "user", "isMeta": True, "message": {"role": "user", "content": "meta noise"}},
    {"type": "user", "message": {"role": "user", "content": "first genuine ask"}},
    {"type": "assistant", "message": {"content": [{"type": "text", "text": "working on it"}, {"type": "tool_use", "name": "Edit", "input": {"file_path": "/tmp/proj/alpha.py"}}]}},
    {"type": "assistant", "message": {"content": [{"type": "tool_use", "name": "mcp__plugin_serena_serena__replace_symbol_body", "input": {"relative_path": "src/beta.ts"}}]}},
    {"type": "assistant", "message": {"content": [{"type": "tool_use", "name": "Bash", "input": {"command": "git commit -m x"}}]}},
    {"type": "user", "message": {"role": "user", "content": [{"type": "tool_result", "is_error": True, "content": [{"type": "text", "text": "E: torpedo failure in test_gamma"}]}]}},
    {"type": "user", "message": {"role": "user", "content": "second genuine ask about gamma"}},
    {"type": "user", "message": {"role": "user", "content": "This session is being continued from a previous conversation that ran out of context. Summary: blah blah must not appear as a user message."}},
    {"type": "assistant", "message": {"content": [{"type": "tool_use", "name": "mcp__goodmem__goodmem_memories_create", "input": {"space_id": "x"}}]}},
    {"type": "user", "message": {"role": "user", "content": [{"type": "tool_result", "content": [{"type": "text", "text": "{\"memoryId\": \"019f4200-0000-7000-0000-00000000cea7\", \"processingStatus\": \"PENDING\"}"}]}]}},
    {"type": "user", "message": {"role": "user", "content": [{"type": "tool_result", "content": [{"type": "text", "text": "{\"retrievedItem\": {\"chunk\": {\"memoryId\": \"019f4200-0000-7000-0000-0000deadbeef\", \"relevanceScore\": 0.7}}}"}]}]}},
    {"type": "assistant", "isSidechain": True, "message": {"content": [{"type": "text", "text": "sidechain text must not win"}]}},
    {"type": "assistant", "message": {"content": [{"type": "text", "text": "final assistant status: gamma fixed"}]}},
    {"type": "assistant", "message": {"usage": {"input_tokens": 2000, "output_tokens": 400, "cache_read_input_tokens": 300000, "cache_creation_input_tokens": 500}}},
]
with open(sys.argv[1], "w") as f:
    for e in entries:
        f.write(json.dumps(e) + "\n")
EOF
EV_RICH="{\"hook_event_name\":\"PreCompact\",\"trigger\":\"manual\",\"session_id\":\"sess-2\",\"cwd\":\"$TD/projA\",\"transcript_path\":\"$TD/rich.jsonl\"}"
printf '%s' "$EV_RICH" | python3 "$REC"
AL="$TD/projA/.claude/blackboard/sess-2/LEDGER.auto.md"
[ -f "$AL" ] && ok "auto-ledger written when no model ledger" || bad "auto-ledger missing"
grep -q "make the smart compact genuinely good" "$AL" && ok "auto-ledger captures /goal" || bad "goal missing"
grep -q "second genuine ask about gamma" "$AL" && ok "auto-ledger captures genuine user msg" || bad "user msg missing"
grep -q "meta noise" "$AL" && bad "meta noise leaked into auto-ledger" || ok "meta/wrapper messages excluded"
grep -q "Caveat:" "$AL" && bad "caveat wrapper leaked" || ok "caveat wrapper excluded"
grep -q "/tmp/proj/alpha.py" "$AL" && ok "Edit file_path captured" || bad "Edit path missing"
grep -q "src/beta.ts" "$AL" && ok "serena relative_path captured" || bad "serena path missing"
grep -q "git commit" "$AL" && ok "commit flag noted" || bad "commit flag missing"
grep -q "torpedo failure in test_gamma" "$AL" && ok "last tool error captured" || bad "error missing"
grep -q "final assistant status: gamma fixed" "$AL" && ok "last assistant text captured" || bad "assistant text missing"
grep -q "sidechain text must not win" "$AL" && bad "sidechain text leaked" || ok "sidechain excluded"
grep -q "occupancy: 302900" "$AL" && ok "occupancy recorded in header" || bad "occupancy missing"
grep -q "compact boundary" "$AL" && ok "earlier-boundary note present" || bad "boundary note missing"
tail -1 "$COMPACT_EVENTS_LOG" | grep -q '"auto_ledger": "written"' && ok "auto_ledger=written logged" || bad "auto_ledger status missing"
grep -q "This session is being continued" "$AL" && bad "continuation-summary blob leaked into users" || ok "continuation-summary blob excluded"
grep -q "019f4200-0000-7000-0000-00000000cea7" "$AL" && ok "goodmem CREATE id captured as a write" || bad "create memoryId missing"
grep -q "019f4200-0000-7000-0000-0000deadbeef" "$AL" && bad "goodmem RETRIEVE id wrongly listed as a write" || ok "retrieve memoryId excluded from writes"
grep -q "## Memory writes" "$AL" && ok "Memory writes section present" || bad "memory writes section missing"

# 11b. Empty/all-sidechain transcript -> no stub written, status skipped-empty.
python3 - "$TD/sidechain-only.jsonl" <<'EOF'
import json, sys
with open(sys.argv[1], "w") as f:
    for i in range(3):
        f.write(json.dumps({"type": "assistant", "isSidechain": True, "message": {"content": [{"type": "text", "text": "agent noise"}]}}) + "\n")
EOF
EV_EMPTY="{\"hook_event_name\":\"PreCompact\",\"trigger\":\"manual\",\"session_id\":\"sess-empty\",\"cwd\":\"$TD/projA\",\"transcript_path\":\"$TD/sidechain-only.jsonl\"}"
printf '%s' "$EV_EMPTY" | python3 "$REC"
[ ! -f "$TD/projA/.claude/blackboard/sess-empty/LEDGER.auto.md" ] && ok "content-free transcript writes no auto-ledger stub" || bad "empty stub written"
tail -1 "$COMPACT_EVENTS_LOG" | grep -q '"auto_ledger": "skipped-empty"' && ok "auto_ledger=skipped-empty logged" || bad "skipped-empty status missing"

# 12. Auto-ledger skipped when the model ledger is FRESH.
mkdir -p "$TD/projA/.claude/blackboard/sess-3"
printf '# ledger\n' > "$TD/projA/.claude/blackboard/sess-3/LEDGER.md"
EV_S3="{\"hook_event_name\":\"PreCompact\",\"trigger\":\"auto\",\"session_id\":\"sess-3\",\"cwd\":\"$TD/projA\",\"transcript_path\":\"$TD/rich.jsonl\"}"
printf '%s' "$EV_S3" | python3 "$REC"
[ ! -f "$TD/projA/.claude/blackboard/sess-3/LEDGER.auto.md" ] && ok "fresh model ledger suppresses auto-ledger" || bad "auto-ledger written despite fresh model ledger"
tail -1 "$COMPACT_EVENTS_LOG" | grep -q '"auto_ledger": "skipped-fresh-model"' && ok "auto_ledger=skipped-fresh-model logged" || bad "skip status missing"

# 13. Auto-ledger written when the model ledger is STALE (25m).
touch -t "$(date -v-25M +%Y%m%d%H%M)" "$TD/projA/.claude/blackboard/sess-3/LEDGER.md"
printf '%s' "$EV_S3" | python3 "$REC"
[ -f "$TD/projA/.claude/blackboard/sess-3/LEDGER.auto.md" ] && ok "stale model ledger gets auto-ledger" || bad "auto-ledger missing for stale model ledger"

# 14. Agent event never writes an auto-ledger.
EV_AG2="{\"hook_event_name\":\"PreCompact\",\"trigger\":\"auto\",\"session_id\":\"sess-4\",\"cwd\":\"$TD/projA\",\"transcript_path\":\"$TD/rich.jsonl\",\"agent_id\":\"xyz\"}"
printf '%s' "$EV_AG2" | python3 "$REC"
[ ! -e "$TD/projA/.claude/blackboard/sess-4" ] && ok "agent event writes no auto-ledger" || bad "agent event wrote auto-ledger"

# 15. Rehydrator: auto-only injection (no model ledger) + outcome log.
EV_REH2="{\"hook_event_name\":\"SessionStart\",\"source\":\"compact\",\"session_id\":\"sess-2\",\"cwd\":\"$TD/projA\",\"transcript_path\":\"$TD/rich.jsonl\"}"
OUT=$(printf '%s' "$EV_REH2" | python3 "$REH")
printf '%s' "$OUT" | grep -q "MECHANICAL pre-compact extraction" && ok "auto-only injection flagged mechanical" || bad "auto-only injection missing"
printf '%s' "$OUT" | grep -q "make the smart compact genuinely good" && ok "auto-only injection carries extract" || bad "extract content missing"
tail -1 "$COMPACT_EVENTS_LOG" | grep -q '"outcome": "auto"' && ok "rehydrate outcome=auto logged" || bad "outcome log missing"

# 16. Rehydrator: model (30m, usable-but-predates) + fresh auto -> both blocks.
mkdir -p "$TD/projA/.claude/blackboard/sess-5"
printf '# SESSION LEDGER\nmodel-ledger-content\n' > "$TD/projA/.claude/blackboard/sess-5/LEDGER.md"
touch -t "$(date -v-30M +%Y%m%d%H%M)" "$TD/projA/.claude/blackboard/sess-5/LEDGER.md"
printf '# AUTO\nauto-delta-content\n' > "$TD/projA/.claude/blackboard/sess-5/LEDGER.auto.md"
EV_REH5="{\"hook_event_name\":\"SessionStart\",\"source\":\"compact\",\"session_id\":\"sess-5\",\"cwd\":\"$TD/projA\",\"transcript_path\":\"$TD/rich.jsonl\"}"
OUT=$(printf '%s' "$EV_REH5" | python3 "$REH")
printf '%s' "$OUT" | grep -q "model-ledger-content" && ok "model block present (30m ledger)" || bad "model block missing"
printf '%s' "$OUT" | grep -q "FINAL-MINUTES AUTO-EXTRACT" && ok "auto delta appended to stale-ish model ledger" || bad "auto delta missing"
printf '%s' "$OUT" | grep -q "trust the ledger" && ok "30m ledger keeps strong trust" || bad "trust language wrong"
tail -1 "$COMPACT_EVENTS_LOG" | grep -q '"outcome": "model+auto"' && ok "outcome=model+auto logged" || bad "model+auto outcome missing"

# 17. Rehydrator: FRESH model ledger (now) + fresh auto -> model only.
touch "$TD/projA/.claude/blackboard/sess-5/LEDGER.md"
OUT=$(printf '%s' "$EV_REH5" | python3 "$REH")
printf '%s' "$OUT" | grep -q "FINAL-MINUTES" && bad "auto delta appended despite fresh model ledger" || ok "fresh model ledger stands alone"
tail -1 "$COMPACT_EVENTS_LOG" | grep -q '"outcome": "model"' && ok "outcome=model logged" || bad "model outcome missing"

# 18. Rehydrator: STALE auto (20m) + no model -> recovery.
mkdir -p "$TD/projA/.claude/blackboard/sess-7"
printf '# AUTO\nold-extract\n' > "$TD/projA/.claude/blackboard/sess-7/LEDGER.auto.md"
touch -t "$(date -v-20M +%Y%m%d%H%M)" "$TD/projA/.claude/blackboard/sess-7/LEDGER.auto.md"
EV_REH7="{\"hook_event_name\":\"SessionStart\",\"source\":\"compact\",\"session_id\":\"sess-7\",\"cwd\":\"$TD/projA\",\"transcript_path\":\"$TD/rich.jsonl\"}"
printf '%s' "$EV_REH7" | python3 "$REH" | grep -q "POST-COMPACT RECOVERY" && ok "stale auto-ledger falls to recovery" || bad "stale auto not rejected"

# 19. Resume crash-window with only a fresh auto-ledger: injects it (never RECOVERY on resume).
EV_RES2="{\"hook_event_name\":\"SessionStart\",\"source\":\"resume\",\"session_id\":\"sess-2\",\"cwd\":\"$TD/projA\",\"transcript_path\":\"$TD/rich.jsonl\"}"
OUT=$(printf '%s' "$EV_RES2" | python3 "$REH")
printf '%s' "$OUT" | grep -q "MECHANICAL" && ok "crash-window resume injects auto-ledger" || bad "resume auto injection missing"
python3 - "$TD/rich.jsonl" <<'EOF'
import json, sys
with open(sys.argv[1], "a") as f:
    f.write(json.dumps({"type": "user", "message": {"content": "POST-COMPACT REHYDRATION marker"}}) + "\n")
EOF
OUT=$(printf '%s' "$EV_RES2" | python3 "$REH")
[ -z "$OUT" ] && ok "resume after persisted rehydration: silent" || bad "resume double-injected after marker"

# 19b. Escaped mentions never count as a boundary: prose QUOTING the boundary
# string after the rehydration marker must not re-arm the crash window.
python3 - "$TD/rich.jsonl" <<'EOF'
import json, sys
with open(sys.argv[1], "a") as f:
    f.write(json.dumps({"type": "user", "message": {"content": 'prose quoting "subtype":"compact_boundary" from a file read'}}) + "\n")
EOF
OUT=$(printf '%s' "$EV_RES2" | python3 "$REH")
[ -z "$OUT" ] && ok "escaped boundary mention does not re-arm crash window" || bad "escaped mention re-armed resume injection"

# 19c. Total injected context stays under the 16KB budget: a maxed model
# ledger spends it all and the auto block is SKIPPED, never squeezed over.
mkdir -p "$TD/projA/.claude/blackboard/sess-8"
python3 -c "open('$TD/projA/.claude/blackboard/sess-8/LEDGER.md','w').write('# big\n'+'y'*17000)"
touch -t "$(date -v-30M +%Y%m%d%H%M)" "$TD/projA/.claude/blackboard/sess-8/LEDGER.md"
printf '# AUTO\nfresh-auto-content\n' > "$TD/projA/.claude/blackboard/sess-8/LEDGER.auto.md"
EV_REH8="{\"hook_event_name\":\"SessionStart\",\"source\":\"compact\",\"session_id\":\"sess-8\",\"cwd\":\"$TD/projA\",\"transcript_path\":\"$TD/rich.jsonl\"}"
OUT=$(printf '%s' "$EV_REH8" | python3 "$REH")
BYTES=$(printf '%s' "$OUT" | python3 -c "import json,sys;print(len(json.load(sys.stdin)['hookSpecificOutput']['additionalContext'].encode()))")
[ "$BYTES" -le 16384 ] && ok "total injected context <= 16384B ($BYTES)" || bad "cap violated: ${BYTES}B"
printf '%s' "$OUT" | grep -q "FINAL-MINUTES" && bad "auto block squeezed in over budget" || ok "auto block skipped when model spends the budget"
printf '%s' "$OUT" | grep -q "TRUNCATED at " && ok "oversized model body truncated with marker" || bad "truncation marker missing on maxed ledger"

# 19d. Boundary verifier: a PreCompact with no boundary after it = FAILED
# compaction — the stamp + tier sentinels must be voided so watermark nudges
# re-arm (the retry loop), and a verify-failed event logged. ledger_path pin
# survives. COMPACT_VERIFY_DELAY_S=0 makes the wait instant for tests.
VT="$TD/verify.jsonl"
python3 -c "import json;open('$VT','w').write(json.dumps({'type':'assistant','message':{'usage':{'input_tokens':1,'output_tokens':1,'cache_read_input_tokens':1,'cache_creation_input_tokens':1}}})+'\n')"
VKEY=$(python3 -c "import hashlib;print(hashlib.sha1('$VT'.encode()).hexdigest()[:16])")
VSTATE="/tmp/claude-context-watermark/$VKEY"; rm -rf "$VSTATE"; mkdir -p "$VSTATE"
touch "$VSTATE/t1" "$VSTATE/t2" "$VSTATE/t3" "$VSTATE/compacted"
printf '%s' "/x/LEDGER.md" > "$VSTATE/ledger_path"
VPRE=$(wc -c < "$VT" | tr -d ' ')
python3 -c "import json;open('$VT','a').write(json.dumps({'type':'system','subtype':'local_command','content':'<local-command-stdout>Error during compaction: limit</local-command-stdout>'})+'\n')"
echo '' | COMPACT_VERIFY_DELAY_S=0 python3 "$REC" --verify-boundary "$VT" "$VPRE" "$VSTATE" sess-v
{ [ ! -f "$VSTATE/compacted" ] && [ ! -f "$VSTATE/t1" ] && [ ! -f "$VSTATE/t3" ]; } && ok "verifier voids stamp+sentinels when no boundary lands" || bad "verifier did not void state"
[ -f "$VSTATE/ledger_path" ] && ok "verifier leaves ledger_path pin" || bad "verifier removed ledger_path"
tail -1 "$COMPACT_EVENTS_LOG" | grep -q '"event": "compact-verify-failed"' && ok "compact-verify-failed event logged" || bad "verify-failed event missing"
mkdir -p "$VSTATE"; touch "$VSTATE/t1" "$VSTATE/compacted"
python3 -c "import json;open('$VT','a').write(json.dumps({'type':'system','subtype':'compact_boundary'})+'\n')"
echo '' | COMPACT_VERIFY_DELAY_S=0 python3 "$REC" --verify-boundary "$VT" "$VPRE" "$VSTATE" sess-v
{ [ -f "$VSTATE/compacted" ] && [ -f "$VSTATE/t1" ]; } && ok "verifier leaves state intact when boundary present" || bad "verifier cleared despite boundary"
VPRE2=$(wc -c < "$VT" | tr -d ' ')
python3 - "$VT" <<'EOF'
open(__import__('sys').argv[1], 'a').write('prose quoting \\"subtype\\":\\"compact_boundary\\" only\n')
EOF
echo '' | COMPACT_VERIFY_DELAY_S=0 python3 "$REC" --verify-boundary "$VT" "$VPRE2" "$VSTATE" sess-v
[ ! -f "$VSTATE/compacted" ] && ok "escaped boundary mention not counted as a boundary" || bad "escaped mention counted"
# 19e. BEHAVIORAL spawn check (review 2026-07-09: string-presence alone lets a
# broken Popen ship green — every exception in the spawn path is swallowed).
# A real main-session PreCompact event, delay 0, no boundary ever appended:
# the child the hook itself spawned must void the state within a few seconds.
VT2="$TD/verify-spawn.jsonl"
python3 -c "import json;open('$VT2','w').write(json.dumps({'type':'assistant','message':{'usage':{'input_tokens':1,'output_tokens':1,'cache_read_input_tokens':1,'cache_creation_input_tokens':1}}})+'\n')"
VKEY2=$(python3 -c "import hashlib;print(hashlib.sha1('$VT2'.encode()).hexdigest()[:16])")
VSTATE2="/tmp/claude-context-watermark/$VKEY2"; rm -rf "$VSTATE2"; mkdir -p "$VSTATE2"
touch "$VSTATE2/t1" "$VSTATE2/t3"
EV_VS="{\"hook_event_name\":\"PreCompact\",\"trigger\":\"manual\",\"session_id\":\"sess-vs\",\"cwd\":\"$TD/projA\",\"transcript_path\":\"$VT2\"}"
printf '%s' "$EV_VS" | COMPACT_VERIFY_DELAY_S=0 python3 "$REC"
vs_ok=1
for i in 1 2 3 4 5 6 7 8; do
  sleep 0.5
  if [ ! -f "$VSTATE2/compacted" ] && [ ! -f "$VSTATE2/t1" ] && [ ! -f "$VSTATE2/t3" ]; then vs_ok=0; break; fi
done
[ "$vs_ok" -eq 0 ] && ok "main() REALLY spawns the verifier (spawned child voided state)" || bad "spawned verifier never voided state (spawn path broken)"
grep '"session_id": "sess-vs"' "$COMPACT_EVENTS_LOG" | grep -q '"event": "compact-verify-failed"' && ok "spawned verifier logged verify-failed" || bad "spawned verifier event missing"
rm -rf "$VSTATE" "$VSTATE2"

# 20. Events-log rotation at 1MB.
ROT="$TD/rot.log"
python3 -c "open('$ROT','w').write('x'*1100000)"
printf '%s' "$EV_S3" | COMPACT_EVENTS_LOG="$ROT" python3 "$REC"
[ -f "$ROT.1" ] && ok "events log rotated at 1MB" || bad "rotation missing"
[ "$(wc -c < "$ROT")" -lt 4096 ] && ok "fresh events log small after rotation" || bad "log not reset"

echo "---- $PASS passed, $FAIL failed"
rm -rf "$TD" "$STATE"
exit $FAIL
