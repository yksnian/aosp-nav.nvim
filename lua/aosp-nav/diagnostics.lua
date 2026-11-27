-- diagnostics.lua: structured self-check report (port of the diagnostics
-- command output). Opens a floating scratch buffer with one row per check.

local pathutil = require("aosp-nav.util.path")
local ar = require("aosp-nav.android_root")
local fs = require("aosp-nav.infra.fs")

local M = {}

-- VSCode uses ✓ / ⚠ / - with `→ action:` hints; keep the same reading
-- order here, but add Java / Kotlin / C++ group headers (the VSCode output
-- is one flat list, which gets hard to scan on a real AOSP tree).
local GROUPS = { "General", "Java", "Kotlin", "C/C++" }

local function mark(ok)
  if ok == nil then
    return "-"
  end
  return ok and "✓" or "⚠"
end

-- Count code points and find the byte offset after `limit` of them. Lua 5.1
-- has no utf8 library; treating a stray continuation byte as one character
-- keeps malformed input from looping. `…` occupies one display column.
local function utf8_prefix(s, limit)
  local i, count = 1, 0
  while i <= #s and count < limit do
    local b = string.byte(s, i)
    if b < 0x80 then
      i = i + 1
    elseif b < 0xC0 then -- stray continuation byte
      i = i + 1
    elseif b < 0xE0 then
      i = i + 2
    elseif b < 0xF0 then
      i = i + 3
    else
      i = i + 4
    end
    if i > #s + 1 then
      i = #s + 1
    end
    count = count + 1
  end
  return i - 1, count
end

local function utf8_len(s)
  local _, count = utf8_prefix(s, math.huge)
  return count
end

local function clamp(s, n)
  if n <= 0 then
    return ""
  end
  local _, count = utf8_prefix(s, n + 1)
  if count <= n then
    return s
  end
  local cut = utf8_prefix(s, n - 1)
  return s:sub(1, cut) .. "…"
end

M._clamp = clamp
M._utf8_len = utf8_len

local function split_lines(s)
  local out = {}
  for line in tostring(s or ""):gmatch("[^\n]+") do
    out[#out + 1] = line
  end
  if #out == 0 then
    out[1] = ""
  end
  return out
end

---Collect the report lines (pure data; exported for tests).
function M.collect(D)
  local session = require("aosp-nav.session")
  local guard = require("aosp-nav.java.eclipse_guard")
  local controller = require("aosp-nav.clangd.controller")
  local kotlin = require("aosp-nav.kotlin.channel")
  local S = session._state()

  local function clients_named(name)
    if not (vim and vim.lsp and vim.lsp.get_clients) then
      return {}
    end
    local ok, list = pcall(vim.lsp.get_clients, { name = name })
    return ok and type(list) == "table" and list or {}
  end

  local lines = {}
  local function row(ok, label, detail, action, group, full)
    lines[#lines + 1] = {
      ok = ok,
      label = label,
      detail = detail,
      action = action,
      group = group or "General",
      full = full,
    }
  end

  row(
    true,
    "versions",
    string.format(
      "aosp-nav.nvim %s (neovim %s)",
      session.VERSION,
      vim and vim.version and vim.version().major .. "." .. vim.version().minor or "?"
    )
  )

  -- root (active editor -> workspace folders -> last session)
  local cfg = D.cfg()
  local root, root_source
  local file = vim.api.nvim_buf_get_name(0)
  if file and file ~= "" then
    root = cfg.android_root or ar.detect_aosp_root(file, fs.is_dir, fs.is_file)
    root_source = "active editor"
  end
  if root == nil then
    for _, f in ipairs(D.workspace_folders()) do
      root = cfg.android_root or ar.detect_aosp_root(f, fs.is_dir, fs.is_file)
      if root then
        root_source = "workspace folder"
        break
      end
    end
  end
  if root == nil and S.last_root then
    root = S.last_root
    root_source = "last session"
  end
  local sess = root and S.sessions[pathutil.normalize(root)]
  local phase_label = "no session yet"
  if sess then
    phase_label = sess.phase == "source-only" and "source-only (no build outputs)" or sess.phase
  end
  -- The jar count belongs to the Java "jar source" row; repeating it here
  -- was the most visible duplication in the panel. "active editor" is the
  -- default source and adds nothing; the other two mean root did NOT come
  -- from the open file, which is the case worth diagnosing.
  local root_source_note = root_source
      and root_source ~= "active editor"
      and (" (" .. root_source .. ")")
    or ""
  row(
    root ~= nil,
    "root",
    root ~= nil and string.format("%s%s — %s", root, root_source_note, phase_label)
      or "not detected (no AOSP file open and no AOSP workspace folder)"
  )
  if sess and sess.phase == "source-only" then
    -- The reason for the degraded state is a fact, not a failure: source
    -- roots come from the open file, cross-module jars need a build.
    row(
      nil,
      "build outputs",
      "missing or empty — source-only (module sources from the open file)",
      "build the tree (lunch + m), then :AospRescan for cross-module jars",
      "General"
    )
  end

  -- window scope (the VS Code workspace-folder counterpart): it, not the
  -- root, scopes the module picker, the auto module selection and the
  -- sourcePaths base. The root is always the AOSP tree top — the anchor
  -- of the jar scan and the soong index — exactly like VS Code. The
  -- scope itself: cwd when it sits inside the tree, else the active
  -- file's nearest git project root (scope.lua).
  local wf, wf_src = nil, nil
  if root ~= nil then
    if D.effective_folder then
      local ok, f, source = pcall(D.effective_folder, root)
      if ok and f and f ~= "" then
        wf = pathutil.normalize(f)
        wf_src = source -- "cwd" / "file" from scope.lua; no longer hardcoded
      end
    end
    if wf == nil then
      for _, f in ipairs(D.workspace_folders()) do
        local rel = pathutil.relative(pathutil.normalize(root), pathutil.normalize(f))
        if rel ~= nil then
          wf, wf_src = pathutil.normalize(f), "cwd"
          break
        end
      end
    end
    -- "active file" is the default fallback (cwd outside the tree); it
    -- restates what the path already shows. "cwd" means the user explicitly
    -- :cd'd into a subtree, which explains why scope does not follow the file.
    local src_note = wf_src == "cwd" and "from cwd" or nil
    if wf == nil then
      local cwd = (D.workspace_folders())[1]
      row(
        nil,
        "window scope",
        string.format("%s outside root; scope falls back to the opened file", cwd and cwd or "none"),
        ":cd inside the AOSP tree, then :AospRescan"
      )
    else
      local rel = pathutil.relative(pathutil.normalize(root), wf)
      if rel == "" then
        -- The scope path itself is enough here; the old "picker lists the
        -- whole tree" clause and its action were pure explanation, not state.
        row(
          nil,
          "window scope",
          string.format("%s (root window%s)", wf, src_note and (", " .. src_note) or "")
        )
      else
        row(true, "window scope", string.format("%s (%s)", wf, src_note or wf_src or "scope"))
      end
    end
  end

  if sess and sess.meta then
    local m = sess.meta
    local short = string.format("%s %d ms", m.source == "cache" and "cache hit" or "scan", m.ms)
    local full = short
    if m.verify then
      full = full
        .. string.format(
          " — %d jars checked%s, %d missing",
          m.verify.checked,
          m.verify.sampled and " (sampled)" or "",
          m.verify.missing
        )
    end
    -- sess.meta is written by session._scan_root (the Java jar scan); its
    -- verify counts jars, so this row belongs under Java, not General.
    if sess.phase == "source-only" then
      row(
        nil,
        "jar scan",
        "skipped (no build outputs)",
        nil,
        "Java",
        "source-only: sourcePaths were planned without scanning jars"
      )
    else
      row(nil, "jar scan", short, nil, "Java", full)
    end
  end

  -- Java runtime facts the VSCode panel shows next to the plan: which
  -- jdt.ls is running and whether the start fragment keeps Gradle/Maven off.
  local jclients = clients_named("jdtls")
  local jc = jclients[1]
  local vmargs = {}
  if jc and jc.config and type(jc.config.cmd) == "table" then
    for _, a in ipairs(jc.config.cmd) do
      local v = a:match("^%-%-jvm%-arg=(.*)$") or a:match("^-J(.*)$")
      if v then
        vmargs[#vmargs + 1] = v
      end
    end
  end
  if #jclients > 0 then
    local root_note = jc and jc.config and jc.config.root_dir and ("; root " .. jc.config.root_dir)
      or ""
    local head = string.format("%d client(s)", #jclients)
    local vm = #vmargs > 0 and table.concat(vmargs, " ") or "default"
    local vm_line = "vmargs: " .. vm
    local full = head .. root_note .. "\n" .. vm_line
    -- The panel's reference width is 74 columns and continuation lines are
    -- indented 3. Truncate only when the flags actually overflow one line;
    -- <Tab> reveals the full argv and client root.
    if 3 + utf8_len(vm_line) > 74 then
      -- `…` is one display column but three bytes; clamp() counts code
      -- points, so a non-ASCII path in a flag cannot be cut mid-character.
      vm_line = clamp(vm_line, 74 - 3)
    end
    row(true, "jdtls", head .. "\n" .. vm_line, nil, "Java", full)
  else
    row(nil, "jdtls", "not attached (open a Java file)", nil, "Java")
  end
  local function onoff(v)
    return v == false and "off" or v == true and "on" or "default"
  end
  local imp = sess and sess.settings_fragment and sess.settings_fragment.import
  if imp then
    local g = imp.gradle and imp.gradle.enabled
    local mvn = imp.maven and imp.maven.enabled
    row(
      g == false and mvn == false,
      "java import",
      string.format("gradle=%s, maven=%s", onoff(g), onoff(mvn)),
      nil,
      "Java"
    )
  end
  -- inlayHints is a jdt.ls setting (the plugin disables parameter hints that
  -- trip -32603 on AOSP jars), so it belongs under Java, not General.
  local ih = sess and sess.settings_fragment and sess.settings_fragment.inlayHints
  if ih then
    local mode = ih.parameterNames and ih.parameterNames.enabled or "default"
    row(mode == "none", "inlay hints", mode == "none" and "off" or tostring(mode), nil, "Java")
  end
  -- autobuild is a start-only jdt.ls setting. The fragment and sess.source_paths
  -- are written by the same scan, so recomputing the reason from their count
  -- matches the decision actually sent (scope or sourcePaths threshold).
  if sess and sess.settings_fragment then
    local ab = sess.settings_fragment.autobuild
    local off = ab ~= nil and ab.enabled == false
    local why = ""
    if off then
      local n = sess.source_paths and sess.source_paths.rel_paths and #sess.source_paths.rel_paths
        or 0
      local _, reason = session.autobuild_decision(root, sess.folder, n)
      why = reason and (" — " .. reason) or ""
    end
    -- `on` is jdt.ls's default, not an issue: show it as info. `off` is a
    -- deliberate choice for a large source scope, so it keeps a ✓ mark.
    row(off and true or nil, "java autobuild", (off and "off" or "on") .. why, nil, "Java")
  end

  if sess and sess.plan then
    local p = sess.plan
    local own_note = sess.own_jars_dropped
        and sess.own_jars_dropped > 0
        and string.format(", %d module jar(s) removed (sources injected)", sess.own_jars_dropped)
      or ""
    local injected = string.format("%d jar(s) injected", #sess.jars)
    if sess.phase == "source-only" then
      -- An empty jar list is the designed degraded state, not a failed
      -- fallback: no ✓/⚠ here, just the fact and what it means.
      row(
        nil,
        "jar source",
        "0 injected (source-only)",
        nil,
        "Java",
        "no build outputs: no jar classpath; sourcePaths cover the opened module"
      )
    elseif p.mode == "closure" then
      -- Module selection is reported once, in sourceRootModules below (with
      -- its concrete paths). The reconciliation is diagnostic detail, so
      -- <Tab> reveals it while the default row stays a single count.
      local full = string.format(
        "%d jar(s) injected (%d dropped, %d rescued, %d dangling, %d unbuilt)%s%s",
        #sess.jars,
        p.dropped,
        p.rescued,
        #p.unmapped,
        p.starved,
        own_note,
        p.stubs_kept and "; conflict stubs kept (no framework.jar/core-all.jar provider)" or ""
      )
      row(true, "jar source", injected, nil, "Java", full)
    elseif p.expected then
      -- The scope row already says "root window"; repeating the whole-tree
      -- design and the per-window module rule here was pure explanation.
      row(true, "jar source", injected, nil, "Java", injected .. own_note)
    else
      local detail = string.format("full-list fallback (%s)", p.reason or "unspecified")
      row(false, "jar source", detail, nil, "Java", detail)
    end
  end
  if sess and sess.source_paths then
    local sp = sess.source_paths
    -- The count is the state users scan for; why it was skipped and how it
    -- was pushed are diagnostic detail, revealed by <Tab>.
    local push = ""
    if sess.sp_push then
      push = sess.sp_push.mode == "jars-only" and "push: jars-only"
        or string.format(
          "push: %s (%d pushed, %d skipped)",
          sess.sp_push.mode,
          sess.sp_push.rel,
          sess.sp_push.skipped
        )
    end
    local third = (sp.third_party or 0) > 0
        and string.format("%d third-party roots skipped", sp.third_party)
      or nil
    local source_label = sp.module_source
    if source_label == "explicit" and sess.seeded_defaults then
      source_label = "default (root window)"
    end
    source_label = source_label or "unknown"
    -- `auto` is already said by sourceRootModules' "auto-selected"; only a
    -- non-auto source explains why this set was injected, so keep that.
    if source_label == "auto" then
      source_label = nil
    end
    local injected = #sp.rel_paths
    local outside = sp.skipped_outside
    local bits = {}
    if injected > 0 then
      bits[#bits + 1] = string.format("%d injected", injected)
    end
    if outside > 0 then
      bits[#bits + 1] = string.format("%d outside window", outside)
    end
    if injected == 0 then
      bits[#bits + 1] = "0 injected"
    end
    if third then
      bits[#bits + 1] = third
    end
    if source_label then
      bits[#bits + 1] = "source: " .. source_label
    end
    if push ~= "" then
      bits[#bits + 1] = push
    end
    local short = string.format("%d injected", injected)
    local full = table.concat(bits, ", ")
    if injected == 0 and #sp.abs_paths > 0 then
      -- 模块选择来自别的 scope / 根全部落在窗口外: 本窗口实际 0 个源码根
      row(
        false,
        "sourcePaths",
        short,
        sess.phase == "source-only"
            and "set source_roots or build the tree (lunch + m) for cross-module navigation"
          or "press m to pick modules under this window (or r for auto)",
        "Java",
        full
      )
    else
      row(#sp.abs_paths == 0 and nil or injected > 0, "sourcePaths", short, nil, "Java", full)
    end
  end
  if sess and sess.plan then
    -- report what the plan ACTUALLY used, not the raw config (auto/default
    -- picks never write the selection file — same rule as the VSCode panel)
    local mods = sess.plan.modules or {}
    local auto_pick = sess.plan.auto
      or (sess.source_paths and sess.source_paths.module_source == "auto" and #mods > 0)
    local label = sess.seeded_defaults and "defaults applied"
      or auto_pick and "auto-selected"
      or "selected"
    local preview = {}
    for i = 1, math.min(3, #mods) do
      preview[i] = mods[i]
    end
    -- A zero-module root window is already described by the scope and jar
    -- rows; only an actual selection is worth a line here. Show three module
    -- paths by default; Tab swaps in the full list (see M.open).
    if #mods > 0 then
      -- Name the plan's scope only when it differs from the current window
      -- scope (a :cd without rescan leaves the plan anchored to the old one).
      local plan_scope = sess.folder and pathutil.normalize(sess.folder) or nil
      local scope_note = ""
      if plan_scope and wf and plan_scope ~= wf then
        local rel = root and pathutil.relative(pathutil.normalize(root), plan_scope) or nil
        scope_note = (rel ~= nil and rel ~= "") and (" under " .. rel) or " (whole tree)"
      end
      local header = string.format("%s %d module dir(s)%s:", label, #mods, scope_note)
      local short = header
      for _, m in ipairs(preview) do
        short = short .. "\n" .. m .. ","
      end
      if #mods > 3 then
        short = short:sub(1, -2) .. string.format(", +%d more", #mods - 3)
      else
        short = short:sub(1, -2)
      end
      row(
        true,
        "sourceRootModules",
        short,
        nil,
        "Java",
        header .. "\n" .. table.concat(mods, ",\n")
      )
    end
  end

  -- C/C++ (read-only: never scans or writes a CDB from the panel)
  local cpp = controller.status(root)
  local prebuilt = root and controller.find_aosp_clangd(root) or nil
  local clangds = clients_named("clangd")
  local cc = clangds[1]
  local cc_cmd = cc and cc.config and type(cc.config.cmd) == "table" and cc.config.cmd or nil
  local cdb_arg = nil
  for _, a in ipairs(cc_cmd or {}) do
    if a:find("--compile-commands-dir=", 1, true) then
      cdb_arg = a
      break
    end
  end
  -- The plugin now owns the native/legacy clangd argv wiring, so a missing
  -- client is an informational state (no C/C++ file opened yet), never a
  -- prompt to hand-edit `cmd`. Only report an action when the hook is absent.
  local auto_wired = false
  if vim.lsp and vim.lsp.config and vim.lsp.config.clangd then
    auto_wired = controller.is_native_cmd(vim.lsp.config.clangd.cmd)
  end
  if cc_cmd then
    row(
      true,
      "clangd",
      string.format(
        "%s, %d arg(s)%s",
        cc_cmd[1],
        #cc_cmd,
        cdb_arg and (", " .. cdb_arg) or ", no --compile-commands-dir"
      ),
      nil,
      "C/C++"
    )
  else
    -- A healthy hook is not a finding: show it only when it is missing.
    local detail = auto_wired and "not attached" or "not attached; no aosp-nav argv hook"
    local full = detail
    if prebuilt then
      full = detail .. "; prebuilt: " .. prebuilt
    end
    row(
      nil,
      "clangd",
      detail,
      auto_wired and "open a C/C++ file"
        or prebuilt and "wire lspconfig with aosp-nav.lspconfig_opts()"
        or nil,
      "C/C++",
      full
    )
  end
  local cpp_detail = cpp.origin ~= "none"
      and string.format(
        "%s, %d entries%s",
        cpp.origin,
        cpp.entries,
        cpp.module and (", last module " .. cpp.module) or ""
      )
    or "none (no compdb / module_bp_cc_deps.json / Android.bp)"
  local cpp_full = cpp_detail .. (cpp.cdb_dir and ("; cdb: " .. cpp.cdb_dir) or "")
  row(nil, "cpp origin", cpp_detail, nil, "C/C++", cpp_full)
  if cpp.origin == "cc_deps" then
    row(
      nil,
      "cpp generated headers",
      "no AIDL/protobuf output dirs; android/net/INetd.h errors expected until compdb "
        .. "(SOONG_GEN_COMPDB=1)",
      nil,
      "C/C++"
    )
  end

  -- Kotlin: split script ownership from ktlsp configuration, as in VSCode
  if cfg.kotlin.enabled and root then
    local kp = kotlin.probe(root)
    row(
      kp.script == "ours" or kp.script == "family-nvim",
      "kotlin",
      string.format(
        "on, classpath script: %s (%d jars)%s",
        kp.script,
        kp.jars,
        kp.script == "family-nvim" and ", takeover pending" or ""
      ),
      nil,
      "Kotlin"
    )
    local missing = {}
    if kp.exclusions == nil then
      missing[#missing + 1] = "exclusions"
    end
    if not kp.gitignore then
      missing[#missing + 1] = "gitignore prune"
    end
    if not kp.kls_classpath then
      missing[#missing + 1] = "classpath"
    end
    if #missing > 0 then
      row(false, "kotlin ktlsp", "missing: " .. table.concat(missing, ", "), nil, "Kotlin")
    elseif sess and sess.phase == "source-only" then
      -- Support files are present, so there is no warning; but with no jars
      -- the Kotlin server has no cross-module dependency resolution yet.
      row(
        nil,
        "kotlin ktlsp",
        string.format("%d exclusions; source-only (no Kotlin dependency jars)", kp.exclusions),
        nil,
        "Kotlin"
      )
    else
      row(
        true,
        "kotlin ktlsp",
        string.format("%d exclusions; gitignore prune and classpath present", kp.exclusions),
        nil,
        "Kotlin"
      )
    end
  end

  -- eclipse guard. The physical .project dirs stay on disk BY DESIGN after
  -- the exclusions are written (see core/guard_state.lua), so their count is
  -- information, not an error signal. Only the sticky guard outcome
  -- (get_blocked_count) decides whether a clean is still owed: after a
  -- converged rescan it is 0 and pressing `e` would only tear down a healthy
  -- workspace — and, with a still-live JVM, corrupt it.
  local reports = guard.get_reports()
  local guard_blocked = guard.get_blocked_count()
  if #reports == 0 then
    row(nil, "eclipse guard", "not scanned yet (open an AOSP java file first)")
  else
    for _, r in ipairs(reports) do
      local n = #r.blockers
      local root_note = r.root_blocked and " (root has Eclipse metadata; open a sub-directory)"
        or ""
      -- The ✓ mark already says exclusions are active; the only extra fact
      -- worth keeping is that pressing `e` is not needed.
      local state_note = guard_blocked == 0 and n > 0 and " — no clean needed" or ""
      -- Absolute paths get truncated to an unreadable prefix on a real
      -- checkout; show the path relative to the AOSP root when possible.
      local short = root and pathutil.relative(pathutil.normalize(root), r.folder) or nil
      if short == nil or short == "" then
        short = r.folder
      end
      local label = "eclipse guard [" .. clamp(short, 32) .. "]"
      -- blocked_count is global, reports are per-window. A clean subtree must
      -- stay informational even while another scope owes a clean, otherwise
      -- the panel shows a bogus `⚠ press e` on a row with zero blockers.
      -- A converged clean scope has nothing to act on: hide the row instead
      -- of spending a line saying there is no stale .project dir.
      if n > 0 or r.root_blocked then
        row(
          guard_blocked == 0 and not r.root_blocked,
          label,
          string.format("%d dir(s) excluded from import%s%s", n, root_note, state_note),
          (guard_blocked > 0 or r.root_blocked) and "press e (clean + restart)" or nil
        )
      end
    end
  end
  return lines
end

local function group_of(r)
  if r.group and r.group ~= "General" then
    return r.group
  end
  local l = r.label or ""
  if
    l == "jdtls"
    or l == "java import"
    or l == "inlay hints"
    or l:match("^jar source")
    or l:match("^sourcePaths")
    or l:match("^sourceRootModules")
    or l:match("^eclipse guard")
  then
    return "Java"
  end
  if l:match("^kotlin") then
    return "Kotlin"
  end
  if l == "clangd" or l:match("^cpp") then
    return "C/C++"
  end
  return "General"
end

function M.render(lines, show_all)
  local out = { "aosp-nav diagnostics", string.rep("─", 74) }
  for _, group in ipairs(GROUPS) do
    local section = {}
    for _, r in ipairs(lines) do
      if group_of(r) == group then
        section[#section + 1] = r
      end
    end
    if #section > 0 then
      out[#out + 1] = ""
      out[#out + 1] = group
      for _, r in ipairs(section) do
        local parts = split_lines((show_all and r.full or nil) or r.detail)
        out[#out + 1] = string.format(" %s %s: %s", mark(r.ok), r.label, parts[1])
        for i = 2, #parts do
          out[#out + 1] = "   " .. parts[i]
        end
        if r.action then
          out[#out + 1] = string.format("   → %s", r.action)
        end
      end
    end
  end
  out[#out + 1] = ""
  out[#out + 1] = string.rep("─", 74)
  out[#out + 1] = "✓ ok   ⚠ warning   - info"
  out[#out + 1] =
    "Tab full details   e fix guard   m modules   r rescan (! reloads jdt.ls)   L log   q close"
  return table.concat(out, "\n")
end

---Floating window width. On a large editor, stay close to the report body
---(74 columns) instead of stretching to 160. On a small/non-maximized editor,
---shrink with it and never exceed the available columns.
function M._panel_width(ui_width)
  local w = ui_width or 120
  local target = math.min(112, w - 16)
  return math.min(w - 2, math.max(24, target))
end

function M.open(D)
  local lines = M.collect(D)
  local content = split_lines(M.render(lines))
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  local ui = vim.api.nvim_list_uis()[1]
  local width = M._panel_width(ui and ui.width or nil)
  -- fit the whole report on screen (no scrolling)
  local height = math.min((ui and ui.height or 40) - 4, math.max(24, #content + 2))
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor(((ui and ui.height or 40) - height) / 2),
    col = math.floor(((ui and ui.width or 120) - width) / 2),
    style = "minimal",
    border = "rounded",
    title = " aosp-nav diagnostics (q to close) ",
    title_pos = "center",
  })
  -- Long rows wrap under the mark column (VSCode-style " ✓ label: detail").
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].breakindent = true
  vim.wo[win].breakindentopt = "shift:3"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, content)
  vim.bo[buf].modifiable = false
  local expanded = false
  local function draw()
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, split_lines(M.render(lines, expanded)))
    vim.bo[buf].modifiable = false
  end
  local function close()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end
  -- 面板动作: 命令面收敛到 4 个后, 其余入口就是这里 (nvim 习惯: 一个浮窗
  -- 加单键动作, 而不是命令面板).
  local actions = {
    ["<Tab>"] = function()
      expanded = not expanded
      draw()
    end,
    q = close,
    e = function()
      close()
      require("aosp-nav.commands").fix_eclipse()
    end,
    m = function()
      close()
      require("aosp-nav.commands").select_modules()
    end,
    r = function()
      close()
      require("aosp-nav.commands").rescan()
    end,
    L = function()
      close()
      require("aosp-nav.commands").open_log()
    end,
  }
  for lhs, fn in pairs(actions) do
    vim.keymap.set("n", lhs, fn, { buffer = buf, noremap = true, silent = true, nowait = true })
  end
end

return M
