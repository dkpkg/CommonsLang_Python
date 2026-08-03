-- CommonsLang_Python.Uv -- materialize uv (+uvx) for a slot, and a runner.
--
-- DRAFT: authored to the researched patterns (mirrors CommonsSec_Age/Age.values.lua
-- for rules.Files and CommonsLang_DotNet SDK.values.lua for the runner). NOT yet
-- build-validated -- a fresh rule is only exercised by the first `distribute`
-- build; see AUTHORING.md. lua-ml has no local functions, so a global helper
-- table holds the helpers.
--
-- uv is a handful of files: the Windows asset is a .zip (get-asset auto-extracts
-- uv.exe/uvx.exe/uvw.exe at the slot root); the Unix asset is a .tar.gz whose
-- files live under `uv-<target>/`.

CommonsLang_Python_Uv = {
  id_module = "CommonsLang_Python.Uv",
  id_version = "0.12.1",
  bundle = "CommonsLang_Python.Uv.Bundle@0.12.1"
}

local M = { id = CommonsLang_Python_Uv.id_module .. "@" .. CommonsLang_Python_Uv.id_version }
rules, uirules = build.newrules(M)

function CommonsLang_Python_Uv.form_output_id()
  return string.format("%s.Form@%s", CommonsLang_Python_Uv.id_module, CommonsLang_Python_Uv.id_version)
end

function CommonsLang_Python_Uv.supported_slots()
  return {
    "Release.Windows_x86_64",
    "Release.Linux_x86_64",
    "Release.Darwin_x86_64",
    "Release.Darwin_arm64"
  }
end

-- Per-slot uv release asset filename and the archive's internal target dir (Unix).
function CommonsLang_Python_Uv.asset_for(slot)
  if slot == "Release.Windows_x86_64" then return "uv-x86_64-pc-windows-msvc.zip", nil end
  if slot == "Release.Linux_x86_64" then return "uv-x86_64-unknown-linux-gnu.tar.gz", "uv-x86_64-unknown-linux-gnu" end
  if slot == "Release.Darwin_x86_64" then return "uv-x86_64-apple-darwin.tar.gz", "uv-x86_64-apple-darwin" end
  if slot == "Release.Darwin_arm64" then return "uv-aarch64-apple-darwin.tar.gz", "uv-aarch64-apple-darwin" end
  error("Unsupported uv slot: " .. slot)
end

-- The uv executable path, relative to the materialized Files dir, per slot.
function CommonsLang_Python_Uv.uv_relpath(slot)
  if slot == "Release.Windows_x86_64" then return "uv.exe" end
  local _, dir = CommonsLang_Python_Uv.asset_for(slot)
  return dir .. "/uv"
end

function CommonsLang_Python_Uv.form_values(slot)
  local asset, dir = CommonsLang_Python_Uv.asset_for(slot)
  local is_windows = string.find(slot, "Windows_") ~= nil
  local private, paths
  if is_windows then
    private = { string.format("get-asset %s -p %s -d ${SLOT.%s}", CommonsLang_Python_Uv.bundle, asset, slot) }
    paths = { "uv.exe", "uvx.exe", "uvw.exe" }
  else
    private = { string.format(
      "run-function CommonsBase_Std.Extract.F_Untar@0.3.0 -d ${SLOT.%s} modver=CommonsLang_Python.Uv.Unix.%s@0.12.1 tarmodver=%s tarassetpath=%s paths[]=%s/uv paths[]=%s/uvx",
      slot, slot, CommonsLang_Python_Uv.bundle, asset, dir, dir) }
    paths = { dir .. "/uv", dir .. "/uvx" }
  end
  return { private = private }, { assets = { { slots = { slot }, paths = paths } } }
end

function rules.Files(command, request)
  if command == "declareoutput" then
    local slot = assert(request.user.slot, "please provide `slot=SLOT`")
    return { declareoutput = { return_objects = {
      id = CommonsLang_Python_Uv.form_output_id(),
      slots = CommonsLang_Python_Uv.supported_slots(),
      execution_slot = slot } } }
  elseif command == "submit" then
    local slot = assert(request.user.slot, "please provide `slot=SLOT`")
    local precommands, outputs = CommonsLang_Python_Uv.form_values(slot)
    return { submit = { values = { schema_version = { major = 1, minor = 0 },
      forms = { { id = request.submit.outputid, precommands = precommands, outputs = outputs } } } } }
  end
end

function CommonsLang_Python_Uv.envmods()
  return {
    "-UV_PYTHON", "-UV_INDEX_URL", "-UV_EXTRA_INDEX_URL", "-UV_CACHE_DIR",
    "-VIRTUAL_ENV", "-UV_SYSTEM_PYTHON", "-UV_NO_CONFIG",
    "+UV_NO_CONFIG=1"
  }
end

function CommonsLang_Python_Uv.common_submit_response(request)
  local slot = "Release." .. assert(request.execution.ABIv3, "Expected `request.execution.ABIv3`")
  local outputid = CommonsLang_Python_Uv.form_output_id()
  local precommands, outputs = CommonsLang_Python_Uv.form_values(slot)
  return { submit = {
    values = { schema_version = { major = 1, minor = 0 },
      forms = { { id = outputid, precommands = precommands, outputs = outputs } } },
    expressions = {
      directories = { uvdir = "$(get-object " .. outputid .. " -s " .. slot .. " -d :)" },
      files = {},
      strings = { extexe = "${.exe.execution}", uvrel = CommonsLang_Python_Uv.uv_relpath(slot) } } } }
end

-- `dk0 run CommonsLang_Python.Uv.Uv@0.12.1 'args[]=--version'` runs uv <args>.
function uirules.Uv(command, request, continue_)
  if command == "submit" then
    return CommonsLang_Python_Uv.common_submit_response(request)
  elseif command == "ui" then
    local uvdir = request.io.realpath(assert(request.continued.uvdir,
      "Expected `uvdir` in expressions.directories"))
    local program = uvdir .. "/" .. request.continued.uvrel
    assert(request.ui.spawn { program = program, envmods = CommonsLang_Python_Uv.envmods(), args = request.user.args })
  end
end

return M
