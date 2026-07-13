#!/usr/bin/env python3
"""Canary for the UNDOCUMENTED Claude Code internals the smart-compact system
depends on. Run it after Claude Code updates or wire it into any periodic
checker (cron/launchd): if an update changes these internals it exits 3 and
names the broken assumption — instead of the watermark silently going dark.

Checks (fail = exit 3 with reasons; pass = exit 0):
 1. usage-signal: some recent, reasonably large MAIN transcript yields an
    assistant `message.usage` sum via the same reverse-scan the hooks use.
 2. hooks-alive: any transcript modified in the last hour implies the watermark
    state root exists (UserPromptSubmit/PostToolUse create it on every session).
 3. ceiling-estimator: if the flight log records auto-compactions but the
    watermark's effective-ceiling estimator can't parse occupancy out of them
    (a recorder/log schema drift), the tiers silently revert to the nominal
    fallback — surface it. Manual-only or fresh logs pass silently.
 4. version-note (informational): prints the current binary version so
    failure output names the version that broke the assumption.

Documented APIs (hook events, additionalContext, /compact) are NOT checked —
they are stable surface; this canary covers only the empirically-derived parts.
"""
import glob
import json
import os
import re
import subprocess
import sys
import time

PROJECTS = os.path.expanduser(os.environ.get("CANARY_PROJECTS_ROOT", "~/.claude/projects"))
STATE_ROOT = os.environ.get("CANARY_STATE_ROOT", "/tmp/claude-context-watermark")
EVENTS_LOG = os.path.expanduser(
    os.environ.get("CANARY_EVENTS_LOG", "~/.claude/logs/compact-events.log")
)
MIN_SIZE = 100_000
RECENT_DAYS = 7


def estimator_health():
    """(auto_lines, auto_samples) from the events-log tail, mirroring
    context-watermark.effective_ceiling's own filter. auto_lines counts main
    auto-compaction records; auto_samples counts those the estimator can
    actually read an int occupancy from. auto_lines>=2 with auto_samples<2 is
    the drift signal: the recorder is logging autos but their occupancy field
    is no longer parseable. Returns (0, 0) when the log is absent/unreadable."""
    try:
        size = os.path.getsize(EVENTS_LOG)
        with open(EVENTS_LOG, "rb") as f:
            f.seek(max(0, size - 131072))
            data = f.read().decode("utf-8", errors="replace")
        lines = data.split("\n")
        if size > 131072:
            lines = lines[1:]
    except OSError:
        return (0, 0)
    auto_lines = auto_samples = 0
    for line in lines:
        line = line.strip()
        if not line:
            continue
        try:
            d = json.loads(line)
        except ValueError:
            continue
        if d.get("event") or d.get("agent") or d.get("trigger") != "auto":
            continue
        auto_lines += 1
        if isinstance(d.get("occupancy"), int) and d["occupancy"] > 0:
            auto_samples += 1
    return (auto_lines, auto_samples)


def latest_usage(path):
    try:
        size = os.path.getsize(path)
        n = min(size, 262144)
        with open(path, "rb") as f:
            f.seek(size - n)
            data = f.read(n).decode("utf-8", errors="replace")
    except OSError:
        return None
    for line in reversed(data.split("\n")):
        line = line.strip()
        if not line:
            continue
        try:
            d = json.loads(line)
        except ValueError:
            continue
        if d.get("type") != "assistant" or d.get("isSidechain"):
            continue
        u = d.get("message", {}).get("usage")
        if isinstance(u, dict) and any(k in u for k in ("input_tokens", "cache_read_input_tokens")):
            return sum(u.get(k, 0) for k in ("input_tokens", "output_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"))
    return None


def boot_time():
    """/tmp is wiped at boot: a transcript written just BEFORE a reboot must
    not imply watermark state exists AFTER it. 0 on failure = guard inactive."""
    try:
        out = subprocess.run(["sysctl", "-n", "kern.boottime"],
                             capture_output=True, text=True, timeout=5).stdout
        m = re.search(r"sec\s*=\s*(\d+)", out)
        if m:
            return int(m.group(1))
    except Exception:
        pass
    return 0


def main() -> int:
    now = time.time()
    fails = []

    candidates = []
    for p in glob.glob(os.path.join(PROJECTS, "*", "*.jsonl")):
        try:
            st = os.stat(p)
        except OSError:
            continue
        if st.st_size >= MIN_SIZE and now - st.st_mtime < RECENT_DAYS * 86400:
            candidates.append((st.st_mtime, p))
    candidates.sort(reverse=True)

    if candidates:
        # Judge only the NEWEST 2 by mtime: transcripts last written before a
        # breaking harness update keep valid usage in their tails for days, so
        # a wider any() would mask the break until they age out of the window.
        # Two (not one) tolerates a single transcript whose tail 256KB happens
        # to hold no assistant entry.
        if not any(latest_usage(p) is not None for _, p in candidates[:2]):
            fails.append(f"usage-signal BROKEN: none of the {min(2, len(candidates))} newest large transcripts "
                         "yield assistant message.usage — occupancy/watermark is dark")
        newest_mtime = candidates[0][0]
        if now - newest_mtime < 3600 and newest_mtime > boot_time() and not os.path.isdir(STATE_ROOT):
            fails.append("hooks-alive BROKEN: a session was active within the hour but no watermark state exists — "
                         "hooks may not be firing")
    # No recent large transcripts at all = idle machine, nothing to judge: pass.

    auto_lines, auto_samples = estimator_health()
    if auto_lines >= 2 and auto_samples < 2:
        fails.append(f"ceiling-estimator BROKEN: {auto_lines} auto-compaction records in the flight log "
                     f"but only {auto_samples} yield a parseable occupancy — the effective-ceiling "
                     "estimator has silently reverted to the nominal fallback (recorder/log schema drift)")

    # Newest by mtime, not lexicographic ("2.1.99" would sort above "2.1.201").
    versions = glob.glob(os.path.expanduser("~/.local/share/claude/versions/*"))
    ver = "unknown"
    if versions:
        try:
            ver = os.path.basename(max(versions, key=os.path.getmtime))
        except OSError:
            ver = os.path.basename(sorted(versions)[-1])

    if fails:
        for f in fails:
            print(f"[claude {ver}] {f}")
        return 3
    print(f"harness assumptions OK (claude {ver}, {len(candidates)} recent transcripts checked)")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as e:
        print(f"canary internal error: {e}", file=sys.stderr)
        sys.exit(2)
