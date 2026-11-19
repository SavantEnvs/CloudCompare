#!/usr/bin/env python3
"""Print the compile flags CMake used for one source file (from compile_commands.json),
without the compiler, the source, -o/-c and dependency-file options. The harnesses reuse
the flags of upstream's TestCoreIOFilters.cpp (Qt + qCC_db + qCC_io + qCoreIO include
dirs and defines) so they compile exactly like upstream's own loader tests."""
import json, shlex, sys

cdb, needle = sys.argv[1], sys.argv[2]
for e in json.load(open(cdb)):
    if e["file"].endswith(needle):
        args = e.get("arguments") or shlex.split(e["command"])
        out, skip = [], False
        for a in args[1:]:
            if skip:
                skip = False
                continue
            if a in ("-o", "-c", "-MF", "-MT", "-MQ"):
                skip = True
                continue
            if a in ("-MD", "-MMD") or a == e["file"]:
                continue
            out.append(a)
        print(" ".join(shlex.quote(a) for a in out))
        sys.exit(0)
sys.exit("no compile command for " + needle)
