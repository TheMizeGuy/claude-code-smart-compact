#!/bin/bash
# install.sh — install the smart-compact system onto this machine.
#
# Usage: ./install.sh [--window <tokens>]
#
#   --window   Your session's context window in tokens (the nominal
#              auto-compact anchor the watermark hook tiers against).
#              Default 200000 (standard Claude Code sessions). If you run
#              extended-context sessions (e.g. a [1m] model config), pass
#              your real window, e.g. --window 1000000.
#
# Idempotent: safe to re-run; existing files that differ are backed up as
# <file>.pre-smart-compact-<ts> before being overwritten, and config appends
# are skipped when their distinctive content is already present.
set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
TS="$(date +%Y%m%d-%H%M%S)"
WINDOW="200000"

while [ $# -gt 0 ]; do
  case "$1" in
    --window) WINDOW="${2:?--window needs a value}"; shift 2 ;;
    *) echo "install.sh: unknown arg $1" >&2; exit 1 ;;
  esac
done
case "$WINDOW" in *[!0-9]*|'') echo "install.sh: --window must be a positive integer" >&2; exit 1 ;; esac

say()  { printf '%s\n' "$*"; }
fail() { printf 'install.sh: %s\n' "$*" >&2; exit 1; }

# --- preflight ---------------------------------------------------------------
command -v python3 >/dev/null || fail "python3 is required (macOS: xcode-select --install)"
command -v tmux    >/dev/null || fail "tmux is required (brew install tmux)"
command -v git     >/dev/null || fail "git is required"
[ "$(uname)" = "Darwin" ] || say "WARNING: hooks/scripts are macOS-flavored (stat -f, /tmp semantics, terminal-notifier). Linux needs a port pass."
command -v terminal-notifier >/dev/null || say "NOTE: terminal-notifier not found (optional; self-compact abort banners degrade to tmux messages). brew install terminal-notifier"
command -v claude  >/dev/null || say "NOTE: claude not found on PATH yet — install Claude Code before the smoke test."

# --- files -------------------------------------------------------------------
install_file() { # src dst
  local src="$1" dst="$2"
  mkdir -p "$(dirname "$dst")"
  if [ -f "$dst" ] && ! cmp -s "$src" "$dst"; then
    cp -p "$dst" "$dst.pre-smart-compact-$TS"
    say "backed up: $dst -> $dst.pre-smart-compact-$TS"
  fi
  cp -p "$src" "$dst"
  chmod +x "$dst"
  say "installed: $dst"
}

install_file "$REPO/hooks/context-watermark.py"        "$HOME/.claude/hooks/context-watermark.py"
install_file "$REPO/hooks/precompact-recorder.py"      "$HOME/.claude/hooks/precompact-recorder.py"
install_file "$REPO/hooks/compact-rehydrate.py"        "$HOME/.claude/hooks/compact-rehydrate.py"
install_file "$REPO/scripts/self-compact.sh"           "$HOME/.claude/scripts/self-compact.sh"
install_file "$REPO/scripts/claude-tmux.sh"            "$HOME/.claude/scripts/claude-tmux.sh"
install_file "$REPO/scripts/tmux-global-env-scrub.sh"  "$HOME/.claude/scripts/tmux-global-env-scrub.sh"
install_file "$REPO/scripts/check-harness-assumptions.py" "$HOME/.claude/scripts/check-harness-assumptions.py"

mkdir -p "$HOME/.claude/logs" "$HOME/.claude/state/tmux-sockets" "$HOME/.claude/state/tmux-sessions"

# --- settings.json hook wiring -------------------------------------------------
python3 - "$REPO/settings/settings-fragment.json" "$TS" "$WINDOW" <<'PYEOF'
import json, os, shutil, sys

frag_path, ts, window = sys.argv[1], sys.argv[2], sys.argv[3]
home = os.path.expanduser("~")
sp = os.path.join(home, ".claude", "settings.json")

frag = json.load(open(frag_path))
frag.pop("//", None)
frag["env"]["CLAUDE_CODE_AUTO_COMPACT_WINDOW"] = window

try:
    settings = json.load(open(sp))
except (FileNotFoundError, json.JSONDecodeError) as e:
    if isinstance(e, json.JSONDecodeError):
        sys.exit(f"settings.json exists but is not valid JSON — fix it first: {sp}")
    settings = {}

changed = False

env = settings.setdefault("env", {})
for k, v in frag.get("env", {}).items():
    if k not in env:  # never clobber an existing tuned value
        env[k] = v
        changed = True

hooks = settings.setdefault("hooks", {})
for event, entries in frag.get("hooks", {}).items():
    ev = hooks.setdefault(event, [])
    for entry in entries:
        matcher = entry.get("matcher")
        for h in entry.get("hooks", []):
            h = dict(h, command=h["command"].replace("$HOME", home))
            target = next((e for e in ev if e.get("matcher") == matcher), None)
            if target is None:
                new = {"hooks": [h]}
                if matcher is not None:
                    new = {"matcher": matcher, "hooks": [h]}
                ev.append(new)
                changed = True
            elif h["command"] not in [x.get("command") for x in target.setdefault("hooks", [])]:
                target["hooks"].append(h)
                changed = True

if changed:
    if os.path.exists(sp):
        shutil.copy2(sp, f"{sp}.pre-smart-compact-{ts}")
    os.makedirs(os.path.dirname(sp), exist_ok=True)
    with open(sp, "w") as f:
        json.dump(settings, f, indent=2)
        f.write("\n")
    print(f"settings.json: hook wiring merged (backup: {sp}.pre-smart-compact-{ts})" if os.path.exists(f"{sp}.pre-smart-compact-{ts}") else "settings.json: created with hook wiring")
else:
    print("settings.json: already wired — no change")
PYEOF

# --- global gitignore (ledgers/blackboards must never be committed) -----------
excl="$(git config --global core.excludesFile || true)"
if [ -z "$excl" ]; then
  excl="$HOME/.gitignore_global"
  git config --global core.excludesFile "$excl"
  say "git: set core.excludesFile = $excl"
fi
excl="${excl/#\~/$HOME}"
touch "$excl"
if ! grep -qxF '.claude/blackboard/' "$excl"; then
  cat "$REPO/config/gitignore_global.snippet" >> "$excl"
  say "git: added .claude/blackboard/ to $excl"
else
  say "git: .claude/blackboard/ already ignored"
fi

# --- tmux.conf ----------------------------------------------------------------
if ! grep -q 'tmux-global-env-scrub.sh' "$HOME/.tmux.conf" 2>/dev/null; then
  cat "$REPO/config/tmux.conf.snippet" >> "$HOME/.tmux.conf"
  say "tmux: appended smart-compact block to ~/.tmux.conf"
else
  say "tmux: ~/.tmux.conf already carries the identity scrub — snippet skipped"
fi

# --- zshrc (ctm launcher alias) ------------------------------------------------
if ! grep -q 'alias ctm=' "$HOME/.zshrc" 2>/dev/null; then
  cat "$REPO/config/zshrc.snippet" >> "$HOME/.zshrc"
  say "zsh: appended ctm alias to ~/.zshrc"
else
  say "zsh: ctm alias already present"
fi

# --- CLAUDE.md compact instructions --------------------------------------------
if ! grep -q '^# Compact instructions' "$HOME/.claude/CLAUDE.md" 2>/dev/null; then
  { [ -s "$HOME/.claude/CLAUDE.md" ] && printf '\n'; cat "$REPO/config/claude-md-compact-instructions.md"; } >> "$HOME/.claude/CLAUDE.md"
  say "CLAUDE.md: appended '# Compact instructions' section"
else
  say "CLAUDE.md: '# Compact instructions' already present"
fi

say ""
say "Done (window: $WINDOW tokens). Next:"
say "  1. Restart any running Claude Code sessions (hooks load at session start)."
say "  2. Verify: cd $REPO/tests && for t in test-*.sh; do bash \"\$t\"; done"
say "  3. Launch inside tmux for self-compaction: source ~/.zshrc && ctm scratch"
say "  4. After some real usage: python3 ~/.claude/scripts/check-harness-assumptions.py"
