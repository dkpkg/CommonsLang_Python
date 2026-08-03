-- CommonsLang_Python.SDK -- the CPython runtime + a `python` runner.
--
-- DRAFT: authored to the researched patterns; NOT yet build-validated (see
-- AUTHORING.md). lua-ml has no local functions, so a global helper table is used.
--
-- The whole CPython `python/` tree (thousands of files) is captured as a single
-- `output.zip` by `CommonsBase_Std.Extract.F_TarToZip` and exposed as the object
-- `CommonsLang_Python.SDK.Zip@3.13.14`. That object is CREATED per-ABI in the
-- `dist/<ABI>.u` scripts (the CPython asset filename differs per ABI), following
-- the MSYS2 idiom. Consumers and the runner below materialize it with
-- `install-object ... -m ./output.zip -n 1 -d <dest>` (the `-n 1` strips the
-- leading `python/`).

CommonsLang_Python_SDK = {
  id_module = "CommonsLang_Python.SDK",
  id_version = "3.13.14",
  bundle = "CommonsLang_Python.SDK.Bundle@3.13.14",
  zip = "CommonsLang_Python.SDK.Zip@3.13.14"
}

local M = { id = CommonsLang_Python_SDK.id_module .. "@" .. CommonsLang_Python_SDK.id_version }
rules, uirules = build.newrules(M)

function CommonsLang_Python_SDK.supported_slots()
  return {
    "Release.Windows_x86_64",
    "Release.Linux_x86_64",
    "Release.Darwin_x86_64",
    "Release.Darwin_arm64"
  }
end

-- Per-slot CPython release asset filename (python-build-standalone install_only).
function CommonsLang_Python_SDK.asset_for(slot)
  if slot == "Release.Windows_x86_64" then return "cpython-3.13.14+20260728-x86_64-pc-windows-msvc-install_only.tar.gz" end
  if slot == "Release.Linux_x86_64" then return "cpython-3.13.14+20260728-x86_64-unknown-linux-gnu-install_only.tar.gz" end
  if slot == "Release.Darwin_x86_64" then return "cpython-3.13.14+20260728-x86_64-apple-darwin-install_only.tar.gz" end
  if slot == "Release.Darwin_arm64" then return "cpython-3.13.14+20260728-aarch64-apple-darwin-install_only.tar.gz" end
  error("Unsupported CPython slot: " .. slot)
end

-- After `install-object -n 1` (strips `python/`): Windows has python.exe at the
-- dir root; Unix has bin/python3.
function CommonsLang_Python_SDK.python_relpath(slot)
  if string.find(slot, "Windows_") ~= nil then return "python.exe" end
  return "bin/python3"
end

-- `rules.Export` is the scriptmodule marker: running any rule of a scriptmodule
-- brings the whole module (including uirules.Python) into a distribution. Each
-- dist/<ABI>.u runs `run-function CommonsLang_Python.SDK.Export@3.13.14 -f ...`.
function rules.Export(command, request)
  if command == "declareoutput" then
    return { declareoutput = { return_objects = {
      id = string.format("%s.Export@%s", CommonsLang_Python_SDK.id_module, CommonsLang_Python_SDK.id_version),
      slots = { "Release.Agnostic" }, execution_slot = "Release.Agnostic" } } }
  elseif command == "submit" then
    return { submit = { values = { schema_version = { major = 1, minor = 0 },
      forms = { { id = request.submit.outputid,
        precommands = { private = { "touch ${SLOT.Release.Agnostic}/sdk-scriptmodule" } },
        outputs = { assets = { { slots = { "Release.Agnostic" }, paths = { "sdk-scriptmodule" } } } } } } } } }
  end
end

function CommonsLang_Python_SDK.envmods(options)
  local pythondir = assert(options.pythondir, "Expected `pythondir`")
  return {
    "-PYTHONPATH", "-PYTHONHOME", "-PYTHONSTARTUP", "-PYTHONUSERBASE",
    "-PIP_INDEX_URL", "-PIP_EXTRA_INDEX_URL", "-PIP_TARGET", "-VIRTUAL_ENV",
    "+PYTHONHOME=" .. pythondir,
    "+PYTHONNOUSERSITE=1",
    "+PIP_DISABLE_PIP_VERSION_CHECK=1"
  }
end

function CommonsLang_Python_SDK.common_submit_response(request)
  local slot = "Release." .. assert(request.execution.ABIv3, "Expected `request.execution.ABIv3`")
  return { submit = {
    values = { schema_version = { major = 1, minor = 0 }, forms = {} },
    expressions = {
      directories = {
        -- materialize the CPython tree from the Zip object (strip the python/ prefix)
        pythondir = "$(install-object " .. CommonsLang_Python_SDK.zip .. " -s " .. slot .. " -m ./output.zip -n 1 -d :)"
      },
      files = {},
      strings = { extexe = "${.exe.execution}", pyrel = CommonsLang_Python_SDK.python_relpath(slot) } } } }
end

-- `dk0 run CommonsLang_Python.SDK.Python@3.13.14 'args[]=--version'` runs python.
function uirules.Python(command, request, continue_)
  if command == "submit" then
    return CommonsLang_Python_SDK.common_submit_response(request)
  elseif command == "ui" then
    local pythondir = request.io.realpath(assert(request.continued.pythondir,
      "Expected `pythondir` in expressions.directories"))
    local program = pythondir .. "/" .. request.continued.pyrel
    assert(request.ui.spawn {
      program = program,
      envmods = CommonsLang_Python_SDK.envmods { pythondir = pythondir },
      args = request.user.args })
  end
end

return M
