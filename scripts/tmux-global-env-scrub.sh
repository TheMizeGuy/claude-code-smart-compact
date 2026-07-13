#!/bin/bash
# Dynamic backstop for the ~/.tmux.conf static session-identity scrub
# (2026-07-06). The static `set-environment -gu` lines cover every var known
# today; this helper additionally discovers ANY identity-namespace var a
# future Claude Code update stamps into the tmux global environment and
# scrubs it at server birth — so the protection survives updates without
# anyone editing the conf. Invoked from ~/.tmux.conf via if-shell/run-shell -b.
#
# $1 = socket path of the server being born (tmux.conf passes #{socket_path},
# 2026-07-08). REQUIRED for correctness on the isolated per-launch `-S`
# sockets: a plain `tmux` call from run-shell resolves to the DEFAULT socket,
# so without the arg the backstop silently scrubbed the wrong server (proven
# 2026-07-08 — the verify battery false-passed because its probe used a
# default-named socket). No arg = legacy default-socket behavior.
#
# Pattern spans the FULL CLAUDE_*/CODEX_* namespaces (plus the un-prefixed
# knowns): the static lists already hold non-CODE identity vars like
# CLAUDE_EFFORT, so future siblings will appear there too (adversarial probe
# 2026-07-06 showed CLAUDE_AGENT_FOO-style vars slipping a CLAUDE_CODE_-only
# pattern). CLAUDE_NO_TMUX / CLAUDE_TMUX_* are wrapper controls — exempt.
SOCK_ARG="${1:-}"
T() {
  if [ -n "$SOCK_ARG" ]; then tmux -S "$SOCK_ARG" "$@"; else tmux "$@"; fi
}
T show-environment -g 2>/dev/null \
  | grep -oE '^(CLAUDECODE|CLAUDE_[A-Za-z0-9_]+|CODEX_[A-Za-z0-9_]+|AI_AGENT|TRACEPARENT|GIT_EDITOR)=' \
  | tr -d '=' \
  | while IFS= read -r v; do
      case "$v" in CLAUDE_NO_TMUX|CLAUDE_TMUX_*) continue ;; esac
      T set-environment -g -u "$v" 2>/dev/null
    done
exit 0
