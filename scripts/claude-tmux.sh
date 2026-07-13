#!/bin/bash
# Launch Claude Code inside an ISOLATED, per-launch tmux server — with a
# deterministic close-out lifecycle (2026-07-08 v2).
#
# Isolation model: every launch gets its OWN tmux server on an explicit `-S`
# socket under ~/.claude/state/tmux-sockets/ (NOT /tmp: immune to macOS's
# 3-day /tmp atime reaper, out of the shared tmux-<uid> dir, auditable with
# plain ls). There is NO shared server, so no stray in-session command and no
# external kill can cross sessions — isolation is the structural fix.
#
# Close-out lifecycle (no abandoned sessions):
#   * claude exits        -> session ends -> server exits (exit-empty) -> this
#                            script removes registry+socket+runner and prints a
#                            `claude --resume <id>` breadcrumb.
#   * terminal tab closes -> client dies -> AUTO sessions are destroyed
#                            (destroy-unattached): claude and every child
#                            workflow get SIGHUP'd; nothing lingers. Litter
#                            (registry entry + socket file — this script died
#                            with the tab) is swept by the NEXT launch's GC or
#                            any external cleanup tooling reading the registry.
#   * ctm <name> / KEEP   -> the deliberate EXCEPTIONS: survive tab close for
#                            reattach via `ctm <name>` (or tmux attach).
#
# Modes:
#   AUTO  (CLAUDE_TMUX_AUTONAME=1 — set it from your own shell wrapper): a NEW
#         isolated session per launch. Socket cc-<pid>-<rand>. Name = workspace
#         basename. destroy-unattached ON. All argv are claude args.
#   KEEP  (AUTO + CLAUDE_TMUX_KEEP=1): as AUTO but survives tab close.
#   NAMED (`ctm <name> [args]`): STABLE socket keyed on <name>, reattach-or-
#         create, survives tab close.
#
# Hardening notes (all empirically proven 2026-07-08 on tmux 3.7):
#   * The pane command is delivered via a generated RUNNER script, never
#     through tmux argv: tmux joins multi-arg commands with spaces (quoting
#     loss) and treats a trailing ';' in ANY argv token as a command separator
#     — i.e. prompt text like `claude "fix this;"` could inject tmux commands.
#     The runner printf-%q-escapes every element.
#   * destroy-unattached is set AFTER the client attaches (chained `';'`
#     command) — setting it in a conf kills a detached-created session at birth.
#   * If the tmux path fails to start, falls back to a BARE claude launch:
#     this wrapper must never leave the user unable to work.
set -u
shopt -s extglob

AUTO="${CLAUDE_TMUX_AUTONAME:-0}"
SOCK_DIR="${CLAUDE_TMUX_SOCK_DIR:-$HOME/.claude/state/tmux-sockets}"
REG_DIR="${CLAUDE_TMUX_REG_DIR:-$HOME/.claude/state/tmux-sessions}"
mkdir -p "$SOCK_DIR" "$REG_DIR" 2>/dev/null
chmod 700 "$SOCK_DIR" 2>/dev/null

# --- name + socket resolution ----------------------------------------------
# Workspace root = git worktree/superproject root, else $PWD (drives name + cwd).
WT="$(git rev-parse --show-toplevel 2>/dev/null || printf '%s' "$PWD")"

if [ "$AUTO" = "1" ]; then
  # AUTO: never consume $1 as a name — every positional is a claude arg.
  NAME="${CLAUDE_TMUX_NAME:-$(basename "$WT")}"
  NAME=${NAME//[.:]/-}; [ -n "$NAME" ] || NAME="claude"
  SOCK="cc-$$-${RANDOM}"
  for _i in 1 2 3; do [ -e "$SOCK_DIR/$SOCK" ] && SOCK="cc-$$-${RANDOM}" || break; done
  MODE="auto"; [ "${CLAUDE_TMUX_KEEP:-0}" = "1" ] && MODE="keep"
else
  # NAMED (ctm): first arg is the session NAME unless it looks like a claude flag.
  case "${1:-}" in
    ""|-*) NAME="claude" ;;
    *) NAME="$1"; shift ;;
  esac
  NAME=${NAME//[.:]/-}; [ -n "$NAME" ] || NAME="claude"
  HASH="$(printf '%s' "$NAME" | shasum 2>/dev/null | cut -c1-8)"
  [ -n "$HASH" ] || HASH="$$"
  SOCK="cc-n-$HASH"
  MODE="named"
fi
SP="$SOCK_DIR/$SOCK"
RUN="$SP.run"

# --- launch-time GC ----------------------------------------------------------
# Sweep registry entries + socket/runner files whose server is gone. The 30s
# age grace keeps concurrent just-starting launches (entry written before the
# server is up) out of the blast zone. Registry v2 rows start with an absolute
# socket path; anything else is skipped.
_now=$(date +%s)
for _f in "$REG_DIR"/*; do
  [ -f "$_f" ] || continue
  IFS=$'\t' read -r _sp _rest < "$_f" || true
  case "$_sp" in /*) ;; *) continue ;; esac
  _ep=$(awk -F'\t' '{print $5}' "$_f" 2>/dev/null); [ -n "$_ep" ] || _ep=0
  [ $(( _now - _ep )) -lt 30 ] && continue
  if ! tmux -S "$_sp" has-session 2>/dev/null; then
    rm -f "$_f" "$_sp" "$_sp.run" "$_sp.run.pid" 2>/dev/null
  fi
done
for _s in "$SOCK_DIR"/cc-*; do
  [ -S "$_s" ] || continue
  _mt=$(stat -f %m "$_s" 2>/dev/null); [ -n "$_mt" ] || _mt=0
  [ $(( _now - _mt )) -lt 30 ] && continue
  tmux -S "$_s" has-session 2>/dev/null && continue
  rm -f "$_s" "$_s.run" "$_s.run.pid" 2>/dev/null
done

# --- OAuth-concurrency soft warn ---------------------------------------------
# Every local claude process shares ONE keychain OAuth credential; refresh
# tokens are single-use + rotating, so N concurrent sessions race and one lost
# race revokes the whole grant (a real mass logout was observed at N=5-8). Live
# cc-* sockets with a running server = the wrapped-session population (registry
# rows undercount; bare un-wrapped `claude` launches are invisible either way).
# WARN only — a hard cap would break the ordinary 5-7-repo workflow.
WARN_N="${CLAUDE_TMUX_OAUTH_WARN_N:-8}"
_live=0
for _s in "$SOCK_DIR"/cc-*; do
  [ -S "$_s" ] || continue
  tmux -S "$_s" has-session 2>/dev/null && _live=$((_live+1))
done
if [ "$_live" -ge "$WARN_N" ]; then
  echo "claude-tmux: $_live concurrent local Claude sessions share one OAuth credential — a lost refresh race can log out ALL of them. Consider closing idle sessions. (threshold: CLAUDE_TMUX_OAUTH_WARN_N=$WARN_N)" >&2
fi

# --- argv handling -----------------------------------------------------------
# Dash guard (macOS Smart Dashes can turn a leading '--' into an em dash) for
# launches that don't come through a shell wrapper (ctm).
ARGS=()
for a in "$@"; do
  if [[ "$a" == [—–]* && "$a" != *' '* ]]; then
    a="--${a##+([—–])}"
  fi
  ARGS+=("$a")
done

# NAMED reattach detection — a reattach ignores the new pane command entirely,
# so skip the pin and preserve the registry's existing session id.
REATTACH=0
if [ "$MODE" = "named" ] && tmux -S "$SP" has-session -t "=$NAME" 2>/dev/null; then
  REATTACH=1
fi

# Pin session identity on argv (stale-relaunch guard, anthropics/claude-code#74403):
# an explicit --session-id survives the fleet/workflows TUI relaunch re-exec so
# resolution can't land on a stale sibling session. Skipped when the caller
# manages identity itself (resume/continue/fork/etc) or on a NAMED reattach.
PIN=1; SID="-"
for a in ${ARGS[@]+"${ARGS[@]}"}; do
  case "$a" in
    --resume|--resume=*|-r|--continue|-c|--session-id|--session-id=*|--fork-session) PIN=0 ;;
    --from-pr|--from-pr=*|--remote-control|--remote-control=*) PIN=0 ;;
  esac
done
[ "$REATTACH" = "1" ] && PIN=0
if [ "$PIN" = "1" ] && command -v uuidgen >/dev/null 2>&1; then
  SID="$(uuidgen | tr 'A-Z' 'a-z')"
  ARGS+=(--session-id "$SID")
fi
if [ "$REATTACH" = "1" ] && [ -f "$REG_DIR/$SOCK" ]; then
  SID=$(awk -F'\t' '{print $7}' "$REG_DIR/$SOCK" 2>/dev/null)
  [ -n "$SID" ] || SID="-"
fi

BIN=$(command -v claude) || { echo "claude-tmux: claude not on PATH" >&2; exit 1; }

# --- session-identity sanitization (2026-07-06, retained) --------------------
# tmux panes inherit the SERVER's global env, not the launching shell's. A
# server first started from inside a Claude session freezes that session's
# identity into the global env; every wrapped launch then boots believing it is
# a nested child of a dead session (degraded harness). Isolated sockets make
# this mostly moot for AUTO (fresh server, clean shell env), but a NAMED
# reattach can hit a server born earlier inside a session — keep both layers,
# targeted at THIS socket. (Layer 3 lives in ~/.tmux.conf at server birth.)
SCRUB_VARS=(
  CLAUDECODE CLAUDE_CODE_CHILD_SESSION CLAUDE_CODE_SESSION_ID
  CLAUDE_CODE_ENTRYPOINT CLAUDE_CODE_EXECPATH CLAUDE_CODE_VERSION
  CLAUDE_CODE_MAX_CONTEXT_TOKENS CLAUDE_CODE_BRIDGE_SESSION_ID
  CLAUDE_EFFORT CLAUDE_JOB_DIR CLAUDE_PLUGIN_DATA
  CODEX_COMPANION_SESSION_ID CODEX_COMPANION_TRANSCRIPT_PATH
  AI_AGENT TRACEPARENT GIT_EDITOR
  CLAUDE_CODE_AUTO_COMPACT_WINDOW CLAUDE_CODE_DAEMON_COLD_START
  CLAUDE_CODE_DISABLE_BG_EXIT_HANDOFF CLAUDE_CODE_STOP_HOOK_BLOCK_CAP
)
# Future-proofing: discover any not-yet-listed CLAUDE_*/CODEX_* identity var in
# the launching shell env AND this socket's global env. Wrapper controls are
# never identity.
while IFS= read -r v; do
  case "$v" in CLAUDE_NO_TMUX|CLAUDE_TMUX_*) continue ;; esac
  for k in "${SCRUB_VARS[@]}"; do [ "$k" = "$v" ] && continue 2; done
  SCRUB_VARS+=("$v")
done < <( { env; tmux -S "$SP" show-environment -g 2>/dev/null; } \
          | grep -oE '^(CLAUDECODE|CLAUDE_[A-Za-z0-9_]+|CODEX_[A-Za-z0-9_]+)=' \
          | tr -d '=' | sort -u )
# Layer 1: scrub THIS socket's server global env (no-op when the server isn't up).
if tmux -S "$SP" ls >/dev/null 2>&1; then
  for v in "${SCRUB_VARS[@]}"; do tmux -S "$SP" set-environment -g -u "$v" 2>/dev/null; done
fi
# Layer 2: strip the vars from the pane command itself.
SANITIZE=(/usr/bin/env)
for v in "${SCRUB_VARS[@]}"; do SANITIZE+=(-u "$v"); done

CMD=("${SANITIZE[@]}" "$BIN")

# Already inside tmux -> run in the current pane (never nest a server).
if [ -n "${TMUX:-}" ]; then
  exec "${CMD[@]}" ${ARGS[@]+"${ARGS[@]}"}
fi

# --- runner script (safe argv delivery — see hardening notes) ----------------
{
  printf '#!/bin/bash\n# generated by claude-tmux.sh — removed at close-out\n'
  printf 'printf %%s "$$" > %q 2>/dev/null\n' "$RUN.pid"
  printf 'exec'
  for x in "${CMD[@]}" ${ARGS[@]+"${ARGS[@]}"}; do printf ' %q' "$x"; done
  printf '\n'
} > "$RUN" 2>/dev/null || {
  echo "claude-tmux: cannot write runner script — launching bare" >&2
  exec "${CMD[@]}" ${ARGS[@]+"${ARGS[@]}"}
}
chmod 700 "$RUN" 2>/dev/null

# --- registry v2 (attach/cleanup helpers + external status tooling) ----------
# sockpath \t name \t workspace \t state \t epoch \t mode \t session-id
# CLAUDE_TMUX_PRIVATE=1 stamps mode 'private' in the REGISTRY ONLY (launch
# behavior keeps $MODE): external discovery/status tooling should skip
# 'private' rows. Tooling that rewrites rows must preserve the mode field.
REG_MODE="$MODE"
[ "${CLAUDE_TMUX_PRIVATE:-0}" = "1" ] && REG_MODE="private"
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
  "$SP" "$NAME" "$WT" "running" "$(date +%s)" "$REG_MODE" "$SID" \
  > "$REG_DIR/$SOCK" 2>/dev/null

# --- launch -------------------------------------------------------------------
# CLAUDE_TMUX_* env is exported into the session so the notify hooks can
# retarget this exact server. AUTO chains destroy-unattached AFTER the client
# has attached (post-create, race-free — proven pattern).
T0=$SECONDS
if [ "$MODE" = "auto" ]; then
  tmux -S "$SP" new-session -s "$NAME" -c "$WT" \
    -e CLAUDE_TMUX_SOCKPATH="$SP" -e CLAUDE_TMUX_SOCK="$SOCK" -e CLAUDE_TMUX_NAME="$NAME" \
    "$RUN" ';' set-option destroy-unattached on
else
  tmux -S "$SP" new-session -A -s "$NAME" -c "$WT" \
    -e CLAUDE_TMUX_SOCKPATH="$SP" -e CLAUDE_TMUX_SOCK="$SOCK" -e CLAUDE_TMUX_NAME="$NAME" \
    "$RUN"
fi
EC=$?
ELAPSED=$(( SECONDS - T0 ))

# --- close-out ----------------------------------------------------------------
SERVER_DEAD=0
tmux -S "$SP" has-session 2>/dev/null || SERVER_DEAD=1
PANE_RAN=0
[ -f "$RUN.pid" ] && PANE_RAN=1

if [ "$SERVER_DEAD" = "1" ]; then
  rm -f "$REG_DIR/$SOCK" "$SP" "$RUN" "$RUN.pid" 2>/dev/null
fi

# tmux itself failed before claude ever ran -> never block the user: go bare.
if [ "$EC" -ne 0 ] && [ "$ELAPSED" -lt 5 ] && [ "$PANE_RAN" = "0" ] && [ "$SERVER_DEAD" = "1" ]; then
  echo "claude-tmux: tmux failed to start (rc=$EC) — falling back to a bare launch" >&2
  exec "${CMD[@]}" ${ARGS[@]+"${ARGS[@]}"}
fi

if [ "$SERVER_DEAD" = "1" ] && [ "$PANE_RAN" = "1" ] && [ "$SID" != "-" ]; then
  printf 'claude [%s] closed — resume with: claude --resume %s\n' "$NAME" "$SID"
elif [ "$SERVER_DEAD" = "0" ]; then
  printf 'detached — session "%s" still running (reattach: ctm%s)\n' \
    "$NAME" "$( [ "$MODE" = "named" ] && printf ' or ctm %s' "$NAME" )"
fi
exit "$EC"
