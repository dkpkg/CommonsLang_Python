#!/usr/bin/env python3
"""Generate a dk-uv-lock.jsonc from a set of requested PyPI requirements.

Run at AUTHOR time by CommonsLang_Python.UvLock (with the bundled CPython + uv on
PATH). Flow: synthesize a throwaway project, `uv lock` it, then for each dk slot
`uv export --format pylock.toml --python-platform <triple>` so uv does the
resolution AND the per-platform wheel selection, giving exact wheel URLs + hashes
(PEP 751). Reshape those into the schema-validated dk-uv-lock.jsonc that
UvBuild reads at build time.

Usage:
  python dk_uv_lock.py --python-version 3.13 --out dk.uv-lock.jsonc \\
      --requirement requests --requirement 'flask>=3'

NOTE (validate against uv 0.12.1): the exact `uv export` flags for per-platform
pylock.toml output are what needs confirming with real uv; the reshaping below is
plain and stable. Requires Python 3.11+ (tomllib) -- satisfied by the bundled
CPython 3.13.
"""
import argparse, json, os, subprocess, sys, tempfile, tomllib

# dk slot -> uv --python-platform target triple (matches the CPython asset triples)
SLOT_PLATFORM = {
    "Release.Windows_x86_64": "x86_64-pc-windows-msvc",
    "Release.Linux_x86_64":   "x86_64-unknown-linux-gnu",
    "Release.Darwin_x86_64":  "x86_64-apple-darwin",
    "Release.Darwin_arm64":   "aarch64-apple-darwin",
}


def run(cmd, cwd):
    subprocess.run(cmd, cwd=cwd, check=True)


def first_hash(hashes):
    # PEP 751 records hashes as {algo: hex}; prefer sha256.
    if not hashes:
        return None
    algo = "sha256" if "sha256" in hashes else next(iter(hashes))
    return f"{algo}:{hashes[algo]}"


def artifact_from(entry, kind):
    h = first_hash(entry.get("hashes"))
    if not entry.get("url") or h is None:
        return None
    return {"url": entry["url"], "hash": h, "size": int(entry.get("size", 0)),
            "filename": entry.get("name", ""), "kind": kind}


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
        run([args.uv, "lock"], cwd=proj)

        packages = {}          # "name.version" -> catalog entry
        slots = {}
        for slot, triple in SLOT_PLATFORM.items():
            plock = os.path.join(proj, f"{slot}.pylock.toml")
            run([args.uv, "export", "--format", "pylock.toml",
                 "--python-platform", triple, "--python-version", args.python_version,
                 "--no-emit-project", "-o", plock], cwd=proj)
            with open(plock, "rb") as f:
                pl = tomllib.load(f)
            solution, artifacts = [], {}
            for p in pl.get("packages", []):
                key = f'{p["name"]}.{p["version"]}'
                solution.append(key)
                # choose the wheel for this platform (uv already filtered); else sdist
                chosen = None
                for w in p.get("wheels", []) or []:
                    chosen = artifact_from(w, "wheel")
                    if chosen:
                        break
                if chosen is None and p.get("sdist"):
                    chosen = artifact_from(p["sdist"], "sdist")
                if chosen:
                    artifacts[key] = {k: chosen[k] for k in ("url", "hash", "size")}
                cat = packages.setdefault(key, {"name": p["name"], "version": p["version"],
                                                "depends": [], "sdist": None, "wheels": []})
                if p.get("sdist"):
                    cat["sdist"] = cat["sdist"] or artifact_from(p["sdist"], "sdist")
                for w in p.get("wheels", []) or []:
                    a = artifact_from(w, "wheel")
                    if a and a not in cat["wheels"]:
                        cat["wheels"].append(a)
            slots[slot] = {"python": args.python_version,
                           "solution": sorted(solution),
                           "artifacts": artifacts}

    lock = {
        "$schema": "https://diskuv.com/dk/schema/dk-uv-lock-1.0.json",
        "schema_version": {"major": 1, "minor": 0},
        "generated": {"tool": "CommonsLang_Python.UvLock", "python_version": args.python_version},
        "packages": packages,
        "slots": slots,
    }
    body = json.dumps(lock, indent=2, sort_keys=True) + "\n"
    with open(args.out, "w", newline="\n") as f:
        f.write(body)
    print(f"wrote {args.out}: {len(packages)} packages, {len(slots)} slots")


if __name__ == "__main__":
    main()
