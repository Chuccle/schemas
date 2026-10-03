#!/usr/bin/env python3
"""Fail when a behaviour in contract.json has no test that claims to check it.

    python3 tools/check_traceability.py --checker server-rs --root ../src --root ../tests

A test claims a behaviour with a `contract: B04` tag in a comment next to it
(any file type; several IDs may follow one tag: `contract: B01 B02`). Every
behaviour whose status is "enforced" and whose checked_by lists --checker must
be claimed at least once under the given roots, and every claimed ID must exist.

Run from the consuming repo against its pinned submodule, so the requirement
is always the contract version that repo actually builds against.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

TAG = re.compile(r"contract:((?:\s+B\d{2})+)")
SUFFIXES = {".rs", ".c", ".h", ".cpp", ".hpp", ".ps1", ".py"}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--checker", required=True, help="name as it appears in checked_by")
    parser.add_argument("--root", action="append", required=True, help="directory to scan (repeatable)")
    parser.add_argument("--contract", default=str(Path(__file__).resolve().parent.parent / "contract.json"))
    args = parser.parse_args()

    contract = json.loads(Path(args.contract).read_text(encoding="utf-8"))
    behaviours = {b["id"]: b for b in contract["behaviours"]}

    claimed: dict[str, list[str]] = {}
    for root in args.root:
        for path in sorted(Path(root).rglob("*")):
            if path.suffix.lower() not in SUFFIXES or not path.is_file():
                continue
            text = path.read_text(encoding="utf-8", errors="replace")
            for lineno, line in enumerate(text.splitlines(), 1):
                for match in TAG.finditer(line):
                    for bid in match.group(1).split():
                        claimed.setdefault(bid, []).append("%s:%d" % (path, lineno))

    problems = []
    for bid, where in sorted(claimed.items()):
        if bid not in behaviours:
            problems.append("%s claimed at %s is not in contract.json" % (bid, where[0]))

    for bid, b in behaviours.items():
        required = b["status"] == "enforced" and args.checker in b["checked_by"]
        if required and bid not in claimed:
            problems.append("%s (%s) must be checked by %s but no test is tagged `contract: %s`" % (
                bid, b["title"], args.checker, bid))
        elif bid in claimed:
            print("%s  %-60s %s" % (bid, b["title"][:60], claimed[bid][0]))

    if problems:
        for p in problems:
            print("::error::" + p, file=sys.stderr)
        return 1

    print("every behaviour %s is responsible for is covered (contract v%d.%d)" % (
        args.checker, contract["version"]["major"], contract["version"]["minor"]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
