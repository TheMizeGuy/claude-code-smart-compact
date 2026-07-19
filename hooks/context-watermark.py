#!/usr/bin/env python3
"""Context watermark hook (PostToolUse + UserPromptSubmit).

Computes true context-window occupancy from the transcript (latest assistant
message.usage) and injects a
one-shot additionalContext nudge as the session crosses 75% / 87% / 94% of the
EFFECTIVE auto-compact ceiling — the MAX of recently OBSERVED auto-compact
occupancies from the flight recorder, not the nominal
CLAUDE_CODE_AUTO_COMPACT_WINDOW (the harness fires well below it; see
effective_ceiling). The nudges drive the smart-compact protocol: externalize
state to the session ledger BEFORE auto-compaction fires, so
compact-rehydrate.py can re-inject it after.

Design doc: docs/ARCHITECTURE.md in this repo.
State: /tmp/claude-context-watermark/<sha1(transcript_path)[:16]>/
  t1|t2|t3   one-shot sentinels          last_check  rate-limit stamp
  compacted  stamped by precompact-recorder.py (forces re-arm)
State lives in /tmp deliberately: it is per-conversation and ephemeral; the
worst a purge can cause is one repeat nudge.

Invariants: never blocks, never errors a tool call — every failure exits 0.
Re-arm: occupancy < 55% of window (or `compacted` stamp) clears sentinels.
WATERMARK_FORCE=1 bypasses the 10s rate limit (tests).
"""
import hashlib
import json
import os
import sys
import time

STATE_ROOT = "/tmp/claude-context-watermark"
RATE_LIMIT_S = 10
REARM_BELOW = 0.55
TIERS = (("t1", 0.75), ("t2", 0.87), ("t3", 0.94))

LEDGER_TEMPLATE = """# SESSION LEDGER (update the timestamp on every write)
## Goal & acceptance criteria
## Now: active task + next 3 actions
## Done so far
## Decisions & constraints (incl. user corrections)
## Files/symbols touched
## Verbatim critical state (errors, test output, IDs, branch/PR)
## Memory writes (memory-tool IDs)"""


def latest_usage_tokens(path):
    """Bounded 256KB reverse-scan for the latest assistant usage sum.

    Kept in sync with the copy in precompact-recorder.py. Skips isSidechain
    entries: current builds keep subagent
    turns in separate transcript files, but older formats inlined them with
    isSidechain: true — their usage reflects the subagent's window, not ours.
    """
    try:
        size = os.path.getsize(path)
    except OSError:
        return None
    n = min(size, 262144)
    try:
        with open(path, "rb") as f:
            f.seek(size - n)
            data = f.read(n).decode("utf-8", errors="replace")
    except OSError:
        return None
    lines = data.split("\n")
    if size > n:
        lines = lines[1:]
    for line in reversed(lines):
        line = line.strip()
        if not line:
            continue
        try:
            d = json.loads(line)
        except ValueError:
            continue
        # A compact boundary seen before any assistant usage means every usage
        # entry behind it is PRE-compact: occupancy is unknown until the first
        # post-compact assistant turn. Returning it would spuriously re-fire
        # the top tier right after the rehydrator re-armed the sentinels.
        if d.get("type") == "system" and d.get("subtype") == "compact_boundary":
            return None
        if d.get("type") != "assistant" or d.get("isSidechain"):
            continue
        u = d.get("message", {}).get("usage")
        if not isinstance(u, dict):
            continue
        return (
            u.get("input_tokens", 0)
            + u.get("output_tokens", 0)
            + u.get("cache_read_input_tokens", 0)
            + u.get("cache_creation_input_tokens", 0)
        )
    return None


def resolve_window():
    v = os.environ.get("CLAUDE_CODE_AUTO_COMPACT_WINDOW", "").strip()
    if v.isdigit() and int(v) > 0:
        return int(v)
    try:
        with open(os.path.expanduser("~/.claude/settings.json")) as f:
            v = str(json.load(f).get("env", {}).get("CLAUDE_CODE_AUTO_COMPACT_WINDOW", "")).strip()
        if v.isdigit() and int(v) > 0:
            return int(v)
    except (OSError, ValueError):
        pass
    return 1_000_000


EVENTS_LOG = os.environ.get("COMPACT_EVENTS_LOG") or os.path.expanduser(
    "~/.claude/logs/compact-events.log"
)


def effective_ceiling(window):
    """Estimate where auto-compact ACTUALLY fires: MAX of the last 5 genuine
    auto occupancies from the flight recorder, clamped to [50%, 100%] of the
    nominal window.

    The harness's real trigger point sits below CLAUDE_CODE_AUTO_COMPACT_WINDOW
    and moves across builds (observed clusters ~533K and ~615-618K against
    650K). Tiers computed against the nominal window sat ABOVE the real point,
    so T2/T3 never fired and 13/20 compactions landed with no ledger
    (2026-07-08 flight data). Learning the ceiling from the recorder's own log
    self-corrects across harness updates.

    Max, not median (2026-07-17): a recorded occupancy is the LAST assistant
    usage before the compaction — everything appended after it (the very
    growth that tripped auto-compact, e.g. a huge mid-turn tool result) is
    invisible, so samples only ever UNDERSTATE the true trigger and max stays
    a safe lower bound. Live data: lag artifacts 395-492K amid a true ~616K
    trigger put the median at 492,578 — T3 fired ~123K early and sessions
    self-compacted at 437-450K, wasting ~170K of usable window per cycle.
    Cost of max: a build regression that LOWERS the trigger takes up to 5
    samples to re-learn (T1 + the recorder's auto-ledger floor cover the
    transition). Fewer than 2 samples (fresh install, rotated-away log):
    assume 85% of nominal — mildly-early nudges beat dead ones.
    """
    samples = []
    try:
        size = os.path.getsize(EVENTS_LOG)
        with open(EVENTS_LOG, "rb") as f:
            f.seek(max(0, size - 131072))
            data = f.read().decode("utf-8", errors="replace")
        lines = data.split("\n")
        if size > 131072:
            lines = lines[1:]
        for line in lines:
            line = line.strip()
            if not line:
                continue
            try:
                d = json.loads(line)
            except ValueError:
                continue
            # Genuine main-session auto-compactions only: rehydrate/outcome
            # lines carry `event`, subagent compactions carry `agent`, and
            # manual compacts say nothing about where AUTO fires.
            if d.get("event") or d.get("agent") or d.get("trigger") != "auto":
                continue
            occ = d.get("occupancy")
            if isinstance(occ, int) and occ > 0:
                samples.append(occ)
    except OSError:
        pass
    samples = samples[-5:]
    if len(samples) < 2:
        # 1000-token floor: a typo'd tiny window would otherwise yield
        # ceiling 0 and a silently-swallowed ZeroDivisionError on every call.
        return max(int(window * 0.85), 1000)
    return max(int(window * 0.5), min(max(samples), window), 1000)


def self_compact_line(transcript):
    """When the session runs inside tmux, the model can genuinely self-compact
    (proven 2026-07-05): self-compact.sh types /compact into this pane after
    the turn ends, waits for the boundary, then types a continuation prompt.
    The exact transcript path is handed over as arg 3 — the script's own
    resolution is ambiguous with two concurrent sessions in one cwd."""
    if not os.environ.get("TMUX_PANE"):
        return ""
    return (
        " SELF-COMPACTION AVAILABLE (tmux session): instead of waiting for "
        "auto-compact, at the clean boundary run "
        "~/.claude/scripts/self-compact.sh '<one-line focus>' '<continuation "
        f"prompt naming the exact next action>' '{transcript}' — after this "
        "turn ends it types /compact into this pane, waits for compaction, "
        "then resumes you with the continuation. Write the ledger FIRST."
    )


def ledger_status(ledger):
    """Self-auditing line for T2/T3: the nudge states whether the checkpoint
    actually exists rather than assuming the model wrote it."""
    try:
        age_m = int((time.time() - os.path.getmtime(ledger)) / 60)
        return f"Current ledger: updated {age_m}m ago — refresh it if anything material changed since."
    except OSError:
        return "Current ledger: MISSING — nothing will survive compaction until you write it."


def nudge_text(tier, occ, win, ceiling, ledger, transcript):
    left = max(ceiling - occ, 0)
    where = (
        f"auto-compact expected near ~{ceiling:,} tokens "
        f"(learned from recent compactions; nominal window {win:,})"
    )
    if tier == "t1":
        return (
            f"CONTEXT WATERMARK 75% — occupancy {occ:,}; {where}. "
            "Start externalizing state: at the next "
            f"natural boundary create/refresh the session ledger at {ledger} "
            "(goal, active task, decisions, files touched, next actions). Keep tool "
            "output lean; prefer subagents for bulk reads; write durable results to "
            "files as you produce them."
        )
    if tier == "t2":
        return (
            f"CONTEXT WATERMARK 87% — occupancy {occ:,}; {where}; ~{left:,} tokens of "
            f"headroom. CHECKPOINT NOW: write or refresh {ledger} using the template "
            "below, then prefer finishing the current work unit over starting new ones. "
            "If the user is active, suggest a manual /compact at this clean boundary — "
            "it beats an automatic one landing mid-task later.\n"
            f"{LEDGER_TEMPLATE}\n"
            "Keep it under 8KB, concrete paths and verbatim errors over prose. After "
            "compaction this ledger is re-injected verbatim and treated as authoritative. "
            f"{ledger_status(ledger)}{self_compact_line(transcript)}"
        )
    return (
        f"CONTEXT WATERMARK 94% — occupancy {occ:,}; {where}; auto-compact is "
        f"imminent (~{left:,} tokens of headroom). Ensure {ledger} is current NOW. "
        "Wrap up in-flight work; do not start new multi-step work; keep responses "
        "lean until compaction passes. The ledger is re-injected automatically after "
        f"compaction. {ledger_status(ledger)}{self_compact_line(transcript)}"
    )


def gc_old_state(now):
    try:
        for name in os.listdir(STATE_ROOT):
            p = os.path.join(STATE_ROOT, name)
            try:
                if now - os.path.getmtime(p) > 7 * 86400:
                    for f in os.listdir(p):
                        os.unlink(os.path.join(p, f))
                    os.rmdir(p)
            except OSError:
                continue
    except OSError:
        pass


def main():
    event = json.load(sys.stdin)
    # Subagent tool calls fire PostToolUse with the PARENT's session_id and
    # transcript_path but carry agent_id/agent_type (verified empirically
    # 2026-07-05). Without this guard a subagent would consume the parent's
    # one-shot sentinel and receive the nudge meant for the main loop.
    if event.get("agent_id") or event.get("agent_type"):
        return
    transcript = event.get("transcript_path") or ""
    if not transcript or not os.path.isfile(transcript):
        return
    key = hashlib.sha1(transcript.encode()).hexdigest()[:16]
    state = os.path.join(STATE_ROOT, key)
    os.makedirs(state, exist_ok=True)
    now = time.time()

    # Periodic GC (6h sentinel): the original nudge-path-only GC never ran for
    # sessions that stay under 75% occupancy — the common case — so state dirs
    # accumulated indefinitely (86 dirs in 36h observed 2026-07-06).
    gc_stamp = os.path.join(STATE_ROOT, ".last_gc")
    try:
        gc_due = now - os.path.getmtime(gc_stamp) > 21600
    except OSError:
        gc_due = True
    if gc_due:
        with open(gc_stamp, "w") as f:
            f.write(str(int(now)))
        gc_old_state(now)

    stamp = os.path.join(state, "last_check")
    if os.environ.get("WATERMARK_FORCE") != "1":
        try:
            if now - os.path.getmtime(stamp) < RATE_LIMIT_S:
                return
        except OSError:
            pass
    with open(stamp, "w") as f:
        f.write(str(int(now)))

    occ = latest_usage_tokens(transcript)
    if not occ:
        return
    win = resolve_window()
    ceiling = effective_ceiling(win)
    ratio = occ / ceiling

    fired = {t: os.path.exists(os.path.join(state, t)) for t, _ in TIERS}
    compacted = os.path.join(state, "compacted")
    # `compacted` means a compaction was claimed but a low reading hasn't been
    # observed yet: suppress firing until refill is confirmed (guards aborted
    # compacts and stale pre-compact readings the boundary check can't see).
    # A stamp older than 30min is void — compaction + first assistant turn
    # completes within minutes; never let a stray stamp mute a whole cycle.
    stamp_fresh = False
    try:
        stamp_fresh = now - os.path.getmtime(compacted) < 1800
        if not stamp_fresh:
            os.unlink(compacted)
    except OSError:
        pass
    # Re-arm on refill — and, once a compaction is CONFIRMED (stamp), on any
    # sub-T1 reading (a heavy post-compact context can legitimately reopen
    # above 55% of the ceiling) OR when no tier sentinel is set at all: with
    # nothing fired there is nothing to suppress, and holding the mute would
    # silence a genuinely-high first post-compact reading for the stamp's
    # whole 30-min life — exactly the pre-auto-compact window the nudges
    # exist for. The aborted-compact case the stamp protects keeps its
    # sentinels (only a REAL compaction clears them via the rehydrator), so
    # it still lands in the elif and stays suppressed.
    if ratio < REARM_BELOW or (
        stamp_fresh and (ratio < TIERS[0][1] or not any(fired.values()))
    ):
        if any(fired.values()) or stamp_fresh:
            for name in ("t1", "t2", "t3", "compacted"):
                try:
                    os.unlink(os.path.join(state, name))
                except OSError:
                    pass
            fired = {t: False for t, _ in TIERS}
    elif stamp_fresh:
        return
    # The ceiling is an ESTIMATE: a session whose true auto point runs past it
    # (per-session window variance is real — one 611K auto amid the 533K
    # cluster) must still get its highest tier, so a mild overshoot clamps to
    # just-under-1.0 instead of going silent. A wild ratio means garbage input.
    if ratio > 1.3:
        return
    if ratio > 1.0:
        ratio = 0.999

    # Highest crossed, un-fired tier wins; firing it marks it and all lower tiers.
    target = None
    for t, thresh in TIERS:
        if ratio >= thresh and not fired[t]:
            target = t
    if target is None:
        return
    # Exclusive-create the target sentinel: parallel tool calls both reach here
    # within the same window; only the winner may emit the nudge.
    try:
        os.close(os.open(os.path.join(state, target), os.O_CREAT | os.O_EXCL | os.O_WRONLY))
    except FileExistsError:
        return
    for t, _ in TIERS:
        if t == target:
            break
        open(os.path.join(state, t), "w").close()

    cwd = event.get("cwd") or os.getcwd()
    session_id = event.get("session_id") or "unknown-session"
    ledger = os.path.join(cwd, ".claude", "blackboard", session_id, "LEDGER.md")
    # Pin the ledger path so recorder/rehydrator find it even if cwd changes
    # between the nudge and the compaction.
    try:
        with open(os.path.join(state, "ledger_path"), "w") as f:
            f.write(ledger)
    except OSError:
        pass
    hook_event = event.get("hook_event_name") or "PostToolUse"

    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": hook_event,
            "additionalContext": nudge_text(target, occ, win, ceiling, ledger, transcript),
        }
    }))
    gc_old_state(now)


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass
    sys.exit(0)
