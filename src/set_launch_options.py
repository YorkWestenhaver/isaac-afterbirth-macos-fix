#!/usr/bin/env python3
"""
set_launch_options.py -- safely set (or clear) a Steam game's Launch Options by
surgically editing localconfig.vdf, without needing Steam's UI.

Steam must be CLOSED when this runs (Steam rewrites localconfig.vdf on exit and
would clobber the change otherwise). The installer handles quitting Steam.

Safety: makes a timestamped backup first, edits only the target app's
"LaunchOptions" field via a brace-matched surgical text edit (never reformats
the rest of the file), then verifies the result before keeping it. On any
anomaly it restores the backup and exits non-zero so the caller can fall back
to manual instructions.

Usage:
    set_launch_options.py --appid 250900 --value '"/path/wrapper.sh" %command%'
    set_launch_options.py --appid 250900 --clear

Exit codes:
    0  success (at least one config updated)
    3  couldn't do it safely -> caller should print manual instructions
    2  bad arguments
"""
import argparse
import glob
import os
import shutil
import sys
import time


def find_kv_block(text, key_quoted, start=0):
    """Find a `"key" { ... }` block. Returns (key_idx, brace_open_idx,
    brace_close_idx) or None. Only matches when the key is immediately followed
    (ignoring whitespace) by a `{`, so it won't match the key appearing as a
    plain value."""
    idx = text.find(key_quoted, start)
    while idx != -1:
        k = idx + len(key_quoted)
        while k < len(text) and text[k] in " \t\r\n":
            k += 1
        if k < len(text) and text[k] == "{":
            depth = 0
            m = k
            while m < len(text):
                c = text[m]
                if c == "{":
                    depth += 1
                elif c == "}":
                    depth -= 1
                    if depth == 0:
                        return (idx, k, m)
                m += 1
            return None
        idx = text.find(key_quoted, k)
    return None


def vdf_escape(value):
    return value.replace("\\", "\\\\").replace('"', '\\"')


def find_launchoptions_value_span(block_text):
    """Within a block, find the span of the VALUE of "LaunchOptions" (the text
    between its surrounding quotes), returning (val_start, val_end) offsets
    relative to block_text, or None. Handles escaped quotes in the value."""
    key = '"LaunchOptions"'
    p = block_text.find(key)
    if p == -1:
        return None
    q = p + len(key)
    # skip whitespace to the opening quote of the value
    while q < len(block_text) and block_text[q] in " \t":
        q += 1
    if q >= len(block_text) or block_text[q] != '"':
        return None
    val_start = q + 1
    r = val_start
    while r < len(block_text):
        if block_text[r] == "\\":
            r += 2
            continue
        if block_text[r] == '"':
            return (val_start, r)
        r += 1
    return None


def set_in_text(text, appid, escaped_value):
    """Return (new_text, 'replaced'|'inserted') or None if the app block or a
    safe insertion point wasn't found."""
    blk = find_kv_block(text, '"%s"' % appid)
    if blk is None:
        return None
    _, bo, bc = blk
    block_text = text[bo : bc + 1]
    span = find_launchoptions_value_span(block_text)
    if span is not None:
        vs, ve = span
        new_block = block_text[:vs] + escaped_value + block_text[ve:]
        return (text[:bo] + new_block + text[bc + 1 :], "replaced")
    # No LaunchOptions yet -> insert a line right after the opening brace.
    # Derive indentation from the line the closing brace sits on, + one tab.
    line_start = text.rfind("\n", 0, bc) + 1
    close_indent = ""
    for ch in text[line_start:bc]:
        if ch in " \t":
            close_indent += ch
        else:
            break
    indent = close_indent + "\t"
    newline_after_brace = "\n" if (bo + 1 < len(text) and text[bo + 1] != "\n") else ""
    insertion = "\n" + indent + '"LaunchOptions"\t\t"' + escaped_value + '"' + newline_after_brace
    return (text[: bo + 1] + insertion + text[bo + 1 :], "inserted")


def verify(new_text, old_text, appid, expected_escaped):
    # brace balance must be unchanged
    if new_text.count("{") != old_text.count("{"):
        return False, "brace-open count changed"
    if new_text.count("}") != old_text.count("}"):
        return False, "brace-close count changed"
    blk = find_kv_block(new_text, '"%s"' % appid)
    if blk is None:
        return False, "app block missing after edit"
    _, bo, bc = blk
    span = find_launchoptions_value_span(new_text[bo : bc + 1])
    if span is None:
        return False, "LaunchOptions missing after edit"
    vs, ve = span
    got = new_text[bo:bc + 1][vs:ve]
    if got != expected_escaped:
        return False, "value mismatch after edit"
    return True, "ok"


def candidate_configs():
    base = os.path.expanduser(
        "~/Library/Application Support/Steam/userdata"
    )
    paths = glob.glob(os.path.join(base, "*", "config", "localconfig.vdf"))
    # newest first (most likely the active account)
    paths.sort(key=lambda p: os.path.getmtime(p), reverse=True)
    return paths


def process_one(path, appid, escaped_value, expected_stored):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            old = f.read()
    except OSError as e:
        return False, "could not read: %s" % e

    result = set_in_text(old, appid, escaped_value)
    if result is None:
        return False, "app %s not found in this config" % appid
    new, how = result

    ok, why = verify(new, old, appid, expected_stored)
    if not ok:
        return False, "verification failed (%s)" % why

    backup = "%s.bak-%s" % (path, time.strftime("%Y%m%d-%H%M%S"))
    shutil.copy2(path, backup)
    try:
        with open(path, "w", encoding="utf-8") as f:
            f.write(new)
    except OSError as e:
        shutil.copy2(backup, path)
        return False, "write failed, restored backup: %s" % e
    return True, "%s (backup: %s)" % (how, os.path.basename(backup))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--appid", required=True)
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--value")
    g.add_argument("--clear", action="store_true")
    ap.add_argument("--config", help="explicit localconfig.vdf path")
    args = ap.parse_args()

    value = "" if args.clear else args.value
    escaped = vdf_escape(value)

    configs = [args.config] if args.config else candidate_configs()
    if not configs:
        print("No Steam localconfig.vdf found.", file=sys.stderr)
        sys.exit(3)

    any_ok = False
    updated_paths = []
    for path in configs:
        ok, msg = process_one(path, args.appid, escaped, escaped)
        tag = "OK  " if ok else "skip"
        print("[%s] %s -> %s" % (tag, path, msg))
        if ok:
            any_ok = True
            updated_paths.append(path)

    if any_ok:
        print("\nLaunch Options %s for app %s in %d config(s)."
              % ("cleared" if args.clear else "set", args.appid, len(updated_paths)))
        sys.exit(0)
    else:
        print("\nCould not set Launch Options automatically.", file=sys.stderr)
        sys.exit(3)


if __name__ == "__main__":
    main()
