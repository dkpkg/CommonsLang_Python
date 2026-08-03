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
      slots = { "Release.Agnostic" }, execution_slot = "Release.Agnostic" } } }
  elseif command == "submit" then
    return { submit = { values = { schema_version = { major = 1, minor = 0 }, forms = { {
      id = request.submit.outputid,
      precommands = { private = { "touch ${SLOT.Release.Agnostic}/uvbuild-scriptmodule" } },
      outputs = { assets = { { slots = { "Release.Agnostic" }, paths = { "uvbuild-scriptmodule" } } } } } } } } }
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
    local basename = string.gsub(url, "^.*/", "")
    local origin_base = string.gsub(url, "/[^/]*$", "")
    local bundle_id = modver .. ".Whl"
    local sha256 = string.gsub(art.hash, "^sha256:", "")
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

return M
