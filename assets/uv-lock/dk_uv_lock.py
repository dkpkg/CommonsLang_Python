#!/usr/bin/env python3
"""Generate a dk-uv-lock.jsonc from a set of requested PyPI requirements.

Run at AUTHOR time by CommonsLang_Python.UvLock (with the bundled CPython + uv on
PATH). Flow: synthesize a throwaway project, `uv lock` it (universal), then a
single `uv export --format pylock.toml` (PEP 751) so uv records every package's
wheel/sdist URLs + hashes. We then select, per dk slot, the wheel whose platform
tag matches that slot (falling back to a pure-Python `none-any` wheel, then the
sdist), and reshape into the schema-validated dk-uv-lock.jsonc that UvBuild reads.

Usage:
  python dk_uv_lock.py --python-version 3.13 --out dk.uv-lock.jsonc \\
      --requirement requests --requirement 'flask>=3'
  # --out - writes the lock to stdout (the dk rule captures it).

Notes (uv 0.12.1): uv's lockfile is universal; `uv export` has no
`--python-platform`, and the `-o` name must be `pylock.toml`/`pylock.<name>.toml`
with no dots. Per-platform wheel selection is therefore done here, from filenames.
Requires Python 3.11+ (tomllib) -- satisfied by the bundled CPython 3.13.
"""
import argparse, json, os, re, subprocess, sys, tempfile, tomllib, urllib.parse

# dk slots we produce solutions for (the CPython/uv release ABIs).
SLOTS = [
    "Release.Windows_x86_64",
    "Release.Linux_x86_64",
    "Release.Darwin_x86_64",
    "Release.Darwin_arm64",
]


def run(cmd, cwd):
    # uv writes progress to stdout; redirect it to stderr so `--out -` keeps
    # stdout clean for the lock JSON (the dk rule captures stdout).
    subprocess.run(cmd, cwd=cwd, check=True, stdout=sys.stderr)


def first_hash(hashes):
    # PEP 751 records hashes as {algo: hex}; prefer sha256.
    if not hashes:
        return None
    algo = "sha256" if "sha256" in hashes else next(iter(hashes))
    return f"{algo}:{hashes[algo]}"


def basename_of(url):
    return os.path.basename(urllib.parse.urlparse(url).path)


def artifact_from(entry, kind):
    # A PEP 751 wheel/sdist entry: { url, size, hashes = { sha256 = ... } }.
    # There is no filename field; derive it from the URL.
    h = first_hash(entry.get("hashes"))
    url = entry.get("url")
    if not url or h is None:
        return None
    return {"url": url, "hash": h, "size": int(entry.get("size", 0)),
            "filename": basename_of(url), "kind": kind}


def wheel_kind_for_slot(filename, slot):
    # "universal" for a pure-Python wheel (matches every slot), "plat" for a
    # wheel whose platform tag matches this slot, else None.
    n = filename.lower()
    if n.endswith("-none-any.whl"):
        return "universal"
    if slot == "Release.Windows_x86_64":
        return "plat" if "win_amd64" in n else None
    if slot == "Release.Linux_x86_64":
        # dk's Linux slot is glibc (manylinux), not musl.
        return "plat" if ("manylinux" in n and "x86_64" in n) else None
    if slot == "Release.Darwin_x86_64":
        return "plat" if ("macosx" in n and ("x86_64" in n or "universal2" in n)) else None
    if slot == "Release.Darwin_arm64":
        return "plat" if ("macosx" in n and ("arm64" in n or "universal2" in n)) else None
    return None


def wheel_py_ok(filename, pyver):
    # A universal lock can list wheels for several Python versions (cp313 AND
    # cp314); keep only those compatible with the target (bundled) interpreter.
    # Wheel tag fields are the last three: <pytag>-<abitag>-<plattag>.whl.
    if not filename.lower().endswith(".whl"):
        return False
    parts = filename[:-4].split("-")
    if len(parts) < 3:
        return False
    pytag, abitag = parts[-3].lower(), parts[-2].lower()
    minor = int(pyver.split(".")[1])
    for t in pytag.split("."):
        if t == "py3":                       # pure-Python, any 3.x
            return True
        if t == f"cp3{minor}":               # this exact CPython
            return True
        if abitag == "abi3":                 # stable ABI, forward-compatible
            m = re.match(r"^cp3(\d+)$", t)
            if m and int(m.group(1)) <= minor:
                return True
    return False


def select_artifact(pkg, slot, pyver):
    # Prefer a platform-specific wheel, then a pure-Python wheel, then the sdist.
    # Only consider wheels compatible with the target Python version.
    plat, univ = None, None
    for w in pkg.get("wheels") or []:
        a = artifact_from(w, "wheel")
        if not a or not wheel_py_ok(a["filename"], pyver):
            continue
        kind = wheel_kind_for_slot(a["filename"], slot)
        if kind == "plat" and plat is None:
            plat = a
        elif kind == "universal" and univ is None:
            univ = a
    chosen = plat or univ
    if chosen is None and pkg.get("sdist"):
        chosen = artifact_from(pkg["sdist"], "sdist")
    return chosen


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--python-version", default="3.13")
    ap.add_argument("--requirement", action="append", default=[], dest="requirements")
    ap.add_argument("--requirements-file")
    ap.add_argument("--out", required=True)
    ap.add_argument("--uv", default="uv")
    args = ap.parse_args()

    reqs = list(args.requirements)
    if args.requirements_file:
        with open(args.requirements_file) as f:
            reqs += [ln.strip() for ln in f if ln.strip() and not ln.startswith("#")]
    if not reqs:
        sys.exit("no requirements given")

    with tempfile.TemporaryDirectory() as proj:
        deps = ",\n    ".join(json.dumps(r) for r in reqs)
        with open(os.path.join(proj, "pyproject.toml"), "w") as f:
            f.write(
                "[project]\n"
                'name = "dk-uv-lock-workspace"\n'
                'version = "0.0.0"\n'
                f'requires-python = ">={args.python_version}"\n'
                f"dependencies = [\n    {deps}\n]\n"
            )
        uv, py = args.uv, sys.executable
        # Resolve on THIS (bundled) interpreter, and export the universal lock.
        run([uv, "lock", "--python", py], cwd=proj)
        plock = os.path.join(proj, "pylock.toml")
        run([uv, "export", "--format", "pylock.toml", "--python", py,
             "--no-emit-project", "-o", plock], cwd=proj)
        with open(plock, "rb") as f:
            pl = tomllib.load(f)

    pkgs = pl.get("packages", [])

    packages = {}   # "name.version" -> catalog entry (all artifacts)
    for p in pkgs:
        key = f'{p["name"]}.{p["version"]}'
        packages[key] = {
            "name": p["name"],
            "version": p["version"],
            "sdist": artifact_from(p["sdist"], "sdist") if p.get("sdist") else None,
            "wheels": [a for a in (artifact_from(w, "wheel") for w in (p.get("wheels") or [])) if a],
        }

    slots = {}
    for slot in SLOTS:
        solution, artifacts = [], {}
        for p in pkgs:
            key = f'{p["name"]}.{p["version"]}'
            a = select_artifact(p, slot, args.python_version)
            if a:
                solution.append(key)
                artifacts[key] = {k: a[k] for k in ("url", "hash", "size")}
        slots[slot] = {"python": args.python_version,
                       "solution": sorted(solution), "artifacts": artifacts}

    lock = {
        "$schema": "https://diskuv.com/dk/schema/dk-uv-lock-1.0.json",
        "schema_version": {"major": 1, "minor": 0},
        "generated": {"tool": "CommonsLang_Python.UvLock", "python_version": args.python_version},
        "packages": packages,
        "slots": slots,
    }
    body = json.dumps(lock, indent=2, sort_keys=True) + "\n"
    if args.out == "-":
        sys.stdout.write(body)
    else:
        with open(args.out, "w", newline="\n") as f:
            f.write(body)
    print(f"generated dk-uv-lock: {len(packages)} packages, {len(slots)} slots",
          file=sys.stderr)


if __name__ == "__main__":
    main()
