# Authoring checklist — CommonsLang_Python

The two **bundles carry real, GitHub-API-verified pins** (CPython 3.13.14 from
python-build-standalone `20260728`; uv 0.12.1) and validate with `dk0 get-bundle`.
The remaining files carry dk0-generated content-addressed value-ids or are
hardware-gated. Template package: `Y:\source\CommonsSec_Age` (a validated
bundle-of-released-binaries package) and `Y:\source\CommonsLang_DotNet` (the
prebuilt-runtime template). Source plan:
`Y:\source\rotary-phone\commonslang-python-plan.md`.

## Design decisions (defaults chosen; confirmable with the maintainer)

- **Ingestion strategy:** OCaml-style **lock-then-build** — an author-time
  `Dk.PipLock` runs `uv` to produce a slot-aware, hash-pinned lock (checked in,
  schema-validated), and a build-time `Dk.PipBuild` installs each locked package
  offline into a per-slot object. Recommended over a static vendored wheelhouse
  because it matches dk0's hermetic, network-free-at-build-time model. (This is
  the deferred, complex part — step 4 below.)
- **CPython:** a single line, **3.13.14**. (Multiple parallel lines can be added
  later like `CommonsLang_OCaml` ships 4.14/5.4/5.5.)
- **uv:** a **first-class runnable module** (`Uv` with a runner uirule), also used
  internally as the resolver/installer behind `Dk.PipLock`/`Dk.PipBuild`.
- **ABIs:** Windows_x86_64, Linux_x86_64, Darwin_x86_64, Darwin_arm64 (the
  intersection both upstreams ship). Add Linux_arm64 / musl later if wanted.
- **Distribution version line:** 0.1.

## Done in this repo

- `etc/dk/v/CommonsLang_Python/SDK.Bundle.values.jsonc` (CPython, 4 ABIs) and
  `Uv.Bundle.values.jsonc` (uv, 4 ABIs) — real `{path, sha256, size, origin}`.
- `dk.u`, `README.md`, `.gitattributes`, `.gitignore`, launchers
  (dk0/dk0.cmd/dk1/dk1.cmd).

## Remaining

1. **Workspace:** `dk0 add github-l2 dkpkg/CommonsBase_Std` + `dk0 update` (fills
   `dk.u` and `etc/dk/i`; provides `Extract.F_Untar`).
2. **Inspect archive layouts** (like the age package): the CPython `install_only`
   tarball extracts to a `python/` tree (`python/bin/python3` + `python/lib/…` on
   Unix; `python/python.exe` + `python/Lib/…` on Windows). uv extracts to a
   `uv-<target>/` dir. Download one per OS and `tar -tf` to pin the declared
   `paths`. NB: the CPython Windows asset is a `.tar.gz` (not a zip), so **all**
   CPython slots use `run-function CommonsBase_Std.Extract.F_Untar` (the uv
   Windows asset is a `.zip` → `get-asset` auto-extracts).
3. **Modules** `SDK.values.lua` + `Uv.values.lua` (mirror `CommonsSec_Age`'s
   `Age.values.lua`): `supported_slots()`, per-slot file lists, `rules.Files`
   extractors, and `uirules.Python` / `uirules.Uv` runners with a scrubbed env
   (set `PYTHONHOME`, `PYTHONNOUSERSITE=1`, clear inherited `PYTHON*`/`PIP_*`/
   `VIRTUAL_ENV`; disable telemetry). Use `F_Untar@<ver>` matching the imported
   CommonsBase_Std (0.3.0 for 2.6.x).
4. **Ingestion pair** `Dk.PipLock.values.lua` + `Dk.PipBuild.values.lua` +
   `etc/dk/schema/dk-pip-lock-1.0.json` (adapt `CommonsLang_OCaml`'s
   `Dk.OpamLock`/`Dk.OpamBuild` + `dk-opam-lock-1.0.json`). `Dk.PipLock.Solve`
   runs `uv pip compile`/`uv lock` at author time against a pinned index; a build
   rule installs offline. This is the primitive `convert-pypi-to-dk-package`
   targets.
5. **Distribution** `dist/any.u` (mirror `CommonsSec_Age/dist/any.u`); object
   value-ids are dk0-generated at build.
6. **CI** `.github/workflows/distribute-0.1.yml` — copy the CURRENT template
   (the `dk-distribute@v3` distribute job + the combined **`dk-distribute/attest-release@v3`**
   step, per the updated `CommonsSec_Age` workflow), 4-ABI matrix.
7. **Rule validation:** a brand-new local rule is only exercised by the first
   `distribute` build (a bare `run-function` cannot build it) — validate at CI
   distribute, as with `CommonsSec_Age`.
8. **prepare-version (hardware-gated):** run
   `dksdk-coder/scripts/prepare-dkpkg-version.ps1 -Package CommonsLang_Python
   -Spdx Python-2.0`. The driver materializes `age` from `CommonsSec_Age` via
   `get-asset` (no hand-install), age-encrypts the transcript to the recovery
   recipients, and sets the GitHub environment secrets. Needs the provisioned
   YubiKeys + the GitLab archive.
9. **Release + CI validation:** tag `0.1.0`; validate via
   `dksdk-coder:github-actions-validation`. Then label diskuv/dk#105
   `implemented`, comment, and close (per `implement-package-requests`).

## Refresh (later CPython/uv versions)

Re-pin with `gh api repos/astral-sh/python-build-standalone/releases/latest`
(and `.../uv/...`) `--jq '.assets[] | {name, size, digest}'`, updating the two
bundle files and the module versions.
