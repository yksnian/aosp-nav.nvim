-- kotlin/channel.lua: kotlin channel glue (port of classpathChannel.ts +
-- klsSupport.ts + the nvim proc.lua residual-process governance).
--
-- fwcd/ktlsp resolves its classpath as
--     global script (~/.config/kotlin-language-server/classpath)
--       .or(workspace scan: maven -> gradle -> in-tree kls-classpath)
--       .or(backup)
-- where `or` is first-non-empty: a global script that prints anything
-- short-circuits the workspace scan — the stray build.gradle files in an
-- AOSP tree are never touched, no importer switches needed.
--
-- The script is editor-agnostic: this channel works for
-- kotlin-language-server attached from Neovim, VS Code or anything else,
-- and the family protocol (aosp-nav.nvim marker) prevents ping-pong
-- between editors sharing ~/.config.

local pathutil = require("aosp-nav.util.path")
local hash = require("aosp-nav.infra.hash")
local fs = require("aosp-nav.infra.fs")
local kscript = require("aosp-nav.kotlin.classpath_script")
local kls = require("aosp-nav.kotlin.kls_files")
local proc_scan = require("aosp-nav.kotlin.proc_scan")

local M = {}

local S = {
  deps = nil,
  warned_user_script = false,
  bootstrapped = false,
  bootstrap_warned = false, -- download failure is retried per file; notify once
}

local function log(msg)
  if S.deps and S.deps.log then
    S.deps.log("[aosp-nav] kotlin: " .. msg)
  end
end

---The bootstrap retry runs on every Kotlin file; warn about a failed
---download only once per session (the log keeps every attempt).
local function warn_bootstrap_failed()
  if S.bootstrap_warned then
    return
  end
  S.bootstrap_warned = true
  if S.deps.notify then
    S.deps.notify(
      "[aosp-nav] The ktlsp download failed; install it manually (codeberg.org/winlogon/ktlsp) "
        .. "and point your kotlin LSP at its bin/kotlin-language-server."
    )
  end
end

function M.init(deps)
  S.deps = deps
end

-- ------------------------------------------------------------ paths ----

local function config_base()
  if vim then
    local xdg = os.getenv("XDG_CONFIG_HOME")
    if xdg and xdg ~= "" then
      return xdg
    end
    return (vim.fn.expand("~") or "~") .. "/.config"
  end
  return os.getenv("XDG_CONFIG_HOME") or (os.getenv("HOME") or "") .. "/.config"
end

local function kls_config_dir()
  return pathutil.join(config_base(), "kotlin-language-server")
end

local function script_path()
  return pathutil.join(kls_config_dir(), kscript.SCRIPT_NAME)
end

local function nvim_backup_path()
  return pathutil.join(kls_config_dir(), kscript.NVIM_BACKUP_NAME)
end

function M.jar_list_path_for(root)
  return pathutil.join(
    kls_config_dir(),
    kscript.OWN_DIR,
    hash.djb2(pathutil.normalize(root)) .. ".txt"
  )
end

---Cache dir handed to KLS as init_options.storagePath. This is a global
---(cross-checkout) index that KLS sub-indexes by project itself; it lives in
---the plugin's CACHE dir and is rebuilt from scratch if deleted.
local function storage_path()
  if S.deps and S.deps.store and S.deps.store.kotlin_workspace then
    return S.deps.store:kotlin_workspace()
  end
  -- Pre-split fallback: store.base used to be the data dir. Kept for callers
  -- that construct a bare Store without the new helper (e.g. plain-Lua tests).
  local base = (S.deps and S.deps.store and S.deps.store.base)
    or pathutil.join(config_base(), "aosp_nav")
  return pathutil.join(base, "kotlin-workspace")
end

---Where the pinned ktlsp server lives (downloaded by ensure_bootstrap).
---This is a downloaded binary, NOT rebuildable cache: it stays in DATA even
---though every other plugin artifact moved to cache. Read it from the
---dedicated data_dir injected by init.lua — never from store.base (cache).
local function install_dir()
  if S.deps and S.deps.data_dir then
    local d = S.deps.data_dir
    if type(d) == "function" then
      d = d()
    end
    if type(d) == "string" and d ~= "" then
      return pathutil.join(d, "ktlsp")
    end
  end
  return pathutil.join(config_base(), "kotlin-language-server", "aosp-nav-ktlsp")
end

---Nearest folder holding an Android.bp/Android.mk, walking up from `file`
---but never past `root`. That is the module KLS should treat as its
---workspace (a whole-tree root never finishes indexing under fwcd).
function M.module_dir(file, root)
  local dir = pathutil.parent(pathutil.normalize(file))
  root = pathutil.normalize(root)
  while dir ~= nil and dir ~= "" do
    if
      fs.is_file(pathutil.join(dir, "Android.bp"))
      or fs.is_file(pathutil.join(dir, "Android.mk"))
    then
      return dir
    end
    if dir == root then
      return nil
    end
    local up = pathutil.parent(dir)
    if up == dir then
      return nil
    end
    dir = up
  end
  return nil
end

---Dispatch-script $PWD entries for one AOSP root. KLS is started with the
---nearest module dir as its workspace root (see opts.root_dir above), while
---the jar list is owned by the checkout root. The script matches $PWD
---exactly, so the module dir must be listed as well or `apply()` writes a
---jar list nobody ever cats. `extra_paths` carries the module dir derived
---from the Kotlin file that triggered this apply.
function M.match_paths(root, folders, extra_paths)
  local out = kscript.match_paths_for(root, folders or {})
  local seen = {}
  for _, p in ipairs(out) do
    seen[p] = true
  end
  root = pathutil.normalize(root)
  for _, p in ipairs(extra_paths or {}) do
    if type(p) == "string" and p ~= "" then
      local n = pathutil.normalize(p)
      if (n == root or n:sub(1, #root + 1) == root .. "/") and not seen[n] then
        seen[n] = true
        out[#out + 1] = n
      end
    end
  end
  table.sort(out)
  return out
end

---First JDK 21 on the box (release file says JAVA_VERSION="21").
---Same detection the VS Code extension does before writing `java.home`.
local function find_java21_home()
  local function is21(dir)
    if dir == nil or dir == "" then
      return nil
    end
    local rel = fs.read_file(pathutil.join(dir, "release"))
    if rel and rel:find('JAVA_VERSION="21', 1, true) then
      return dir
    end
    return nil
  end
  local jh = os.getenv("JAVA_HOME")
  local hit = is21(jh)
  if hit then
    return hit
  end
  for _, base in ipairs({ "/usr/lib/jvm", "/Library/Java/JavaVirtualMachines" }) do
    for _, name in ipairs(fs.list_dir(base) or {}) do
      hit = is21(pathutil.join(base, name))
      if hit then
        return hit
      end
    end
  end
  return nil
end

---Convenience wrapper for a `kotlin_language_server` opts table.
---
---Mirrors what the VS Code extension does for the same three problems:
---  * server: ktlsp (winlogon fork) instead of the deprecated fwcd build —
---    the VS Code side writes `kotlin.languageServer.path`, nvim has no such
---    setting, so the bootstrapped binary is substituted into cmd[1] (only
---    for the bare default name; an absolute path you chose wins).
---  * JDK: ktlsp/fwcd parse the JDK version string, and JDK 25 ("25.0.5.1")
---    makes the IntelliJ JavaVersion parser throw during initialize — the
---    VS Code side writes `java.home`, here it is cmd_env.JAVA_HOME.
---  * workspace: nvim-lspconfig only knows gradle/maven/ant markers, which do
---    not exist in an AOSP tree, so KLS ends up with root_dir = nil and
---    answers no definitions. Anchor it at the nearest Android.bp module
---    folder instead (a whole-tree root never finishes indexing under fwcd,
---    measured; the VS Code side can use the window folder because it always
---    runs ktlsp).
---
---Also fills init_options.storagePath: nvim encodes an empty table as `[]`
---and KLS 1.3.13 parses that payload as an object, throwing
---"Expected BEGIN_OBJECT but was BEGIN_ARRAY" in initialize.
---
---Also drops the advertised-but-never-answerable documentHighlight
---capability — but ONLY for buffers under an AOSP root: the compile-sandbox
---throw is an AOSP-file problem (see above), a plain Kotlin project keeps
---the stock documentHighlight behaviour. nvim 0.12 gates buf_request on
---client:supports_method, which reads server_capabilities — setting it to
---false stops the request from ever being sent (an existing user_on_attach
---is chained, not replaced).
function M.lsp_opts(opts)
  opts = opts or {}
  opts.init_options = opts.init_options or {}
  if type(opts.init_options.storagePath) ~= "string" or opts.init_options.storagePath == "" then
    opts.init_options.storagePath = storage_path()
  end

  -- ktlsp when the bootstrap already downloaded it (never override a path
  -- the user wrote themselves).
  local bin = pathutil.join(install_dir(), "server", "bin", "kotlin-language-server")
  if fs.is_file(bin) then
    if type(opts.cmd) == "table" and opts.cmd[1] == "kotlin-language-server" then
      local unpack_ = unpack or table.unpack
      opts.cmd = { unpack_(opts.cmd) }
      opts.cmd[1] = bin
    elseif opts.cmd == nil then
      opts.cmd = { bin }
    end
  end

  -- JDK 21: ktlsp's requirement and the last version fwcd 1.3.13 parses.
  if opts.cmd_env == nil then
    opts.cmd_env = {}
  end
  if opts.cmd_env.JAVA_HOME == nil then
    local jdk = find_java21_home()
    if jdk then
      opts.cmd_env.JAVA_HOME = jdk
    end
  end

  if opts.root_dir == nil then
    local markers = opts.root_markers
    -- nvim always calls root_dir(bufnr, on_dir) and only starts the client
    -- from the callback, so this must be the async form.
    opts.root_dir = function(bufnr, on_dir)
      local dir = nil
      local name = vim.api.nvim_buf_get_name(bufnr or 0)
      if name ~= "" then
        local ar = require("aosp-nav.android_root")
        local root = ar.detect_aosp_root(name, fs.is_dir, fs.is_file)
        if root ~= nil then
          dir = M.module_dir(name, root)
        end
      end
      if dir == nil then
        local m = markers
        if m == nil and vim.lsp and vim.lsp.config and vim.lsp.config.kotlin_language_server then
          m = vim.lsp.config.kotlin_language_server.root_markers
        end
        dir = vim.fs.root(bufnr or 0, m or {})
      end
      on_dir(dir)
    end
  end

  -- documentHighlight: strip only for AOSP buffers (see doc comment above).
  local user_on_attach = opts.on_attach
  opts.on_attach = function(client, bufnr)
    if client.name == "kotlin_language_server" and client.server_capabilities then
      local ok, name = pcall(vim.api.nvim_buf_get_name, bufnr or 0)
      if
        ok
        and name ~= nil
        and name ~= ""
        and require("aosp-nav.android_root").detect_aosp_root(name, fs.is_dir, fs.is_file) ~= nil
      then
        client.server_capabilities.documentHighlightProvider = false
      end
    end
    if user_on_attach then
      user_on_attach(client, bufnr)
    end
  end
  return opts
end

local function shell_quote(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end
M.shell_quote = shell_quote

local function read_if_exists(p)
  return fs.read_file(p)
end

local function write_if_changed(p, content, exec)
  local cur = read_if_exists(p)
  if cur == content then
    return false
  end
  local dir = pathutil.parent(p)
  os.execute(string.format("mkdir -p %s", shell_quote(dir)))
  local f = io.open(p, "w")
  if not f then
    return false
  end
  f:write(content)
  f:close()
  if exec then
    os.execute(string.format("chmod 755 %s", shell_quote(p)))
  else
    os.execute(string.format("chmod 644 %s", shell_quote(p)))
  end
  return true
end

local function rm_rf(p)
  os.execute(string.format("rm -rf %s", shell_quote(p)))
end

-- ----------------------------------------------------------- apply ----

---Write the per-root jar list + the global dispatch script (async flow,
---plain IO — files are small).
---Returns { changed, blocked, jars }.
function M.apply(root, jars, log2, extra_paths)
  local result
  root = pathutil.normalize(root)
  local cfg = S.deps.cfg()
  if not cfg.kotlin.enabled then
    return { changed = false, blocked = true, jars = 0 }
  end
  local ok = pcall(function()
    local script = script_path()
    local current = read_if_exists(script)
    local plan = kscript.plan_takeover(current)

    -- guard: a foreign user-managed script means we must not take over
    if plan.action == "blocked" then
      log(string.format("user-managed %s present, not taking over", script))
      if not S.warned_user_script and S.deps.notify then
        S.warned_user_script = true
        S.deps.notify(
          "[aosp-nav] A user-managed kotlin-language-server classpath script already exists; "
            .. "aosp-nav will not take over the Kotlin classpath channel."
        )
      end
      result = { changed = false, blocked = true, jars = 0 }
      return
    end
    -- other candidates (config dir names x extensions) also block
    for _, cand in ipairs(kscript.all_global_script_candidates(config_base())) do
      if cand ~= script and read_if_exists(cand) then
        log(string.format("user-managed %s present, not taking over", cand))
        if not S.warned_user_script and S.deps.notify then
          S.warned_user_script = true
          S.deps.notify(
            "[aosp-nav] A user-managed kotlin-language-server classpath script already exists; "
              .. "aosp-nav will not take over the Kotlin classpath channel."
          )
        end
        result = { changed = false, blocked = true, jars = 0 }
        return
      end
    end

    -- family takeover: the nvim script becomes our fallback branch
    if plan.action == "takeover-nvim" then
      os.rename(script, nvim_backup_path())
      log("took over the aosp-nav.nvim classpath script (backup: classpath.nvim.bak)")
    end

    -- update the dispatch table (global state)
    local store = S.deps.store
    local g = store:global_load()
    local map = g.kotlin_roots or {}
    local prev = map[root]
    local base_paths = M.match_paths(root, S.deps.workspace_folders(), extra_paths)
    local match_paths
    if prev then
      match_paths = {}
      local seen = {}
      for _, p in ipairs(base_paths) do
        if not seen[p] then
          seen[p] = true
          match_paths[#match_paths + 1] = p
        end
      end
      for _, p in ipairs(prev.match_paths or {}) do
        if not vim.tbl_contains(match_paths, p) then
          match_paths[#match_paths + 1] = p
        end
      end
    else
      match_paths = base_paths
    end
    local entry = {
      hash = hash.djb2(root),
      match_paths = match_paths,
      last_used = os.time() * 1000,
    }
    map[root] = entry
    kscript.trim_map(map)

    -- per-root jar list (content compared before writing)
    local txt = M.jar_list_path_for(root)
    local content = table.concat(jars, ":") .. "\n"
    entry.digest = hash.djb2(content)
    local txt_changed = write_if_changed(txt, content, false)

    -- global dispatch script (re-read: the family takeover renamed it away)
    local now = read_if_exists(script)
    local next_script = kscript.build_script(map, {
      jar_list_path = function(h)
        return pathutil.join(kls_config_dir(), kscript.OWN_DIR, h .. ".txt")
      end,
      nvim_backup_path = nvim_backup_path,
    })
    local script_changed = false
    if now ~= next_script then
      write_if_changed(script, next_script, true)
      script_changed = true
    end

    g.kotlin_roots = map
    store:global_save(g)
    log(
      string.format(
        "%d jars%s%s",
        #jars,
        txt_changed and " written" or "",
        script_changed and ", script updated" or ""
      )
    )
    result = { changed = txt_changed or script_changed, blocked = false, jars = #jars }
  end)
  if not ok then
    log("failed to write classpath channel")
    return { changed = false, blocked = false, jars = 0 }
  end
  return result
end

-- ------------------------------------------------------ kls support ----

---Write the .kls support files for one root (exclusions, .gitignore prune
---block, kls-classpath script).
function M.ensure_kls_support(root, jars)
  root = pathutil.normalize(root)
  local ok, err = pcall(function()
    local extra = {}
    local content, risky = kls.build_exclusions_content(extra)
    if #risky > 0 then
      log(
        string.format(
          "klsExcludes contain names that also occur inside frameworks/packages (%s); "
            .. "real sources under same-named dirs may be dropped from the Kotlin index",
          table.concat(risky, ", ")
        )
      )
    end
    local wrote = write_if_changed(pathutil.join(root, kls.KLS_DIR, kls.EXCL_NAME), content, false)

    -- build-file walk prune: every top-level dir except .kls
    local top_names = {}
    local list = fs.list_dir(root)
    if list then
      for _, n in ipairs(list) do
        local st = fs.stat(pathutil.join(root, n))
        if st and st.is_dir then
          top_names[#top_names + 1] = n
        end
      end
    end
    local gi_path = pathutil.join(root, ".gitignore")
    local prunes = kls.build_prune_list(top_names)
    local next_gi = kls.upsert_gitignore_block(read_if_exists(gi_path), prunes)
    if next_gi then
      if write_if_changed(gi_path, next_gi, false) then
        wrote = true
      end
    end

    local manifest = hash.djb2(table.concat(jars, "\n"))
    local cp = kls.build_kls_classpath(M.jar_list_path_for(root), manifest)
    if write_if_changed(pathutil.join(root, kls.KLS_DIR, kls.CP_NAME), cp, true) then
      wrote = true
    end
    if wrote then
      log("ktlsp exclusions/pruning files ready")
    end
  end)
  if not ok then
    log("failed to write ktlsp support files: " .. tostring(err))
  end
end

---Apply + kls support in one call (the session's kotlin hook).
---`opts.no_bootstrap` is for source-only trees: support files are still
---written, but a Java file open must not download the ~87 MiB ktlsp binary.
---Opening a real .kt file triggers ensure_bootstrap from the FileType hook.
function M.apply_full(root, jars, log2, extra_paths, opts)
  local r = M.apply(root, jars, log2, extra_paths)
  if not r.blocked then
    M.ensure_kls_support(root, jars)
    if not (opts and opts.no_bootstrap) then
      M.ensure_bootstrap()
    end
    M.cleanup_stale_procs()
  end
  return r
end

-- -------------------------------------------------------- bootstrap ----

local function server_bin()
  return pathutil.join(install_dir(), "server", "bin", "kotlin-language-server")
end

---A binary left by an older plugin version must not masquerade as the
---pinned ktlsp: an unversioned (manually installed) binary is left alone,
---but a VERSION that disagrees with KTLSP_VERSION triggers a fresh install.
local function install_status()
  if not fs.is_file(server_bin()) then
    return "missing", nil
  end
  local txt = fs.read_file(pathutil.join(install_dir(), "VERSION"))
  local found = txt and txt:match("^%s*(%S+)") or nil
  if found == nil then
    return "unversioned", nil
  end
  if found ~= kls.KTLSP_VERSION then
    return "stale", found
  end
  return "current", found
end

M._install_status = install_status

---Download the pinned ktlsp server.zip once (curl -L, unzip).
---Runs OFF the main loop under Neovim (vim.fn.jobstart + on_exit); the
---os.execute fallback for non-nvim harnesses stays synchronous on purpose.
---Failures fall back to guiding the user through the manual install and
--- reset the flag so the next Kotlin file retries.
local function run_install_job()
  local zip = pathutil.join(install_dir(), "ktlsp-server.zip")
  local script = string.format(
    "curl -fL --max-time %d -o %s %s 2>/dev/null && unzip -oq %s -d %s 2>/dev/null && chmod 755 %s",
    math.floor(kls.DOWNLOAD_TIMEOUT_MS / 1000),
    shell_quote(zip),
    shell_quote(kls.KTLSP_URL),
    shell_quote(zip),
    shell_quote(install_dir()),
    shell_quote(server_bin())
  )
  if vim and vim.fn and vim.fn.jobstart then
    -- async: never block the editor on an ~87 MiB download
    vim.fn.jobstart({ "sh", "-c", script }, {
      on_exit = function(_, code)
        os.remove(zip)
        if code == 0 and fs.is_file(server_bin()) then
          local vf = io.open(pathutil.join(install_dir(), "VERSION"), "w")
          if vf then
            vf:write(kls.KTLSP_VERSION .. "\n")
            vf:close()
          end
          log(string.format("ktlsp %s installed to %s", kls.KTLSP_VERSION, install_dir()))
          if S.deps.notify then
            S.deps.notify(
              string.format(
                "[aosp-nav] ktlsp installed. Point your kotlin-language-server cmd at:\n  %s",
                server_bin()
              )
            )
          end
        else
          S.bootstrapped = false -- allow a retry on the next Kotlin file
          log("ktlsp bootstrap failed; install it manually per codeberg.org/winlogon/ktlsp")
          warn_bootstrap_failed()
        end
      end,
    })
    return true
  end
  -- synchronous fallback (test harness / non-nvim environments)
  local ok = os.execute(script)
  os.remove(zip)
  return ok == 0 or ok == true
end

function M.ensure_bootstrap()
  if S.bootstrapped then
    return
  end
  S.bootstrapped = true
  local status, found = install_status()
  if status == "current" then
    return
  end
  if status == "unversioned" then
    log("ktlsp binary has no VERSION file (manual install); leaving it untouched")
    return
  end
  local why = status == "stale"
      and string.format("VERSION %s != pinned %s", tostring(found), kls.KTLSP_VERSION)
    or "binary missing"
  log(string.format("ktlsp %s needed (%s); downloading ...", kls.KTLSP_VERSION, why))
  -- 下载是后台过程播报: 只进日志; 装好后那句需要用户改 cmd, 仍然弹窗。
  os.execute(string.format("mkdir -p %s", shell_quote(install_dir())))
  local ok = run_install_job()
  if ok ~= true then
    S.bootstrapped = false
    log("ktlsp bootstrap failed; install it manually per codeberg.org/winlogon/ktlsp")
    warn_bootstrap_failed()
  end
end

-- ------------------------------------------------------------ probe ----

---Diagnostics probe: script state + injected jar count for a root.
function M.probe(root)
  root = pathutil.normalize(root)
  local current = read_if_exists(script_path())
  local state = kscript.script_state(current)
  if state == "none" then
    for _, cand in ipairs(kscript.all_global_script_candidates(config_base())) do
      if cand ~= script_path() and read_if_exists(cand) then
        state = "user"
        break
      end
    end
  end
  local txt = read_if_exists(M.jar_list_path_for(root))
  local jars = 0
  if txt then
    for _ in txt:gmatch("[^:\n]+") do
      jars = jars + 1
    end
  end
  local excl = read_if_exists(pathutil.join(root, kls.KLS_DIR, kls.EXCL_NAME))
  local excl_count = 0
  if excl then
    for line in excl:gmatch("[^\n]+") do
      if line ~= "" and line:sub(1, 1) ~= "#" then
        excl_count = excl_count + 1
      end
    end
  end
  return {
    script = state,
    jars = jars,
    exclusions = excl ~= nil and excl_count or nil,
    gitignore = read_if_exists(pathutil.join(root, ".gitignore")) ~= nil
      and read_if_exists(pathutil.join(root, ".gitignore")):find(kls.GI_BEGIN, 1, true) ~= nil,
    kls_classpath = read_if_exists(pathutil.join(root, kls.KLS_DIR, kls.CP_NAME)) ~= nil,
  }
end

-- ------------------------------------------------------ proc cleanup ----

---Collect a /proc snapshot and kill orphaned kotlin-language-server
---processes under the known AOSP roots (the /proc ancestor-chain scan of
---the nvim original).
function M.cleanup_stale_procs()
  local me = { pid = vim and vim.fn.getpid and vim.fn.getpid() or 0, ppid = nil }
  local list = fs.list_dir("/proc")
  if list == nil then
    return {}
  end
  -- one pass over /proc: read each pid's cmdline ONCE and classify it.
  -- stat (ppid) and the cwd readlink are only pulled for the rare
  -- kotlin-language-server processes — every extra syscall per pid is
  -- multiplied by the whole process table.
  local procs = {}
  local alive_nvim = { me.pid }
  local cmd_by_pid = {}
  for _, name in ipairs(list) do
    local pid = tonumber(name)
    if pid then
      local cmd_text = fs.read_file("/proc/" .. name .. "/cmdline")
      if cmd_text then
        cmd_by_pid[pid] = cmd_text:gsub("%z", " ")
        if cmd_text:find("kotlin%-language%-server") then
          local stat_text = fs.read_file("/proc/" .. name .. "/stat")
          if stat_text then
            -- after the comm field: state ppid ...
            local rest = stat_text:match("%) %a (%d+)")
            local cwd_link = nil
            if vim and (vim.uv or vim.loop) then
              local ok2, link = pcall(function()
                return (vim.uv or vim.loop).fs_readlink("/proc/" .. name .. "/cwd")
              end)
              if ok2 then
                cwd_link = link
              end
            end
            if cwd_link then
              procs[pid] = {
                pid = pid,
                ppid = rest and tonumber(rest) or nil,
                cwd = cwd_link,
                cmd = cmd_text:gsub("%z", " "),
              }
            end
          end
        elseif proc_scan.is_editor_cmdline(cmd_text) then
          alive_nvim[#alive_nvim + 1] = pid
        end
      end
    end
  end
  local roots = {}
  if S.deps and S.deps.store then
    local map = S.deps.store:global_load().kotlin_roots or {}
    for r in pairs(map) do
      roots[#roots + 1] = r
    end
  end
  -- The editor-name set above is only a hint. Walk every KLS candidate's
  -- real parent chain so a server owned by an editor we do not know (emacs,
  -- zed, helix, code-server, ...) is never mistaken for an orphan.
  local function read_proc(pid)
    if type(pid) ~= "number" or pid <= 0 then
      return nil
    end
    local stat_text = fs.read_file("/proc/" .. tostring(pid) .. "/stat")
    if not stat_text then
      return nil
    end
    local rest = stat_text:match("%) %a (%d+)")
    local cmd = cmd_by_pid[pid]
    if cmd == nil then
      local raw = fs.read_file("/proc/" .. tostring(pid) .. "/cmdline")
      cmd = raw and raw:gsub("%z", " ") or ""
      cmd_by_pid[pid] = cmd
    end
    return { pid = pid, ppid = rest and tonumber(rest) or nil, cmd = cmd }
  end
  local stale = proc_scan.find_stale_procs({
    me = me,
    procs = procs,
    alive_nvim = alive_nvim,
    read_proc = read_proc,
  }, roots)
  local killed = {}
  for _, p in ipairs(stale) do
    -- TOCTOU / PID reuse: the process table was snapshotted earlier; between
    -- that read and here the pid may have exited and been recycled. Re-read
    -- its cmdline NOW and only signal if it is still the same KLS. Without
    -- this, a reused pid could be an unrelated process (possibly an editor)
    -- and would be SIGTERM'd by mistake.
    local now = fs.read_file("/proc/" .. p.pid .. "/cmdline")
    if proc_scan.confirm_kill(p, now, roots) then
      log(string.format("killing stale kotlin-language-server pid %d (cwd %s)", p.pid, p.cwd))
      if S.deps and S.deps.kill then
        S.deps.kill(p.pid)
      else
        os.execute(string.format("kill -TERM %d 2>/dev/null", p.pid))
      end
      killed[#killed + 1] = p
    else
      log(string.format("skipped stale pid %d: cmdline changed before kill (PID reused)", p.pid))
    end
  end
  return killed
end

-- ------------------------------------------------------------ prune ----

---Drop paths that no longer exist from the dispatch table and remove
---orphaned jar lists. Only touches a script that already carries our
---marker (a foreign/family script is never hijacked by a prune).
function M.prune()
  local store = S.deps and S.deps.store
  if not store then
    return
  end
  local g = store:global_load()
  local map = g.kotlin_roots
  if map == nil then
    return
  end
  local changed = false
  for root, e in pairs(map) do
    if not fs.is_dir(root) then
      map[root] = nil
      changed = true
    else
      local alive = {}
      for _, p in ipairs(e.match_paths or {}) do
        if p ~= root and p:sub(1, #root + 1) ~= root .. "/" then
          changed = true -- stale metadata outside the root
        elseif fs.is_dir(p) then
          alive[#alive + 1] = p
        else
          changed = true
        end
      end
      local has_root = false
      for _, p in ipairs(alive) do
        if p == root then
          has_root = true
        end
      end
      if not has_root then
        table.insert(alive, 1, root)
        changed = true
      end
      if #alive ~= #(e.match_paths or {}) then
        e.match_paths = alive
        changed = true
      end
    end
  end
  kscript.trim_map(map)
  -- orphaned jar lists
  local dir = pathutil.join(kls_config_dir(), kscript.OWN_DIR)
  local keep = {}
  for _, e in pairs(map) do
    keep[e.hash .. ".txt"] = true
  end
  local files = fs.list_dir(dir)
  if files then
    for _, f in ipairs(files) do
      if f:sub(-4) == ".txt" and not keep[f] then
        os.remove(pathutil.join(dir, f))
        changed = true
      end
    end
  end
  if not changed then
    return
  end
  g.kotlin_roots = map
  store:global_save(g)
  -- rewrite the script only when it is ours
  local script = script_path()
  local current = read_if_exists(script)
  if current and current:find(kscript.SCRIPT_MARKER, 1, true) then
    write_if_changed(
      script,
      kscript.build_script(map, {
        jar_list_path = function(h)
          return pathutil.join(kls_config_dir(), kscript.OWN_DIR, h .. ".txt")
        end,
        nvim_backup_path = nvim_backup_path,
      }),
      true
    )
    log("pruned stale roots, script updated")
  end
end

---Rollback (part of :AospReset).
function M.clear(roots)
  local script = script_path()
  local current = read_if_exists(script)
  if current and current:find(kscript.SCRIPT_MARKER, 1, true) then
    if read_if_exists(nvim_backup_path()) then
      -- restore the aosp-nav.nvim family script we took over
      os.rename(nvim_backup_path(), script)
    else
      os.remove(script)
    end
  end
  rm_rf(pathutil.join(kls_config_dir(), kscript.OWN_DIR))
  for _, root in ipairs(roots or {}) do
    root = pathutil.normalize(root)
    local excl = pathutil.join(root, kls.KLS_DIR, kls.EXCL_NAME)
    if (read_if_exists(excl) or ""):find(kls.EXCL_MARKER, 1, true) then
      os.remove(excl)
    end
    local cp = pathutil.join(root, kls.KLS_DIR, kls.CP_NAME)
    if (read_if_exists(cp) or ""):find("aosp%-nav managed", 1, false) then
      os.remove(cp)
    end
    local kls_dir = pathutil.join(root, kls.KLS_DIR)
    os.execute(string.format("rmdir %s 2>/dev/null", shell_quote(kls_dir)))
    local gi_path = pathutil.join(root, ".gitignore")
    local gi = read_if_exists(gi_path)
    if gi then
      local next_gi = kls.remove_gitignore_block(gi)
      if next_gi ~= gi then
        local f = io.open(gi_path, "w")
        if f then
          f:write(next_gi)
          f:close()
        end
      end
    end
  end
  if S.deps and S.deps.store then
    S.deps.store:global_update(function(g)
      g.kotlin_roots = nil
      return g
    end)
  end
end

function M.known_roots()
  if S.deps and S.deps.store then
    local map = S.deps.store:global_load().kotlin_roots or {}
    local out = {}
    for r in pairs(map) do
      out[#out + 1] = r
    end
    return out
  end
  return {}
end

return M
