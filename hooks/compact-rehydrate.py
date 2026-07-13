#!/usr/bin/env python3
"""Post-compact rehydrator (SessionStart, matcher: compact).

After compaction, deterministically re-injects pre-compact state so the exact
active task survives the lossy summary. Injection lattice (16KB total cap):
  1. model-written LEDGER.md < 6h  -> authoritative (age-tiered trust language)
     ... plus the mechanical LEDGER.auto.md as a "final-minutes" delta when the
     model ledger is usable but predates the last stretch before compaction
  2. no usable model ledger, LEDGER.auto.md < 15m -> mechanical extract alone,
     flagged lower-fidelity (precompact-recorder writes it at PreCompact)
  3. neither -> short recovery protocol
Also clears the watermark sentinels (re-arms thresholds) and appends a
{event: "rehydrate", outcome} line to the flight log for observability.

Never blocks: every failure path exits 0 silently.
"""
import hashlib
import json
import os
import re
import sys
import time

STATE_ROOT = "/tmp/claude-context-watermark"
FRESH_S = 6 * 3600
AUTO_FRESH_S = 900          # auto-ledger is written seconds before compaction
MODEL_STALE_FOR_AUTO_S = 1200  # model ledger older than this gets the auto delta
MAX_LEDGER_BYTES = 16384    # TOTAL injected-context budget (wrapper text included)
WRAPPER_RESERVE = 600       # per-block allowance for the trust/label prose
MIN_AUTO_BUDGET = 1024      # skip the auto block below this rather than squeeze

RECOVERY = (
    "POST-COMPACT RECOVERY (no session ledger found): compaction just replaced "
    "earlier turns with a summary. Before continuing: (1) restate the active goal "
    "and acceptance criteria from the summary; (2) recover your tracked task list "
    "(TaskList tool, if available); (3) re-read key files instead of assuming their contents; (4) do not "
    "re-litigate decisions the summary records as made."
)


def unrehydrated_boundary(transcript):
    """True when the transcript tail shows a compact boundary with no
    rehydration marker after it — i.e. the session died in the window between
    compaction and the rehydration context being persisted.

    The boundary match is the UNESCAPED system-entry shape: tool results that
    merely quote 'compact_boundary' (reading these very hooks does exactly
    that) carry it \\"-escaped inside JSON strings and must not count — a bare
    substring here made normal resumes of sessions DISCUSSING compaction
    eligible for spurious re-injection. The rehydration-marker side stays a
    plain substring: its false-positive direction only SUPPRESSES injection
    (status-quo degradation), the safe direction."""
    try:
        size = os.path.getsize(transcript)
        n = min(size, 262144)
        with open(transcript, "rb") as f:
            f.seek(size - n)
            tail = f.read(n).decode("utf-8", errors="replace")
    except OSError:
        return False
    m = None
    for m in re.finditer(r'"subtype"\s*:\s*"compact_boundary"', tail):
        pass
    return m is not None and tail.rfind("POST-COMPACT REHYDRATION") < m.start()


def _log_outcome(session_id, outcome, model_age, auto_age):
    """One flight-log line per rehydration — which path fed the post-compact
    context (tracks the ledger-miss rate over time). The watermark's ceiling
    estimator skips lines carrying `event`."""
    try:
        log = os.environ.get("COMPACT_EVENTS_LOG") or os.path.expanduser(
            "~/.claude/logs/compact-events.log")
        os.makedirs(os.path.dirname(log), exist_ok=True)
        with open(log, "a") as f:
            f.write(json.dumps({
                "ts": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
                "session_id": session_id,
                "event": "rehydrate",
                "outcome": outcome,
                "ledger_age_s": int(model_age) if model_age is not None else None,
                "auto_age_s": int(auto_age) if auto_age is not None else None,
            }) + "\n")
    except OSError:
        pass


def main():
    event = json.load(sys.stdin)
    # Never inject the parent's ledger into a subagent (agent lifecycle events
    # carry agent_id/agent_type with the parent's session_id + transcript).
    if event.get("agent_id") or event.get("agent_type"):
        return
    session_id = event.get("session_id") or "unknown-session"
    cwd = event.get("cwd") or os.getcwd()
    transcript = event.get("transcript_path") or ""

    # On resume, act ONLY for the crash window: compaction happened but the
    # rehydration context never made it into the transcript. A normal resume
    # replays the persisted rehydration — injecting again would duplicate it.
    source = event.get("source") or ""
    if source == "resume" and not (transcript and unrehydrated_boundary(transcript)):
        return

    ledger = os.path.join(cwd, ".claude", "blackboard", session_id, "LEDGER.md")

    # Re-arm watermark thresholds; prefer the ledger path pinned at nudge time
    # (robust against cwd changes between nudge and compaction).
    if transcript:
        key = hashlib.sha1(transcript.encode()).hexdigest()[:16]
        state = os.path.join(STATE_ROOT, key)
        try:
            with open(os.path.join(state, "ledger_path")) as f:
                pinned = f.read().strip()
            if pinned:
                ledger = pinned
        except OSError:
            pass
        # Clear tier sentinels but leave `compacted` for the watermark: it
        # suppresses firing until a genuine low post-compact reading arrives.
        for name in ("t1", "t2", "t3"):
            try:
                os.unlink(os.path.join(state, name))
            except OSError:
                pass
    parts = []
    outcome = "recovery"
    model_age = None
    try:
        model_age = time.time() - os.path.getmtime(ledger)
    except OSError:
        pass
    if model_age is not None and model_age < FRESH_S:
        try:
            body_cap = MAX_LEDGER_BYTES - WRAPPER_RESERVE
            with open(ledger, "rb") as f:
                raw = f.read(body_cap + 1)
            body = raw[:body_cap].decode("utf-8", errors="replace")
            if len(raw) > body_cap:
                body += f"\n[TRUNCATED at {body_cap} bytes — Read {ledger} for the rest]"
            if model_age < 7200:
                trust = (
                    "authoritative pre-compact state, written minutes before "
                    "compaction. Where the compact summary and this ledger disagree, "
                    "trust the ledger."
                )
            else:
                trust = (
                    f"pre-compact state from {int(model_age // 3600)}h ago. Verify it "
                    "against the compact summary; prefer the summary for anything "
                    "it records as newer than the ledger."
                )
            parts.append(
                f"POST-COMPACT REHYDRATION — the session ledger below is {trust} "
                "Verify your next actions against it; do not re-derive established "
                "facts or re-litigate recorded decisions.\n"
                f"--- {ledger} (age {int(model_age // 60)}m) ---\n{body}"
            )
            outcome = "model"
        except OSError:
            pass

    # Mechanical auto-ledger (precompact-recorder writes it at PreCompact):
    # alone when no usable model ledger exists; appended as the final-minutes
    # delta when the model ledger is usable but predates the last stretch.
    auto_path = os.path.join(os.path.dirname(ledger), "LEDGER.auto.md")
    auto_age = None
    try:
        auto_age = time.time() - os.path.getmtime(auto_path)
    except OSError:
        pass
    # Budget counts the FULL emitted parts (wrapper prose included) so the
    # documented total cap is real; when the model block already spent the
    # budget, the auto block is skipped outright — never squeezed in over cap.
    budget = (
        MAX_LEDGER_BYTES
        - sum(len(p.encode("utf-8", "replace")) for p in parts)
        - WRAPPER_RESERVE
    )
    if auto_age is not None and auto_age < AUTO_FRESH_S and budget >= MIN_AUTO_BUDGET and (
        not parts or model_age > MODEL_STALE_FOR_AUTO_S
    ):
        try:
            with open(auto_path, "rb") as f:
                araw = f.read(budget + 1)
            abody = araw[:budget].decode("utf-8", errors="replace")
            if len(araw) > budget:
                abody += f"\n[TRUNCATED — Read {auto_path} for the rest]"
            if parts:
                parts.append(
                    "FINAL-MINUTES AUTO-EXTRACT (mechanical, written at PreCompact — "
                    "newer than the ledger above; use it for what changed at the very end):\n"
                    f"--- {auto_path} (age {int(auto_age // 60)}m) ---\n{abody}"
                )
                outcome = "model+auto"
            else:
                parts.append(
                    "POST-COMPACT REHYDRATION — no model-written session ledger "
                    "existed; below is a MECHANICAL pre-compact extraction "
                    "(deterministic, lower fidelity — treat as evidence and verify "
                    "against the compact summary rather than trusting it blindly).\n"
                    f"--- {auto_path} (age {int(auto_age // 60)}m) ---\n{abody}"
                )
                outcome = "auto"
        except OSError:
            pass

    context = "\n\n".join(parts) if parts else RECOVERY

    if source == "resume" and context == RECOVERY:
        return  # crash-window resume without a usable ledger: stay silent

    _log_outcome(session_id, outcome, model_age, auto_age)

    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "SessionStart",
            "additionalContext": context,
        }
    }))


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass
    sys.exit(0)
