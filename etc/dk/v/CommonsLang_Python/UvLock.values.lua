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

-- Absolute path to the uv executable inside a materialized Uv.Form dir. Windows
-- keeps uv.exe at the root; the Unix uv release tarball nests it under uv-<target>/.
function CommonsLang_Python_UvLock.uv_exe(uvdir, slot)
  if string.find(slot, "Windows_") ~= nil then return uvdir .. "/uv.exe" end
  if slot == "Release.Linux_x86_64" then return uvdir .. "/uv-x86_64-unknown-linux-gnu/uv" end
  if slot == "Release.Darwin_x86_64" then return uvdir .. "/uv-x86_64-apple-darwin/uv" end
  if slot == "Release.Darwin_arm64" then return uvdir .. "/uv-aarch64-apple-darwin/uv" end
  error("unsupported uv slot: " .. slot)
end

-- `dk0 dialog CommonsLang_Python.UvLock.Solve@1.0.0 reqs[]=requests reqs[]=flask
--    out=dk.uv-lock.jsonc python-version=3.13`
--
-- Materializes CPython + uv, runs the generator (which does `uv lock` +
-- per-platform `uv export`), and writes the resulting lock into the project.
-- Follows the OCaml Dk.OpamLock.Solve two-stage pattern: stage 1 declares the
-- directory/file expressions and continues; stage 2 (in the continuation, where
-- program launches are permitted and continued objects must be closed) runs the
-- generator via request.ui.capture and publishes stdout with request.ui.writefile.
function uirules.Solve(command, request, continue_)
  if command == "ui" then return end
  if command ~= "submit" then return end
  if continue_ ~= "solve" then
    return { submit = { expressions = {
      directories = {
        pythondir = "$(get-object CommonsLang_Python.SDK.Zip@3.13.14 -s Release.execution_abi -m ./output.zip -n 1 -d :)",
        uvdir     = "$(get-object CommonsLang_Python.Uv.Form@0.12.1 -s Release.execution_abi -d :)"
      },
      files = {
        generator = "$(get-asset CommonsLang_Python.Apparatus.UvLockGenerator@1.0.0 -p assets/uv-lock/dk_uv_lock.py -f dk_uv_lock.py)"
      }
    }, andthen = { continue_ = { state = "solve" } } } }
  end
  local slot = "Release." .. assert(request.execution.ABIv3, "Expected request.execution.ABIv3")
  local iswin = string.find(slot, "Windows_") ~= nil
  local pythondir = request.io.realpath(request.continued.pythondir)
  local uvdir = request.io.realpath(request.continued.uvdir)
  local generator = request.io.realpath(request.continued.generator)
  request.io.close(request.continued.pythondir)
  request.io.close(request.continued.uvdir)
  request.io.close(request.continued.generator)
  local pyexe = pythondir .. (iswin and "/python.exe" or "/bin/python3")
  local uvexe = CommonsLang_Python_UvLock.uv_exe(uvdir, slot)
  local out = request.user.out or "dk.uv-lock.jsonc"
  local pyver = request.user["python-version"] or "3.13"
  -- python dk_uv_lock.py --python-version V --out - --uv <uvexe> --requirement R ...
  local args = { generator, "--python-version", pyver, "--out", "-", "--uv", uvexe }
  local reqs = request.user.reqs or {}
  local i, r = 1, reqs[1]
  while r do table.insert(args, "--requirement"); table.insert(args, r); i = i + 1; r = reqs[i] end
  local result, msg, kind = request.ui.capture {
    program = pyexe, args = args, max_output_bytes = 16777211,
    envmods = { "+UV_NO_CONFIG=1", "-VIRTUAL_ENV", "-UV_PYTHON" }
  }
  assert(result, "could not run the uv-lock generator: " .. tostring(kind) .. ": " .. tostring(msg))
  assert(result.status == "exit" and result.code == 0,
    "uv-lock generator failed (code " .. tostring(result.code) .. "): " .. tostring(result.stderr))
  local meta = request.ui.checksum { path = out }
  local expected = "false"
  if meta and meta.sha256 then expected = meta.sha256 end
  local ok, written = request.ui.writefile { path = out, content = result.stdout, expected_sha256 = expected }
  assert(ok, "could not write dk-uv-lock to `" .. out .. "`: " .. tostring(written))
  print("wrote dk-uv-lock to " .. tostring(written))
  return { submit = {} }
end

return M
