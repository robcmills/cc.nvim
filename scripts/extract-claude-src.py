#!/usr/bin/env python3
"""Extract the bundled JS (and other assets) out of a `claude` Bun binary.

The claude CLI ships as a Bun single-file executable. Its payload holds
JavaScriptCore bytecode *and* the minified JS source for every code-split
chunk, plus embedded assets (skills, READMEs). This script decodes Bun's
module table and writes each module out under its original bundle name,
so you can grep for a protocol field and prettify the chunk that owns it.

Usage:
    scripts/extract-claude-src.py [BINARY] [--out DIR] [--prettier]

BINARY defaults to the resolved `claude` on $PATH. Output defaults to
/tmp/claude-src/<version>/. --prettier runs `npx prettier@3` over every .js
module (a few minutes for ~35 MB of source); without it, prettify chunks
on demand:

    grep -l 'task_notification' /tmp/claude-src/*/*.js
    npx prettier@3 --parser babel /tmp/claude-src/<ver>/chunk-xxxx.js > /tmp/x.js

Format notes (verified against claude 2.1.270, Bun ~1.3): the payload ends
with an Offsets struct then the trailer "---- Bun! ----". Offsets is
u64 byte_count, StringPointer{u32 off, u32 len} modules, i32 entry_point_id.
Each module entry is 52 bytes: five StringPointers (name, contents,
sourcemap, bytecode, extra), a second name pointer, and a u32 of flag
bytes. Pointers are relative to a base a few bytes before the payload; the
script calibrates it by locating the first module's name string.
"""

import argparse
import os
import re
import shutil
import struct
import subprocess
import sys

TRAILER = b"---- Bun! ----"
ENTRY_SIZE = 52
PREFIX = "/$bunfs/root/"


def resolve_binary(arg):
    path = arg or shutil.which("claude")
    if not path:
        sys.exit("claude not found on $PATH; pass the binary path explicitly")
    return os.path.realpath(path)


def read_version(data):
    m = re.search(rb"// Version: (\d+\.\d+\.\d+)", data)
    return m.group(1).decode() if m else "unknown"


def decode_modules(data):
    t = data.rfind(TRAILER)
    if t < 0:
        sys.exit("no Bun trailer found; is this a Bun single-file executable?")
    # Offsets struct sits right before the trailer, followed by a newline.
    byte_count, mods_off, mods_len, entry_id = struct.unpack_from(
        "<QIIi", data, t - 33
    )
    n = mods_len // ENTRY_SIZE
    if n == 0 or mods_len % ENTRY_SIZE:
        sys.exit(f"unexpected module table length {mods_len}; format changed?")

    # Pointers are relative to the start of Bun's byte blob, which sits
    # roughly byte_count bytes before the trailer. Calibrate the exact base
    # by requiring the first entry's name to be a /$bunfs path.
    guess = t - byte_count
    for base in range(max(0, guess - 4096), guess + 4096):
        e = struct.unpack_from("<13I", data, mods_off + base)
        name_off, name_len = e[0], e[1]
        probe = data[name_off + base : name_off + base + name_len]
        if probe.startswith(PREFIX.encode()):
            break
    else:
        sys.exit("could not calibrate pointer base; format changed?")

    mods = []
    for k in range(n):
        e = struct.unpack_from("<13I", data, mods_off + base + k * ENTRY_SIZE)
        name = data[e[0] + base : e[0] + base + e[1]].decode(errors="replace")
        contents = data[e[2] + base : e[2] + base + e[3]]
        mods.append((name, contents))
    entry = mods[entry_id][0] if 0 <= entry_id < n else None
    return mods, entry


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("binary", nargs="?", help="path to claude binary")
    ap.add_argument("--out", help="output dir (default /tmp/claude-src/<version>)")
    ap.add_argument(
        "--prettier", action="store_true", help="run prettier over every .js module"
    )
    ap.add_argument(
        "--assets", action="store_true", help="also write non-.js modules (.md, .zst, ...)"
    )
    args = ap.parse_args()

    binary = resolve_binary(args.binary)
    data = open(binary, "rb").read()
    version = read_version(data)
    out = args.out or f"/tmp/claude-src/{version}"
    os.makedirs(out, exist_ok=True)

    mods, entry = decode_modules(data)
    written = 0
    for name, contents in mods:
        rel = name[len(PREFIX) :] if name.startswith(PREFIX) else name.lstrip("/")
        is_js = rel.endswith(".js") or rel == (entry or "")[len(PREFIX) :]
        if not is_js and not args.assets:
            continue
        if is_js and not rel.endswith(".js"):
            rel += ".js"
        path = os.path.join(out, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "wb") as f:
            f.write(contents.rstrip(b"\x00"))
        written += 1

    js = [f for f in os.listdir(out) if f.endswith(".js")]
    total = sum(os.path.getsize(os.path.join(out, f)) for f in js)
    print(f"binary:  {binary}")
    print(f"version: {version}")
    print(f"entry:   {entry}")
    print(f"wrote:   {written} modules to {out} ({len(js)} .js, {total / 1e6:.1f} MB)")

    if args.prettier:
        print("running prettier over all .js modules...")
        cmd = ["npx", "--yes", "prettier@3", "--parser", "babel", "--write"]
        cmd += [os.path.join(out, f) for f in js]
        subprocess.run(cmd, check=False, stdout=subprocess.DEVNULL)
        print("done")


if __name__ == "__main__":
    main()
