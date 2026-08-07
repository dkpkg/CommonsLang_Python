-- CommonsLang_Python.UvBuild -- build-time: materialize ONE locked package into a
-- per-slot object, by reading the dk-uv-lock.jsonc and fetching that package's
-- pinned wheel (URL + hash) offline. It NEVER solves and NEVER queries an index.
--
-- DRAFT (ported from CommonsLang_OCaml/etc/dk/v/Dk.OpamBuild.values.lua's
-- F_BuildLockedPackage, adapted for uv wheels). For a prebuilt wheel the "build"
-- is just a content-addressed fetch: the object payload is the wheel file
-- (install.whl); a downstream venv-assembly step unzips the closure's wheels into
-- site-packages. (sdist-only packages would need a real build backend -- a future
-- path.) NOT build-validated (see AUTHORING.md).

CommonsLang_Python_UvBuild = {
  id_module = "CommonsLang_Python.UvBuild",
  id_version = "1.0.0"
}

local M = { id = CommonsLang_Python_UvBuild.id_module .. "@" .. CommonsLang_Python_UvBuild.id_version }
rules, uirules = build.newrules(M)

CommonsLang_Python_UvBuild.SLOTS = {
  "Release.Windows_x86_64", "Release.Linux_x86_64", "Release.Darwin_x86_64", "Release.Darwin_arm64"
}

function rules.Export(command, request)
  if command == "declareoutput" then
    return { declareoutput = { return_objects = {
      id = string.format("%s.Export@%s", CommonsLang_Python_UvBuild.id_module, CommonsLang_Python_UvBuild.id_version),
      slots = CommonsLang_Python_UvBuild.SLOTS, execution_slot = "Release.execution_abi" } } }
  elseif command == "submit" then
    -- Empty marker via hermetic coreutils `touch`; ships the UvBuild scriptmodule (F_BuildLockedPackage).
    return { submit = { values = { schema_version = { major = 1, minor = 0 }, forms = { {
      id = request.submit.outputid,
      function_ = { commands = {
        "$(get-object CommonsBase_Std.Coreutils@0.6.0 -s ${SLOTNAME.Release.execution_abi} -m ./coreutils.exe -f coreutils.exe -e '*')",
        "touch",
        "${SLOT.request}/uvbuild-scriptmodule"
      } },
      outputs = { assets = { { slots = CommonsLang_Python_UvBuild.SLOTS, paths = { "uvbuild-scriptmodule" } } } } } } } } }
  end
end

-- Params (via the driver / request.user):
--   modver=MODULE@VERSION       the <Parent>.Pkg.<Segment>@<version> object to produce
--   pkg=NAME                    the PyPI package name to build from the lock
--   localsrc=MODULE@VERSION     the module whose object carries the lock
--   locksrcpath=PATH            path of dk-uv-lock.jsonc inside localsrc's object
--   deps[]=MODULE@VERSION       sibling Pkg objects this one depends on (edges)
function rules.F_BuildLockedPackage(command, request, continue_)
  local modver = assert(request.user.modver, "please provide modver=MODULE@VERSION")
  local slot = "Release." .. assert(request.execution.ABIv3, "Expected request.execution.ABIv3")

  if command == "declareoutput" then
    return { declareoutput = { return_objects = {
      id = modver, slots = CommonsLang_Python_UvBuild.SLOTS, execution_slot = "Release.execution_abi" } } }

  elseif command == "declareinput" then
    -- Each dep becomes a build-DAG input edge (empty for pure wheels).
    local inputs = {}
    local deps = request.user.deps or {}
    local i, d = 1, deps[1]
    while d do table.insert(inputs, { id = d, slots = CommonsLang_Python_UvBuild.SLOTS }); i = i + 1; d = deps[i] end
    return { declareinput = { input_objects = inputs } }

  elseif command == "submit" and continue_ ~= "build" then
    -- Stage 1: read the lock (no solve).
    local localsrc = assert(request.user.localsrc, "please provide localsrc=MODULE@VERSION")
    local locksrcpath = assert(request.user.locksrcpath, "please provide locksrcpath=PATH")
    return { submit = { expressions = { files = {
      lock = "$(get-object " .. localsrc .. " -s Release.execution_abi -m " .. locksrcpath .. " -f dk-uv-lock.jsonc)"
    } }, andthen = { continue_ = { state = "build" } } } }

  elseif command == "submit" then
    -- Stage 2: find this package's pinned artifact for this slot, fetch it.
    local pkg = assert(request.user.pkg, "please provide pkg=NAME")
    local jd = require("jsondk")
    local lock = jd.decode(request.io.read(request.continued.lock, "a"))
    request.io.close(request.continued.lock)
    assert(lock and lock.slots and lock.slots[slot], "lock has no solution for " .. slot)
    -- find the "<name>.<version>" key in this slot's solution whose name == pkg.
    -- Numeric while, not for-in/pairs -- lua-ml has no generic for or `break`.
    local solution = lock.slots[slot].solution
    local artifacts = lock.slots[slot].artifacts
    local key, art
    local i = 1
    local k = solution[1]
    while k and not art do
      if string.sub(k, 1, string.len(pkg) + 1) == (pkg .. ".") then key = k; art = artifacts[k] end
      i = i + 1; k = solution[i]
    end
    assert(art, "package `" .. pkg .. "` not in the " .. slot .. " solution")

    -- Synthesize a one-asset bundle for the wheel (url/hash/size) and get-asset it.
    -- (Mirrors OpamBuild's synthesized .Src bundle.) The wheel filename is the
    -- basename of the URL.
    local url = art.url
    local basename = CommonsLang_Python_UvBuild.basename_url(url)
    local origin_base = CommonsLang_Python_UvBuild.dirname_url(url)
    local bundle_id = modver .. ".Whl"
    local sha256 = art.hash
    if string.sub(sha256, 1, 7) == "sha256:" then sha256 = string.sub(sha256, 8) end
    return { submit = {
      values = {
        schema_version = { major = 1, minor = 0 },
        bundles = { {
          id = bundle_id,
          listing = { origins = { { name = "pypi", mirrors = { origin_base } } } },
          assets = { { path = basename, checksum = { sha256 = sha256 }, size = art.size, origin = "pypi" } }
        } },
        forms = { {
          id = request.submit.outputid,
          -- get-asset the wheel as the object payload (install.whl). Do NOT
          -- auto-extract: the object is the wheel file; assembly unzips later.
          precommands = { private = {
            string.format("get-asset %s -p %s -f ${SLOT.%s}/install.whl", bundle_id, basename, slot)
          } },
          outputs = { assets = { { slots = { slot }, paths = { "install.whl" } } } }
        } }
      }
    } }
  end
end

-- Global helpers (lua-ml has neither string.gsub nor local functions).
function CommonsLang_Python_UvBuild.dirname_url(url)
  local i = string.len(url)
  while i > 0 do
    if string.sub(url, i, i) == "/" then return string.sub(url, 1, i - 1) end
    i = i - 1
  end
  return url
end
function CommonsLang_Python_UvBuild.basename_url(url)
  local i = string.len(url)
  while i > 0 do
    if string.sub(url, i, i) == "/" then return string.sub(url, i + 1) end
    i = i - 1
  end
  return url
end
function CommonsLang_Python_UvBuild.uv_exe(uvdir, slot)
  if string.find(slot, "Windows_") ~= nil then return uvdir .. "/uv.exe" end
  if slot == "Release.Linux_x86_64" then return uvdir .. "/uv-x86_64-unknown-linux-gnu/uv" end
  if slot == "Release.Darwin_x86_64" then return uvdir .. "/uv-x86_64-apple-darwin/uv" end
  if slot == "Release.Darwin_arm64" then return uvdir .. "/uv-aarch64-apple-darwin/uv" end
  error("unsupported uv slot: " .. slot)
end

-- `dk0 dialog CommonsLang_Python.UvBuild.Build@1.0.0 lock=dk.uv-lock.jsonc import[]=six`
--
-- Hermetic offline build/validation. Reads the project lock, fetches each pinned
-- wheel for the execution slot via dk get-asset (content-addressed; no PyPI at
-- build time), then captures the install helper, which `uv pip install
-- --no-index --offline`s those exact wheels into a throwaway target and imports
-- the requested modules to prove the assembled environment works. Same two-stage
-- capture pattern as UvLock.Solve: stage 1 declares the wheel bundle + object
-- expressions and continues; stage 2 (where program launches are permitted and
-- continued objects must be closed) runs the installer via request.ui.capture.
function uirules.Build(command, request, continue_)
  if command == "ui" then return end
  if command ~= "submit" then return end
  local slot = "Release." .. assert(request.execution.ABIv3, "Expected request.execution.ABIv3")
  local iswin = string.find(slot, "Windows_") ~= nil
  if continue_ ~= "build" then
    local lockpath = request.user.lock or "dk.uv-lock.jsonc"
    local content = assert(request.ui.readfile { path = lockpath },
      "could not read lock `" .. lockpath .. "`")
    local jd = require("jsondk")
    local lock = jd.decode(content)
    assert(lock and lock.slots and lock.slots[slot], "lock has no solution for " .. slot)
    local solution = lock.slots[slot].solution
    local artifacts = lock.slots[slot].artifacts
    -- Synthesize ONE bundle listing every pinned wheel in the slot's solution
    -- (each wheel is its own origin: mirror = URL dir, asset path = filename),
    -- plus a get-asset file expression per wheel (proven in the ZProbe).
    local bundle_id = "CommonsLang_Python.UvBuild.Build.Wheelhouse@1.0.0"
    local origins = {}
    local assets = {}
    local files = {
      helper = "$(get-asset CommonsLang_Python.Apparatus.UvLockGenerator@1.0.0 -p assets/uv-lock/dk_uv_lock.py -f dk_uv_lock.py)"
    }
    local i = 1
    local key = solution[1]
    while key do
      local art = assert(artifacts[key], "no artifact for " .. tostring(key))
      local base = CommonsLang_Python_UvBuild.basename_url(art.url)
      local sha = art.hash
      if string.sub(sha, 1, 7) == "sha256:" then sha = string.sub(sha, 8) end
      local oname = string.format("o%d", i)
      table.insert(origins, { name = oname, mirrors = { CommonsLang_Python_UvBuild.dirname_url(art.url) } })
      table.insert(assets, { path = base, checksum = { sha256 = sha }, size = art.size, origin = oname })
      files[string.format("wheel_%d", i)] = "$(get-asset " .. bundle_id .. " -p " .. base .. " -f " .. base .. ")"
      i = i + 1
      key = solution[i]
    end
    return { submit = {
      values = { schema_version = { major = 1, minor = 0 }, bundles = { {
        id = bundle_id, listing = { origins = origins }, assets = assets
      } } },
      expressions = {
        directories = {
          -- The Python interpreter is a target artifact: its native compilation
          -- (setuptools C extensions) must target the build's target ABI, so it
          -- is fetched at the target ABI slot and run under the execution host's
          -- emulator (for example Rosetta on a cross-built macOS host). uv is a
          -- host tool and stays at the execution ABI.
          pythondir = "$(get-object CommonsLang_Python.SDK.Zip@3.13.14 -s Release.target_abi -m ./output.zip -n 1 -d :)",
          uvdir     = "$(get-object CommonsLang_Python.Uv.Form@0.12.1 -s Release.execution_abi -d :)"
        },
        files = files
      },
      andthen = { continue_ = { state = "build" } }
    } }
  end
  local pythondir = request.io.realpath(request.continued.pythondir)
  local uvdir = request.io.realpath(request.continued.uvdir)
  local helper = request.io.realpath(request.continued.helper)
  request.io.close(request.continued.pythondir)
  request.io.close(request.continued.uvdir)
  request.io.close(request.continued.helper)
  local pyexe = pythondir .. (iswin and "/python.exe" or "/bin/python3")
  local uvexe = CommonsLang_Python_UvBuild.uv_exe(uvdir, slot)
  local args = { helper, "install", "--uv", uvexe, "--python", pyexe }
  -- Collect + close every fetched wheel object.
  local i = 1
  local wkey = "wheel_1"
  while request.continued[wkey] do
    table.insert(args, "--wheel")
    table.insert(args, request.io.realpath(request.continued[wkey]))
    request.io.close(request.continued[wkey])
    i = i + 1
    wkey = string.format("wheel_%d", i)
  end
  local imports = request.user["import"] or {}
  local j = 1
  local m = imports[1]
  while m do table.insert(args, "--import"); table.insert(args, m); j = j + 1; m = imports[j] end
  local result, msg, kind = request.ui.capture {
    program = pyexe, args = args, max_output_bytes = 16777211,
    envmods = { "+UV_NO_CONFIG=1", "-VIRTUAL_ENV", "-UV_PYTHON" }
  }
  assert(result, "could not run the uv installer: " .. tostring(kind) .. ": " .. tostring(msg))
  assert(result.status == "exit" and result.code == 0,
    "uv install/validate failed (code " .. tostring(result.code) .. "): " .. tostring(result.stderr))
  print("uv-build OK: " .. tostring(result.stdout))
  return { submit = {} }
end

-- rules.F_Build -- the dist-testable offline build unit. Given ONE pinned wheel
-- (url/hash/size params) it get-assets the wheel (content-addressed) and, inside a
-- HERMETIC form, `uv pip install --no-index --offline`s it + imports the requested
-- modules. A function rule, so a dist script run-functions it with `\test(pass)` for
-- an offline-build regression + Usage entry -- and it needs NO --trust-local-caps
-- (unlike the Build dialog). The lock itself stays UvLock.Solve (uv lock needs
-- network; forms are hermetic). Windows-only for now; generalize to all slots with
-- slot-gated commands (env -u ${SLOT.Release.<slot>} trick).
--   run-function CommonsLang_Python.UvBuild.F_Build@1.0.0 -d OUT \
--     modver=CommonsLang_Python.UvBuild.Built@1.0.0 url=<wheel-url> \
--     hash=sha256:<hex> size=<bytes> import[]=six
function rules.F_Build(command, request)
  local modver = assert(request.user.modver, "please provide modver=MODULE@VERSION")
  local slots = {
    "Release.Windows_x86_64", "Release.Linux_x86_64", "Release.Darwin_x86_64", "Release.Darwin_arm64"
  }
  if command == "declareoutput" then
    return { declareoutput = { return_objects = {
      id = modver, slots = slots, execution_slot = "Release.execution_abi" } } }
  elseif command == "submit" then
    local url = assert(request.user.url, "please provide url=WHEEL_URL")
    local base = CommonsLang_Python_UvBuild.basename_url(url)
    local origin_base = CommonsLang_Python_UvBuild.dirname_url(url)
    local sha = request.user.hash or ""
    if string.sub(sha, 1, 7) == "sha256:" then sha = string.sub(sha, 8) end
    -- bundle id must be `<modpath>.Whl@<version>` (NOT `<modver>.Whl`, which puts
    -- `.Whl` after the version and fails semver parsing).
    local atpos = assert(string.find(modver, "@"), "modver must contain @")
    local bundle_id = string.sub(modver, 1, atpos - 1) .. ".Whl@" .. string.sub(modver, atpos + 1)
    -- One slot-gated installer command per ABI: the `env -u ${SLOT.Release.<slot>}`
    -- trick makes dk0 drop the command whose referenced slot isn't the one being built,
    -- so only the request slot's line runs. Per-OS python exe + uv subpath; uv is fetched
    -- inline as an ABSOLUTE path (a relative program name fails subprocess resolution),
    -- and the installer defaults --python to its own interpreter.
    local imports = request.user["import"] or {}
    local coreutils = "$(get-object CommonsBase_Std.Coreutils@0.6.0 -s ${SLOTNAME.Release.execution_abi} -m ./coreutils.exe -f coreutils.exe -e '*')"
    local uvbase = "$(get-object CommonsLang_Python.Uv.Form@0.12.1 -s Release.execution_abi -d :)"
    local specs = {
      { "Release.Windows_x86_64", "py/python.exe",  "/uv.exe" },
      { "Release.Linux_x86_64",   "py/bin/python3", "/uv-x86_64-unknown-linux-gnu/uv" },
      { "Release.Darwin_x86_64",  "py/bin/python3", "/uv-x86_64-apple-darwin/uv" },
      { "Release.Darwin_arm64",   "py/bin/python3", "/uv-aarch64-apple-darwin/uv" }
    }
    local commands = {}
    local si = 1
    while specs[si] do
      local sp = specs[si]
      local c = { coreutils, "env", "-u", "${SLOT." .. sp[1] .. "}", "--",
        sp[2], "gen.py", "install", "--uv", uvbase .. sp[3],
        "--wheel", "wheelhouse/" .. base, "--marker", "${SLOT.request}/build-verified.json" }
      local ii, m = 1, imports[1]
      while m do table.insert(c, "--import"); table.insert(c, m); ii = ii + 1; m = imports[ii] end
      table.insert(commands, c)
      si = si + 1
    end
    return { submit = { values = {
      schema_version = { major = 1, minor = 0 },
      bundles = { { id = bundle_id,
        listing = { origins = { { name = "pypi", mirrors = { origin_base } } } },
        assets = { { path = base, checksum = { sha256 = sha }, size = request.user.size, origin = "pypi" } } } },
      forms = { {
        id = request.submit.outputid,
        precommands = { private = {
          "get-object CommonsLang_Python.SDK.Zip@3.13.14 -s Release.execution_abi -m ./output.zip -n 1 -d py",
          "get-asset " .. bundle_id .. " -p " .. base .. " -f wheelhouse/" .. base,
          "get-asset CommonsLang_Python.Apparatus.UvLockGenerator@1.0.0 -p assets/uv-lock/dk_uv_lock.py -f gen.py"
        } },
        function_ = { commands = commands },
        outputs = { assets = { { slots = slots, paths = { "build-verified.json" } } } }
      } }
    } } }
  end
end

return M
