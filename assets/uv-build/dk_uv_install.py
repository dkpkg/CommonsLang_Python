#!/usr/bin/env python3
"""Offline-install a set of pinned wheels and prove the assembled environment imports.

Run at build/validation time by CommonsLang_Python.UvBuild (with the bundled
CPython + uv + the pre-fetched wheels already on disk). The wheels were fetched
hermetically by dk `get-asset` (content-addressed, offline). This installs those
exact wheel files with `uv pip install --no-index --offline` (no network, no
index) into a throwaway target directory, then imports each requested module to
prove the environment works, and prints a JSON summary to stdout.

Usage:
  python dk_uv_install.py --uv <uvexe> --python <pyexe> \\
      --wheel a.whl --wheel b.whl --import six --import markupsafe
Requires Python 3.11+ (stdlib only) -- satisfied by the bundled CPython 3.13.
"""
import argparse, json, os, subprocess, sys, tempfile

IMPORT_PROBE = (
    "import importlib, sys\n"
    "m = importlib.import_module(sys.argv[1])\n"
    "sys.stdout.write(getattr(m, '__version__', '?'))\n"
)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--uv", required=True)
    ap.add_argument("--python", required=True)
    ap.add_argument("--wheel", action="append", default=[], dest="wheels")
    ap.add_argument("--import", action="append", default=[], dest="imports")
    args = ap.parse_args()
    if not args.wheels:
        sys.exit("no wheels given")

    with tempfile.TemporaryDirectory() as target:
        # Offline install of the exact pinned wheels: no index, no network. All
        # progress goes to stderr so stdout stays clean for the JSON summary.
        cmd = [args.uv, "pip", "install", "--python", args.python,
               "--target", target, "--no-index", "--offline"] + args.wheels
        subprocess.run(cmd, check=True, stdout=sys.stderr)

        # Prove each requested module imports from the assembled target.
        versions = {}
        env = dict(os.environ)
        env["PYTHONPATH"] = target
        for mod in args.imports:
            out = subprocess.run([args.python, "-c", IMPORT_PROBE, mod],
                                 check=True, capture_output=True, text=True, env=env)
            versions[mod] = out.stdout.strip()

    sys.stdout.write(json.dumps({"installed_wheels": len(args.wheels),
                                 "imports": versions}) + "\n")
    print("assembled + imported OK", file=sys.stderr)


if __name__ == "__main__":
    main()
