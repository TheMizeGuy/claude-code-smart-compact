#!/bin/bash
# End-to-end exercise of the REAL ~/.claude/scripts/self-compact.sh through the
# usage-limit retry path, against a stub tmux and a real transcript file.
#
# Why this exists: the 2026-07-08 frozen-baseline regression shipped while
# 33/33 extracted-fragment tests passed — the offline suite never ran the real
# watcher. This test does: schedule -> Phase 1 idle detection -> /compact send
# -> "Error during compaction" (usage-limit) entry -> fail-fast detection ->
# retry after the (already-elapsed) reset -> second /compact -> boundary ->
# continuation. Runtime ~30-45s (real watcher loops with shortened knobs).
set -u
SRC="$HOME/.claude/scripts/self-compact.sh"
P=0; F=0
ok(){ P=$((P+1)); printf 'PASS: %s\n' "$1"; }
bad(){ F=$((F+1)); printf 'FAIL: %s\n' "$1"; }

TD=$(mktemp -d)
trap 'rm -rf "$TD"' EXIT
export SC_E2E_CONTENT="$TD/pane-content"
export SC_E2E_SENDLOG="$TD/sends.log"
export SELF_COMPACT_LOG="$TD/watcher.log"
export WATERMARK_STATE_ROOT="$TD/watermark"
printf '> \n' > "$SC_E2E_CONTENT"
: > "$SC_E2E_SENDLOG"

# Stub tmux: claude-looking pane, content from a file, sends appended to a log.
mkdir -p "$TD/bin"
cat > "$TD/bin/tmux" <<'EOF'
#!/bin/bash
case "$1" in
  display-message) case "$*" in *pane_pid*) echo 4242 ;; *) echo claude ;; esac ;;
  capture-pane)    cat "$SC_E2E_CONTENT" 2>/dev/null ;;
  send-keys)       echo "$*" >> "$SC_E2E_SENDLOG" ;;
esac
exit 0
EOF
chmod +x "$TD/bin/tmux"
export PATH="$TD/bin:$PATH"
export TMUX="$TD/fake-socket,0,0" TMUX_PANE="%99"
unset CLAUDE_AGENT_ID CLAUDE_CODE_AGENT_ID 2>/dev/null

TR="$TD/transcript.jsonl"
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"turn end"}]}}' > "$TR"

# Shortened knobs: idle after 1s quiet; a reset stamped with the CURRENT minute
# parses as recent-past (retry-now), so the reset wait is a single iteration.
SELF_COMPACT_IDLE_S=1 SELF_COMPACT_IDLE_TIMEOUT=60 SELF_COMPACT_TIMEOUT=45 \
SELF_COMPACT_LIMIT_GRACE=1 SELF_COMPACT_LIMIT_RETRIES=1 \
bash "$SRC" "e2e focus" "e2e continuation prompt" "$TR" >/dev/null 2>&1 \
  && ok "scheduling call returned 0" || bad "scheduling call failed"

wait_for() { # $1 pattern in sendlog, $2 timeout s, $3 min count
  local t=0 n
  while [ "$t" -lt "$2" ]; do
    n=$(grep -cF "$1" "$SC_E2E_SENDLOG" 2>/dev/null)
    [ "${n:-0}" -ge "${3:-1}" ] && return 0
    sleep 1; t=$((t+1))
  done
  return 1
}

wait_for "/compact e2e focus" 20 1 && ok "watcher typed /compact after turn end" || bad "first /compact never sent"

# The /compact model call fails at the usage limit: only an error entry lands.
NOWT=$(TZ=America/New_York date '+%l:%M%p' | tr -d ' ' | tr 'APM' 'apm')
printf '%s\n' "{\"type\":\"system\",\"subtype\":\"local_command\",\"content\":\"<local-command-stdout>Error during compaction: You've hit your session limit · resets $NOWT (America/New_York)</local-command-stdout>\"}" >> "$TR"

wait_for "/compact e2e focus" 40 2 && ok "watcher re-sent /compact after the reset" || bad "retry /compact never sent"
grep -q "compaction FAILED" "$SELF_COMPACT_LOG" && ok "failure detected fast with the real reason" || bad "failure not logged"
grep -q "usage-limit blocked — retry 1/1" "$SELF_COMPACT_LOG" && ok "retry-after-reset path taken" || bad "retry path not logged"

# Retry succeeds: boundary lands in bytes after the retry baseline.
printf '%s\n' '{"type":"system","subtype":"compact_boundary"}' >> "$TR"
wait_for "e2e continuation prompt" 30 1 && ok "continuation sent after the retried compaction" || bad "continuation never sent"
grep -q "compact_boundary observed" "$SELF_COMPACT_LOG" && ok "boundary observed logged" || bad "boundary log missing"

echo "---- $P passed, $F failed"
exit $F
