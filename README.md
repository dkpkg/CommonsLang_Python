# CommonsLang_Python

A dk package that redistributes a **Python toolchain** — the relocatable CPython
runtime ([python-build-standalone](https://github.com/astral-sh/python-build-standalone))
and [uv](https://github.com/astral-sh/uv) — as per-ABI prebuilt binaries, so dk0
can install and run Python and ingest PyPI distributions.

Requested in [diskuv/dk#105](https://github.com/diskuv/dk/issues/105); it unblocks
the dk-ai `convert-pypi-to-dk-package` skill and the Python/PyPI mini-plans the dk
Prompt Studio produces.

Pinned: **CPython 3.13.14** (python-build-standalone `20260728`), **uv 0.12.1**.
Supported ABIs: **Windows_x86_64, Linux_x86_64, Darwin_x86_64, Darwin_arm64**
(the intersection uv and CPython both ship).

Status: **in progress.** The two bundles carry real, checksum-verified pins and
validate with `dk0 get-bundle`. The runtime modules (`SDK`/`Uv` values.lua), the
PyPI ingestion (`Dk.PipLock`/`Dk.PipBuild`), the distribution script, and the CI
workflow are still to be authored — see [AUTHORING.md](AUTHORING.md).

## Consuming (once released)

```sh
dk0 add github-l2 dkpkg/CommonsLang_Python
```
