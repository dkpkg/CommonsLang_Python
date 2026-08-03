-- CommonsLang_Python.UvLock -- author-time: solve a PyPI requirement set with uv
-- and write a slot-aware dk-uv-lock.jsonc that UvBuild consumes.
--
-- DRAFT (ported from CommonsLang_OCaml/etc/dk/v/Dk.OpamLock.values.lua, adapted
-- for uv). The heavy lifting lives in the checked-in Python generator
-- assets/uv-lock/dk_uv_lock.py: this rule just materializes CPython + uv, runs the
-- generator, and the generator writes the lock. NOT build-validated (see
-- AUTHORING.md). lua-ml has no local functions; a global helper table is used.

CommonsLang_Python_UvLock = {
  id_module = "CommonsLang_Python.UvLock",
  id_version = "1.0.0"
}

local M = { id = CommonsLang_Python_UvLock.id_module .. "@" .. CommonsLang_Python_UvLock.id_version }
rules, uirules = build.newrules(M)

-- Export marker: running any rule of a scriptmodule brings the whole module
-- (including uirules.Solve) into a distribution. dist/<ABI>.u runs this.
function rules.Export(command, request)
  local slots = {
    "Release.Windows_x86_64", "Release.Linux_x86_64", "Release.Darwin_x86_64", "Release.Darwin_arm64"
  }
  if command == "declareoutput" then
    return { declareoutput = { return_objects = {
      id = string.format("%s.Export@%s", CommonsLang_Python_UvLock.id_module, CommonsLang_Python_UvLock.id_version),
      slots = slots, execution_slot = "Release.execution_abi" } } }
  elseif command == "submit" then
    -- Empty marker via hermetic coreutils `touch`; ships the UvLock scriptmodule (uirules.Solve).
    return { submit = { values = { schema_version = { major = 1, minor = 0 }, forms = { {
      id = request.submit.outputid,
      function_ = { commands = {
        "$(get-object CommonsBase_Std.Coreutils@0.6.0 -s ${SLOTNAME.Release.execution_abi} -m ./coreutils.exe -f coreutils.exe -e '*')",
        "touch",
        "${SLOT.request}/uvlock-scriptmodule"
      } },
      outputs = { assets = { { slots = slots, paths = { "uvlock-scriptmodule" } } } } } } } } }
  end
end

-- `dk0 dialog CommonsLang_Python.UvLock.Solve@1.0.0 reqs[]=requests reqs[]=flask
--    out=dk.uv-lock.jsonc python-version=3.13`
--
-- Materializes CPython (python) + uv, then runs the generator to produce the
-- lock. Requirements come from `reqs[]=...`; the generator uses `uv lock` +
-- per-platform `uv export --format pylock.toml` internally.
function uirules.Solve(command, request, continue_)
  if command == "ui" then
    print("dk-uv-lock written.")
    return
  end
  if command ~= "submit" then return end
  if continue_ ~= "solve" then
    -- Stage 1: materialize the toolchain dirs + the generator asset.
    return { submit = { expressions = {
      directories = {
        pythondir = "$(install-object CommonsLang_Python.SDK.Zip@3.13.14 -s Release.execution_abi -m ./output.zip -n 1 -d :)",
        uvdir     = "$(get-object CommonsLang_Python.Uv.Form@0.12.1 -s Release.execution_abi -d :)"
      },
      files = {
        generator = "$(get-asset CommonsLang_Python.Apparatus.UvLockGenerator@1.0.0 -p assets/uv-lock/dk_uv_lock.py -f dk_uv_lock.py)"
      }
    }, andthen = { continue_ = { state = "solve" } } } }
  end
  -- Stage 2: run the generator with python + uv on PATH.
  local pythondir = request.io.realpath(request.continued.pythondir)
  local uvdir = request.io.realpath(request.continued.uvdir)
  local generator = request.io.realpath(request.continued.generator)
  local pyexe = pythondir .. "/python" .. (request.execution.OSFamily == "windows" and ".exe" or "3")
  local uvrel = (request.execution.OSFamily == "windows") and "uv.exe" or "uv"   -- Unix uv is under uv-<target>/; see Uv.uv_relpath
  local out = request.user.out or "dk.uv-lock.jsonc"
  local pyver = request.user["python-version"] or "3.13"
  -- Build: python dk_uv_lock.py --python-version <v> --out <out> --requirement R ...
  local args = { generator, "--python-version", pyver, "--out", out }
  local reqs = request.user.reqs or {}
  local i, r = 1, reqs[1]
  while r do table.insert(args, "--requirement"); table.insert(args, r); i = i + 1; r = reqs[i] end
  request.io.close(request.continued.pythondir); request.io.close(request.continued.uvdir)
  assert(request.ui.spawn {
    program = pyexe,
    args = args,
    -- uv must be discoverable by the generator (it shells out to `uv`).
    envmods = { "<PATH=" .. uvdir, "+UV_NO_CONFIG=1", "-VIRTUAL_ENV", "-UV_PYTHON" }
  })
end

return M
