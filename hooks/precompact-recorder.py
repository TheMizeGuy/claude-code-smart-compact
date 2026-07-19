#!/usr/bin/env python3
"""PreCompact flight recorder (matchers: manual + auto). Notification-only.

1. Appends {ts, session_id, trigger, occupancy, ledger_present} to
   the events log (~/.claude/logs/compact-events.log, or $COMPACT_EVENTS_LOG —
   tests MUST redirect or they pollute the flight data the watermark's
   effective-ceiling estimator learns from). Rotates the log at 1MB.
2. Snapshots the session ledger to LEDGER.pre-compact-<ts>.md if present
   (keeps the newest 3 snapshots per session).
3. Writes LEDGER.auto.md — a deterministic transcript extraction (goal, last
   user messages, files edited, last assistant text, last error, git state) —
   whenever the model-written ledger is missing or stale. PreCompact is the
   only moment that both sees the full pre-compact transcript and precedes
   EVERY compaction, manual included; low-occupancy manual compacts never get
   a nudge, so without this they rehydrate from nothing.
4. Stamps `compacted` in the watermark state dir so context-watermark.py
   re-arms its thresholds for the next fill cycle.
5. Spawns a detached boundary VERIFIER: PreCompact fires before the summarize
   model call, which fails outright at usage-limit exhaustion ("Error during
   compaction" — no boundary ever lands). If no compact_boundary appears in
   the bytes appended after this event within COMPACT_VERIFY_DELAY_S, the
   compaction FAILED: the verifier voids the `compacted` stamp AND the
   t1/t2/t3 sentinels so watermark nudges re-arm (the retry loop) instead of
   staying muted for the rest of the fill cycle, and logs a
   compact-verify-failed event.

Never blocks compaction (it can't — PreCompact is notification-only) and
never errors: every failure path exits 0.
"""
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import time

LOG = os.environ.get("COMPACT_EVENTS_LOG") or os.path.expanduser(
    "~/.claude/logs/compact-events.log"
)
STATE_ROOT = "/tmp/claude-context-watermark"
KEEP_SNAPSHOTS = 3
AUTO_LEDGER_MAX = 6144
MODEL_LEDGER_FRESH_S = 1200  # fresh model ledger => skip the mechanical extract
TAIL_BYTES = 4 * 1024 * 1024
EDIT_TOOLS = {"Edit", "Write", "NotebookEdit", "MultiEdit"}
SYMBOL_EDIT_HINTS = (
    "replace_symbol_body",
    "insert_after_symbol",
    "insert_before_symbol",
    "rename_symbol",
    "replace_content",
    "safe_delete_symbol",
    "replace_in_files",
)


def latest_usage_tokens(path):
    # Returns (usage_sum, model) — model read from the SAME assistant entry
    # the occupancy came from (None when absent), so flight lines are
    # per-model attributable. Scan logic kept in sync with the copy in
    # context-watermark.py, which returns only the sum. Skips isSidechain
    # entries — see the note there.
    try:
        size = os.path.getsize(path)
    except OSError:
        return None, None
    n = min(size, 262144)
    try:
        with open(path, "rb") as f:
            f.seek(size - n)
            data = f.read(n).decode("utf-8", errors="replace")
    except OSError:
        return None, None
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
        if d.get("type") == "system" and d.get("subtype") == "compact_boundary":
            return None, None
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
        ), d.get("message", {}).get("model")
    return None, None


def _text_of(content):
    """Plain text of a message content field (str or block list)."""
    if isinstance(content, str):
        return content
    parts = []
    if isinstance(content, list):
        for b in content:
            if isinstance(b, dict) and b.get("type") == "text":
                parts.append(b.get("text") or "")
    return "\n".join(parts)


def _clip(s, n):
    s = " ".join((s or "").split())
    return s if len(s) <= n else s[: n - 1] + "…"


def _git_facts(cwd):
    facts = []
    try:
        br = subprocess.run(
            ["git", "-C", cwd, "rev-parse", "--abbrev-ref", "HEAD"],
            capture_output=True, text=True, timeout=2,
        )
        if br.returncode == 0 and br.stdout.strip():
            facts.append(f"branch: {br.stdout.strip()}")
        st = subprocess.run(
            ["git", "-C", cwd, "status", "--porcelain"],
            capture_output=True, text=True, timeout=2,
        )
        if st.returncode == 0:
            dirty = [l for l in st.stdout.splitlines() if l.strip()]
            facts.append(f"dirty files: {len(dirty)}")
            facts.extend(f"  {l}" for l in dirty[:8])
    except Exception:
        pass
    return facts


def build_auto_ledger(transcript, cwd, session_id, trigger, occ):
    """Deterministic pre-compact extraction — the floor under the model ledger.

    Everything here is mechanical (no summarization): verbatim-ish last user
    messages, the active /goal, files edited, the last assistant text, the
    last tool error, git state. Lower fidelity than a model-written ledger,
    strictly better than the generic recovery text.
    """
    users, files, memids = [], [], []
    goal_box, asst_box, err_box = [None], [None], [None]
    flag_box = [False, 0]  # [commits_seen, boundary_count]
    lines = []
    if transcript:
        try:
            size = os.path.getsize(transcript)
            with open(transcript, "rb") as f:
                f.seek(max(0, size - TAIL_BYTES))
                data = f.read().decode("utf-8", errors="replace")
            lines = data.split("\n")
            if size > TAIL_BYTES:
                lines = lines[1:]
        except OSError:
            lines = []
    for line in lines:
        line = line.strip()
        if not line:
            continue
        try:
            d = json.loads(line)
        except ValueError:
            continue
        try:
            _consume_entry(
                d, users, files, memids, goal_box, asst_box, err_box, flag_box,
            )
        except Exception:
            # One malformed-shaped entry must never abort the whole
            # extraction — the floor exists precisely for messy inputs.
            continue
    goal, last_asst, last_err = goal_box[0], asst_box[0], err_box[0]
    commits, boundaries = flag_box[0], flag_box[1]
    users = users[-3:]
    files = files[-20:]
    memids = memids[-6:]

    # A transcript with none of the substantive fields (e.g. an all-sidechain
    # subagent file, or a brand-new session) yields only a header stub — worse
    # than nothing, since the rehydrator would inject the empty stub instead of
    # falling through to the model ledger / recovery. Signal "no content" so
    # main() skips the write entirely.
    if not (goal or users or files or last_asst or last_err or memids):
        return ""

    out = [
        "# AUTO-LEDGER (deterministic pre-compact extraction — mechanical, "
        "lower fidelity than a model-written ledger)",
        f"session: {session_id} | trigger: {trigger} | occupancy: {occ} | "
        f"extracted: {time.strftime('%Y-%m-%dT%H:%M:%S%z')}",
        f"cwd: {cwd}",
    ]
    out += _git_facts(cwd)
    if boundaries:
        out.append(f"note: {boundaries} earlier compact boundary(ies) inside the scanned tail")
    if goal:
        out += ["", "## Active /goal", goal]
    if users:
        out += ["", "## Last user messages (oldest first)"]
        out += [f"- {u}" for u in users]
    if last_asst:
        out += ["", "## Last assistant text (pre-compact)", last_asst]
    if files:
        out += ["", "## Files edited (oldest first, deduped)"]
        out += [f"- {p}" for p in files]
        if commits:
            out.append("(at least one `git commit` ran — check `git log` before assuming work is uncommitted)")
    if memids:
        out += ["", "## Memory writes (memory-tool IDs, most recent last)"]
        out += [f"- {mid}" for mid in memids]
    if last_err:
        out += ["", "## Last tool error", last_err]
    doc = "\n".join(out) + "\n"
    raw_doc = doc.encode("utf-8", "replace")
    if len(raw_doc) > AUTO_LEDGER_MAX:
        doc = raw_doc[:AUTO_LEDGER_MAX].decode("utf-8", "replace") + "\n[TRUNCATED]\n"
    return doc


MEMID_RE = re.compile(r'"memoryId"\s*:\s*"([0-9a-fA-F-]{20,})"')
# Unescaped SYSTEM-entry shape only: quoted mentions inside JSON strings carry
# \"-escaped quotes and must not count (see docs/ARCHITECTURE.md on escaped mentions).
BOUNDARY_RE = re.compile(r'"subtype"\s*:\s*"compact_boundary"')
# Longest observed send-to-boundary lag is ~6m20s; 600s matches the
# self-compact watcher's own boundary timeout. A false "failed" verdict after
# a slow SUCCESS only re-arms sentinels the rehydrator already cleared.
VERIFY_DELAY_S = 600
# The auto-compaction summary the harness injects as a user-role message after
# a prior compaction — a genuine typed prompt never opens with this. Left
# unfiltered it eats a scarce user-message slot AND duplicates the summary the
# rehydrator already carries (observed on a real transcript).
CONTINUATION_PREFIX = "This session is being continued from a previous conversation"


def _consume_entry(d, users, files, memids, goal_box, asst_box, err_box, flag_box):
    """Field extraction for one transcript entry (mutates the accumulators).
    Split out so build_auto_ledger can guard each entry independently."""
    if d.get("isSidechain"):
        return
    t = d.get("type")
    if t == "system" and d.get("subtype") == "compact_boundary":
        flag_box[1] += 1
        return
    content = (d.get("message") or {}).get("content")
    if t == "user":
        raw = _text_of(content)
        if "<command-name>/goal</command-name>" in raw:
            m = re.search(r"<command-args>(.*?)</command-args>", raw, re.S)
            if m and m.group(1).strip():
                goal_box[0] = _clip(m.group(1), 300)
        if isinstance(content, list):
            for b in content:
                if isinstance(b, dict) and b.get("type") == "tool_result":
                    rtext = _text_of(b.get("content"))
                    if b.get("is_error"):
                        err_box[0] = _clip(rtext, 400)
                    # goodmem CREATE/UPDATE results carry `processingStatus`
                    # alongside memoryId; RETRIEVE results carry memoryId too
                    # but never processingStatus (they have relevanceScore/
                    # chunkId). Gating on processingStatus keeps this a true
                    # "Memory writes" list — a post-compact model must not
                    # think it wrote a memory it only read.
                    if "processingStatus" in rtext:
                        for mid in MEMID_RE.findall(rtext):
                            if mid not in memids:
                                memids.append(mid)
        if d.get("isMeta"):
            return
        stripped = raw.strip()
        # Skip harness wrappers (local-command/system-reminder XML, the
        # local-command caveat, the post-compaction summary) — only genuine
        # typed prompts belong here.
        if (
            not stripped
            or stripped.startswith("<")
            or stripped.startswith("Caveat:")
            or stripped.startswith(CONTINUATION_PREFIX)
        ):
            return
        users.append(_clip(stripped, 400))
    elif t == "assistant":
        txt = _text_of(content)
        if txt.strip():
            asst_box[0] = _clip(txt, 700)
        if isinstance(content, list):
            for b in content:
                if not (isinstance(b, dict) and b.get("type") == "tool_use"):
                    continue
                name = b.get("name") or ""
                inp = b.get("input")
                if not isinstance(inp, dict):
                    # A truthy non-dict input (malformed line) must skip THIS
                    # block, not detonate the whole extraction.
                    inp = {}
                path = None
                if name in EDIT_TOOLS:
                    path = inp.get("file_path") or inp.get("notebook_path")
                elif any(h in name for h in SYMBOL_EDIT_HINTS):
                    path = inp.get("relative_path")
                elif name == "Bash" and "git commit" in (inp.get("command") or ""):
                    flag_box[0] = True
                if path:
                    if path in files:
                        files.remove(path)
                    files.append(path)


def main():
    event = json.load(sys.stdin)
    session_id = event.get("session_id") or "unknown-session"
    cwd = event.get("cwd") or os.getcwd()
    transcript = event.get("transcript_path") or ""
    ts = time.strftime("%Y-%m-%dT%H:%M:%S%z")
    # Subagent lifecycle events carry agent_id/agent_type with the PARENT's
    # session_id + transcript (verified 2026-07-05): log those for
    # observability but never touch the parent's ledger or re-arm stamp.
    is_agent = bool(event.get("agent_id") or event.get("agent_type"))

    key = hashlib.sha1(transcript.encode()).hexdigest()[:16] if transcript else None
    state = os.path.join(STATE_ROOT, key) if key else None

    ledger = os.path.join(cwd, ".claude", "blackboard", session_id, "LEDGER.md")
    if state:  # prefer the path pinned by context-watermark.py at nudge time
        try:
            with open(os.path.join(state, "ledger_path")) as f:
                pinned = f.read().strip()
            if pinned:
                ledger = pinned
        except OSError:
            pass
    ledger_dir = os.path.dirname(ledger)
    ledger_present = os.path.isfile(ledger)
    if ledger_present and not is_agent:
        try:
            shutil.copy2(ledger, os.path.join(ledger_dir, f"LEDGER.pre-compact-{int(time.time())}.md"))
            snaps = sorted(f for f in os.listdir(ledger_dir) if f.startswith("LEDGER.pre-compact-"))
            for old in snaps[:-KEEP_SNAPSHOTS]:
                os.unlink(os.path.join(ledger_dir, old))
        except OSError:
            pass

    occ, model = latest_usage_tokens(transcript) if transcript else (None, None)

    # Deterministic floor: when the model didn't (or couldn't) checkpoint,
    # write the mechanical extract so the rehydrator has something real.
    # auto_status lands in the flight-log line so a failing extractor is
    # distinguishable from a correctly-skipped one when auditing outcomes.
    auto_status = "skipped-agent"
    if not is_agent:
        fresh_model = False
        if ledger_present:
            try:
                fresh_model = time.time() - os.path.getmtime(ledger) < MODEL_LEDGER_FRESH_S
            except OSError:
                pass
        if fresh_model:
            auto_status = "skipped-fresh-model"
        else:
            try:
                doc = build_auto_ledger(
                    transcript, cwd, session_id, event.get("trigger", ""), occ,
                )
                if doc:
                    os.makedirs(ledger_dir, exist_ok=True)
                    with open(os.path.join(ledger_dir, "LEDGER.auto.md"), "w") as f:
                        f.write(doc)
                    auto_status = "written"
                else:
                    # No substantive content extracted — leave no stub so the
                    # rehydrator falls through to the model ledger / recovery.
                    auto_status = "skipped-empty"
            except Exception as e:
                auto_status = f"error:{type(e).__name__}"

    try:
        os.makedirs(os.path.dirname(LOG), exist_ok=True)
        try:
            if os.path.getsize(LOG) > 1048576:
                os.replace(LOG, LOG + ".1")
        except OSError:
            pass
        with open(LOG, "a") as f:
            f.write(json.dumps({
                "ts": ts,
                "session_id": session_id,
                "trigger": event.get("trigger", ""),
                "occupancy": occ,
                "model": model,
                "ledger_present": ledger_present,
                "agent": is_agent,
                "auto_ledger": auto_status,
            }) + "\n")
    except OSError:
        pass

    if state and not is_agent:
        try:
            os.makedirs(state, exist_ok=True)
            open(os.path.join(state, "compacted"), "w").close()
        except OSError:
            pass
        # Detached verifier (item 5 in the module docstring). The size captured
        # HERE is the pre-summarize baseline: everything the compaction (or its
        # failure) produces lands after it.
        try:
            pre_size = os.path.getsize(transcript)
            subprocess.Popen(
                [sys.executable, os.path.abspath(__file__), "--verify-boundary",
                 transcript, str(pre_size), state, session_id],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                stdin=subprocess.DEVNULL, start_new_session=True,
            )
        except Exception:
            pass


def verify_boundary(transcript, pre_size, state, session_id):
    """Detached: decide success/failure of the compaction announced by the
    PreCompact that spawned us, by whether a boundary landed after pre_size."""
    time.sleep(int(os.environ.get("COMPACT_VERIFY_DELAY_S", VERIFY_DELAY_S)))
    try:
        size = os.path.getsize(transcript)
    except OSError:
        return
    if size < pre_size:
        # Rotated/replaced transcript: success is undecidable — do nothing
        # rather than risk clearing a healthy cycle's state.
        return
    try:
        with open(transcript, "rb") as f:
            f.seek(pre_size)
            data = f.read().decode("utf-8", errors="replace")
    except OSError:
        return
    if BOUNDARY_RE.search(data):
        return
    for name in ("compacted", "t1", "t2", "t3"):
        try:
            os.unlink(os.path.join(state, name))
        except OSError:
            pass
    try:
        with open(LOG, "a") as f:
            f.write(json.dumps({
                "ts": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
                "session_id": session_id,
                "event": "compact-verify-failed",
                "pre_size": pre_size,
            }) + "\n")
    except OSError:
        pass


if __name__ == "__main__":
    if len(sys.argv) >= 6 and sys.argv[1] == "--verify-boundary":
        try:
            verify_boundary(sys.argv[2], int(sys.argv[3]), sys.argv[4], sys.argv[5])
        except Exception:
            pass
        sys.exit(0)
    try:
        main()
    except Exception:
        pass
    sys.exit(0)
