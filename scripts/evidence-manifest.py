#!/usr/bin/env python3
"""Validate the post-B5 evidence manifests — patch 438, ADR-0003 §12.193.

WHY THIS EXISTS
---------------
The runbook's later tasks say things like "starts only after an accepted 0A
artifact" and "record one accepted Task 0 handoff manifest". A manifest that
nothing evaluates is a sentence in a file: it can name a predecessor that was
revised underneath it, hash evidence that has since changed, or claim
`accepted` with nobody's name against it, and every one of those reads exactly
like an accepted handoff.

So the manifests are machine-evaluable, and the four failures the runbook names
by hand — invalid, missing, stale, circular — are each a fixture in
`docs/evidence/post-b5/fixtures/`, driven by `scripts/selftest-evidence.sh`.
A guard that cannot fail has not been tested (§12.69).

THE ONE THING IT REFUSES TO GUESS
---------------------------------
`tree.digest` is the digest of the implementation tree the evidence was taken
against. It can only be RECOMPUTED when the checkout is standing on the commit
the manifest names — any other commit and the answer would be about a tree
nobody tested. So it says which of *recomputed and matched*, *recomputed and
DIFFERED* or *not recomputed, because HEAD is <other>* happened, and
`--require-recompute` turns the third into a failure for the acceptance run.
A checker that cannot say why it has no answer will be read as having one
(§12.15).
"""

from __future__ import annotations

import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path

SCHEMA_VERSIONS = {1}

HEX40 = re.compile(r"^[0-9a-f]{40}$")
HEX64 = re.compile(r"^[0-9a-f]{64}$")
UTC = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")
SLUG = re.compile(r"^[a-z0-9]+(-[a-z0-9]+)*$")

# The implementation tree a manifest's digest is taken over. Documents and
# evidence are deliberately absent: a manifest records evidence by hash
# already, and including the manifests would make the digest self-referential.
TREE_ROOTS = ("Sub4", "Sub4CoreTests", "scripts")
TREE_SUFFIXES = (".swift", ".py", ".sh")


def sha256_of(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 16), b""):
            h.update(chunk)
    return h.hexdigest()


def repo_root() -> Path:
    return Path(__file__).resolve().parent.parent


def tree_digest(root: Path) -> str:
    """A digest of the implementation tree, and it does not depend on git.

    Sorted (relative path, content hash) pairs, hashed as text. Two checkouts
    of the same sources agree whether or not either is a repository.
    """
    entries = []
    for name in TREE_ROOTS:
        base = root / name
        if not base.is_dir():
            continue
        for p in sorted(base.rglob("*")):
            if p.is_file() and p.suffix in TREE_SUFFIXES:
                entries.append((p.relative_to(root).as_posix(), sha256_of(p)))
    entries.sort()
    h = hashlib.sha256()
    for rel, digest in entries:
        h.update(f"{rel} {digest}\n".encode())
    return h.hexdigest()


def head_commit(root: Path) -> str | None:
    try:
        out = subprocess.run(["git", "-C", str(root), "rev-parse", "HEAD"],
                             capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.SubprocessError):
        return None
    sha = out.stdout.strip()
    return sha if out.returncode == 0 and HEX40.match(sha) else None


# --- the shape --------------------------------------------------------------

def _obj(problems, where, value, required: dict, optional: dict | None = None):
    """Check an object's keys exhaustively — BOTH directions.

    A missing key and an unknown key are the same defect seen from either end:
    one is a fact the manifest failed to state, the other is a fact nobody
    reads. §12.129 — a join checked in one direction is unchecked in the other.
    """
    optional = optional or {}
    if not isinstance(value, dict):
        problems.append(f"{where}: expected an object, got {type(value).__name__}")
        return False
    for key in required:
        if key not in value:
            problems.append(f"{where}: missing required key '{key}'")
    for key in value:
        if key not in required and key not in optional:
            problems.append(f"{where}: unknown key '{key}'")
    ok = True
    for key, check in {**required, **optional}.items():
        if key in value:
            message = check(value[key])
            if message:
                problems.append(f"{where}.{key}: {message}")
                ok = False
    return ok


def is_str(v):
    return None if isinstance(v, str) and v.strip() else "must be a non-empty string"


def is_int(v):
    return None if isinstance(v, int) and not isinstance(v, bool) else "must be an integer"


def matches(pattern, what):
    def check(v):
        if not isinstance(v, str):
            return "must be a string"
        return None if pattern.match(v) else f"must be {what}, got {v!r}"
    return check


def is_list(v):
    return None if isinstance(v, list) else "must be a list"


def read_manifest(path: Path, problems: list[str]):
    try:
        raw = path.read_text()
    except OSError as e:
        problems.append(f"cannot be read: {e}")
        return None
    try:
        return json.loads(raw)
    except json.JSONDecodeError as e:
        problems.append(f"is not valid JSON: {e}")
        return None


def check_shape(m, path: Path, problems: list[str]) -> None:
    required = {
        "schemaVersion": is_int,
        "id": matches(SLUG, "a kebab-case slug"),
        "task": is_str,
        "title": is_str,
        "status": lambda v: None if v in ("draft", "accepted", "blocked")
                  else "must be draft, accepted or blocked",
        "owner": is_str,
        "capturedUTC": matches(UTC, "YYYY-MM-DDTHH:MM:SSZ"),
        "approval": lambda v: None,          # shaped below, because it may be null
        "predecessors": is_list,
        "tree": lambda v: None,
        "binding": lambda v: None,
        "evidence": is_list,
    }
    _obj(problems, "manifest", m, required, {"notes": is_str})
    if not isinstance(m, dict):
        return

    if m.get("schemaVersion") not in SCHEMA_VERSIONS:
        problems.append(
            f"schemaVersion {m.get('schemaVersion')!r} is not one this validator knows "
            f"({sorted(SCHEMA_VERSIONS)}) — a manifest from another version is not "
            "machine-evaluable here and must not be treated as accepted")

    if m.get("id") != path.stem:
        problems.append(f"id {m.get('id')!r} does not match the filename stem {path.stem!r}")

    # STATUS AND OWNER. `accepted` is the word every later task keys off, so it
    # is the one word that may not be self-asserted.
    approval = m.get("approval")
    if m.get("status") == "accepted":
        if approval is None:
            problems.append("status is 'accepted' with no approval — "
                            "an acceptance nobody signed is not an acceptance")
        else:
            _obj(problems, "approval", approval,
                 {"by": is_str, "atUTC": matches(UTC, "YYYY-MM-DDTHH:MM:SSZ"),
                  "statement": is_str})
            if isinstance(approval, dict) and approval.get("by") != m.get("owner"):
                problems.append(f"approval.by {approval.get('by')!r} is not the "
                                f"owner {m.get('owner')!r}")
    elif approval is not None:
        problems.append(f"status is {m.get('status')!r} but an approval is recorded")

    if isinstance(m.get("tree"), dict) or "tree" in m:
        _obj(problems, "tree", m.get("tree"),
             {"commit": matches(HEX40, "a 40-character commit sha"),
              "patch": is_int,
              "digest": matches(HEX64, "a 64-character sha256")})

    if "binding" in m:
        _obj(problems, "binding", m.get("binding"),
             {"commit": matches(HEX40, "a 40-character commit sha"),
              "signature": lambda v: None})
        b = m.get("binding")
        if isinstance(b, dict):
            _obj(problems, "binding.signature", b.get("signature"),
                 {"kind": is_str, "value": is_str})
            t = m.get("tree")
            if isinstance(t, dict) and b.get("commit") != t.get("commit"):
                problems.append(f"binding.commit {b.get('commit')!r} names a different "
                                f"commit from tree.commit {t.get('commit')!r}")

    for i, p in enumerate(m.get("predecessors") or []):
        _obj(problems, f"predecessors[{i}]", p,
             {"id": matches(SLUG, "a kebab-case slug"),
              "sha256": matches(HEX64, "a 64-character sha256")})

    ev = m.get("evidence")
    if isinstance(ev, list):
        if not ev:
            problems.append("evidence is empty — a manifest citing nothing proves nothing")
        seen = set()
        for i, e in enumerate(ev):
            _obj(problems, f"evidence[{i}]", e,
                 {"path": is_str, "sha256": matches(HEX64, "a 64-character sha256"),
                  "bytes": is_int})
            if isinstance(e, dict) and isinstance(e.get("path"), str):
                rel = e["path"]
                if rel.startswith("/") or ".." in Path(rel).parts:
                    problems.append(f"evidence[{i}].path {rel!r} must be relative to the "
                                    "manifest's own directory and may not climb out of it")
                if rel in seen:
                    problems.append(f"evidence[{i}].path {rel!r} is listed twice")
                seen.add(rel)


def check_evidence(m, path: Path, problems: list[str]) -> None:
    """MISSING and STALE, and they are different answers."""
    for i, e in enumerate(m.get("evidence") or []):
        if not isinstance(e, dict) or not isinstance(e.get("path"), str):
            continue
        target = (path.parent / e["path"]).resolve()
        if not target.is_file():
            problems.append(f"evidence[{i}] {e['path']!r} is MISSING")
            continue
        actual = sha256_of(target)
        size = target.stat().st_size
        if isinstance(e.get("sha256"), str) and actual != e["sha256"]:
            problems.append(f"evidence[{i}] {e['path']!r} is STALE — recorded "
                            f"{e['sha256'][:12]}…, on disk {actual[:12]}…")
        if isinstance(e.get("bytes"), int) and size != e["bytes"]:
            problems.append(f"evidence[{i}] {e['path']!r} is STALE — recorded "
                            f"{e['bytes']} bytes, on disk {size}")


def check_predecessors(manifests: dict, problems_by_id: dict) -> None:
    """MISSING, STALE and CIRCULAR predecessors.

    A predecessor is recorded as an id AND the hash of that manifest file, so a
    predecessor revised underneath a manifest that cites it is a detectable
    fact rather than a silent one.
    """
    for mid, (path, m, _) in manifests.items():
        problems = problems_by_id[mid]
        for i, p in enumerate(m.get("predecessors") or []):
            if not isinstance(p, dict) or not isinstance(p.get("id"), str):
                continue
            pid = p["id"]
            if pid == mid:
                problems.append(f"predecessors[{i}] names itself")
                continue
            if pid not in manifests:
                problems.append(f"predecessors[{i}] {pid!r} is MISSING — no manifest "
                                "with that id was given to this run")
                continue
            actual = sha256_of(manifests[pid][0])
            if isinstance(p.get("sha256"), str) and actual != p["sha256"]:
                problems.append(f"predecessors[{i}] {pid!r} is STALE — it was revised "
                                f"after this manifest cited it (recorded "
                                f"{p['sha256'][:12]}…, on disk {actual[:12]}…)")

    # CIRCULAR. Reported against every manifest on the cycle, because from any
    # one of them the chain is equally unusable.
    edges = {mid: [p["id"] for p in (m.get("predecessors") or [])
                   if isinstance(p, dict) and isinstance(p.get("id"), str)]
             for mid, (_, m, _) in manifests.items()}
    state: dict[str, int] = {}

    def walk(node, stack):
        if state.get(node) == 2:
            return
        if state.get(node) == 1:
            cycle = " → ".join(stack[stack.index(node):] + [node])
            for member in stack[stack.index(node):]:
                problems_by_id[member].append(f"predecessor chain is CIRCULAR: {cycle}")
            return
        state[node] = 1
        for nxt in edges.get(node, []):
            if nxt in edges:
                walk(nxt, stack + [node])
        state[node] = 2

    for mid in edges:
        walk(mid, [])


def check_tree(m, root: Path, require_recompute: bool,
               problems: list[str], notes: list[str]) -> None:
    tree = m.get("tree")
    if not isinstance(tree, dict) or not isinstance(tree.get("digest"), str):
        return
    head = head_commit(root)
    if head is not None and head == tree.get("commit"):
        actual = tree_digest(root)
        if actual == tree["digest"]:
            notes.append(f"tree digest RECOMPUTED and matched ({actual[:12]}…)")
        else:
            problems.append(f"tree.digest does not describe this tree — recorded "
                            f"{tree['digest'][:12]}…, recomputed {actual[:12]}…")
    else:
        why = (f"HEAD is {head[:12]}…" if head else "this is not a git checkout")
        line = (f"tree digest NOT recomputed: the manifest names "
                f"{str(tree.get('commit'))[:12]}… and {why}")
        (problems if require_recompute else notes).append(line)


def validate(paths: list[Path], require_recompute: bool) -> int:
    root = repo_root()
    manifests: dict = {}
    problems_by_id: dict = {}
    failed_outright = 0

    for path in sorted(paths):
        problems: list[str] = []
        m = read_manifest(path, problems)
        if m is None or not isinstance(m, dict):
            if not problems:
                problems.append("is not a JSON object")
            print(f"FAIL {path}")
            for p in problems:
                print(f"     - {p}")
            failed_outright += 1
            continue
        key = m.get("id") if isinstance(m.get("id"), str) else path.stem
        if key in manifests:
            problems.append(f"id {key!r} is claimed by {manifests[key][0]} as well")
            key = f"{key}::{path}"
        manifests[key] = (path, m, problems)
        problems_by_id[key] = problems

    for key, (path, m, problems) in manifests.items():
        check_shape(m, path, problems)
        check_evidence(m, path, problems)

    check_predecessors(manifests, problems_by_id)

    bad = failed_outright
    for key, (path, m, problems) in sorted(manifests.items(), key=lambda kv: kv[1][0]):
        notes: list[str] = []
        check_tree(m, root, require_recompute, problems, notes)
        status = "FAIL" if problems else "ok  "
        print(f"{status} {path}  [{m.get('status')}, owner {m.get('owner')!r}]")
        for n in notes:
            print(f"     · {n}")
        for p in problems:
            print(f"     - {p}")
        if problems:
            bad += 1

    total = len(manifests) + failed_outright
    if total == 0:
        print("error: no manifests were given — that is not a pass.", file=sys.stderr)
        return 2
    print()
    print(f"{total - bad} of {total} manifests validate"
          + (f"; {bad} FAILED" if bad else ""))
    return 1 if bad else 0


def main(argv: list[str]) -> int:
    args = argv[1:]
    if not args:
        print(__doc__)
        print("usage: evidence-manifest.py validate [--require-recompute] <manifest.json…>")
        print("       evidence-manifest.py digest")
        print("       evidence-manifest.py hash <file…>")
        return 2
    command, rest = args[0], args[1:]
    if command == "digest":
        print(tree_digest(repo_root()))
        return 0
    if command == "hash":
        if not rest:
            print("error: hash needs at least one file", file=sys.stderr)
            return 2
        for name in rest:
            p = Path(name)
            print(f"{sha256_of(p)}  {p.stat().st_size}  {name}")
        return 0
    if command == "validate":
        require = "--require-recompute" in rest
        paths = [Path(a) for a in rest if not a.startswith("--")]
        unknown = [a for a in rest if a.startswith("--") and a != "--require-recompute"]
        if unknown:
            print(f"error: unknown option(s) {unknown}", file=sys.stderr)
            return 2
        return validate(paths, require)
    print(f"error: unknown command {command!r}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
