-- java/module_picker.lua: dependency-free multi-select module picker
-- (port of src/jdtls/modulePicker.ts, adapted to a floating-window UI).
--
-- The user picks MODULES; the plugin maps them to source roots through the
-- soong build index. Checkboxes are seeded from what the session ACTUALLY
-- applied (session plan.modules), not from the persisted pick alone: a
-- stale/empty record must never make an active injection look unchecked,
-- and confirming an unchanged list must be a no-op. `[a]` = auto-derived
-- (current plan), `[x]` = your pick, `[ ]` = off.
--
-- Candidates are the module dirs under the window that own at least one
-- first-party source root (a module without one only navigates through
-- jars, so checking it could never change sourcePaths). Modules deeper
-- than M.VISIBLE_DEPTH are collapsed behind Tab; `/` searches all of them.
--
-- Keys: <Space> toggle, / filter, Tab expand/collapse, r back to auto,
-- <CR> accept (no-op when nothing changed), q/<Esc> cancel (state untouched).

local config_mod = require("aosp-nav.config")
local pathutil = require("aosp-nav.util.path")
local mi = require("aosp-nav.jar.module_index")
local module_selection = require("aosp-nav.java.module_selection")
local fs = require("aosp-nav.infra.fs")

local M = {}

---Modules deeper than this (segments below the window) are collapsed.
M.VISIBLE_DEPTH = 1
M.MAX_HEIGHT = 34

local function seg_count(rel)
  local n = 0
  for _ in rel:gmatch("[^/]+") do
    n = n + 1
  end
  return n
end

---An empty saved list means "no explicit pick" (older versions could write
---it when the picker was confirmed with nothing checked). Treating it as an
---explicit empty selection silently wiped a working auto selection.
local function normalize_selection(list)
  if list == nil or #list == 0 then
    return nil
  end
  return list
end

---Initial checkboxes when no live session is available: explicit picks win;
---a ROOT window with nothing picked checks the seeded defaults; a SUBTREE
---window checks the per-folder auto selection. Pure logic, exported for tests.
function M.default_checked(index, root, folder, explicit, import_exclusions)
  explicit = normalize_selection(explicit)
  if explicit ~= nil then
    return explicit
  end
  local checked = {}
  local root_window = pathutil.relative(pathutil.normalize(root), pathutil.normalize(folder)) == ""
  if root_window then
    for _, m in ipairs(config_mod.DEFAULT_ROOT_MODULES) do
      checked[#checked + 1] = m
    end
    return checked
  end
  local scoped = mi.scoped_import_exclusions(import_exclusions or {}, { folder })
  return mi.auto_modules_for_folder(index, root, folder, scoped)
end

-- Candidate list memo (weak keys: the index is process-cached and immutable
-- for a given build, so the list only depends on the window folder and the
-- exclusion fingerprint). `open` copies the array before sorting/appending,
-- so the cached order stays stable.
local candidates_cache = setmetatable({}, { __mode = "k" })

local function candidates_key(folder, import_exclusions)
  local ex = import_exclusions or {}
  if #ex == 0 then
    return folder
  end
  return folder .. "\1" .. table.concat(ex, "\0")
end

---Picker candidates: module dirs under the window that own at least one
---first-party root. depth = path segments below the window (the collapse
---key). Excluded (eclipse guard) dirs stay out, as before.
local function list_modules(index, aosp_root, folder, import_exclusions)
  local per_index = candidates_cache[index]
  if per_index == nil then
    per_index = {}
    candidates_cache[index] = per_index
  end
  local key = candidates_key(folder, import_exclusions)
  local hit = per_index[key]
  if hit then
    return hit
  end
  local root_window = pathutil.relative(pathutil.normalize(aosp_root), pathutil.normalize(folder))
    == ""
  local has_excl = import_exclusions ~= nil and #import_exclusions > 0
  local compiled_excl = has_excl and mi.compile_import_exclusions(import_exclusions) or nil
  local out = {}
  for _, dir_rel in ipairs(index.by_path_order) do
    local dir_abs = pathutil.join(aosp_root, dir_rel)
    local rel = root_window and dir_rel or pathutil.relative(pathutil.normalize(folder), dir_abs)
    if rel ~= nil and not (has_excl and mi.find_import_exclusion_in(dir_abs, compiled_excl)) then
      -- 0 首方根的模块注入后不产生任何 sourcePath (只能 jar 导航):
      -- 列出来只会让人勾了没效果, 所以不进默认候选集。
      -- 只做布尔判定 (提前退出), 根的完整集合留到行渲染时按需取。
      if mi.path_has_first_party(index, dir_rel) then
        out[#out + 1] = { dir = dir_rel, depth = seg_count(rel) }
      end
    end
  end
  per_index[key] = out
  return out
end

---Candidate list (exported for tests): jar-only modules are dropped here.
M.list_candidates = list_modules

---The window scope for the picker: the effective folder (scope.lua — the
---VS Code workspace folder), falling back to the first workspace folder
---inside the root.
local function picker_folder(root, deps)
  if deps.effective_folder then
    local ok, f = pcall(deps.effective_folder, root)
    if ok and f and f ~= "" then
      return pathutil.normalize(f)
    end
  end
  local folder = root
  for _, f in ipairs(deps.workspace_folders()) do
    if pathutil.relative(root, pathutil.normalize(f)) ~= nil then
      folder = f
      break
    end
  end
  return pathutil.normalize(folder)
end

---Checkbox baseline: the live plan wins (what the session really applied —
---auto, seeded root defaults or an explicit pick), then the persisted pick,
---then the derived default. Exported for tests.
function M.resolve_baseline(index, root, folder, stored, import_exclusions, effective)
  if type(effective) == "table" and #effective > 0 then
    return effective
  end
  return M.default_checked(index, root, folder, stored, import_exclusions)
end

local function same_set(a, b)
  if #a ~= #b then
    return false
  end
  local seen = {}
  for _, v in ipairs(a) do
    seen[v] = true
  end
  for _, v in ipairs(b) do
    if not seen[v] then
      return false
    end
  end
  return true
end

---Open the picker for one AOSP root (wired by init to session deps).
---deps: { cfg, store, log, notify, effective_folder?,
---        effective_modules = fn(root, folder) -> module dirs | nil,
---        apply_selection = fn }
function M.open(root, deps)
  root = pathutil.normalize(root)
  local cfg = deps.cfg()
  local folder = picker_folder(root, deps)
  local io_ = fs.io()
  local index = mi.load_index(root, deps.log, io_.read_file, io_.decode, io_.stat)
  if index == nil then
    deps.notify("[aosp-nav] out/soong/module_bp_java_deps.json not found — build the tree first.")
    return
  end
  local import_exclusions = cfg._guard_exclusions or {}
  -- copy: the list is memoized per index and `open` appends/sorts in place
  local modules = {}
  for _, m in ipairs(list_modules(index, root, folder, import_exclusions)) do
    modules[#modules + 1] = m
  end

  local g = deps.store:load(root)
  -- 显式选择按窗口 scope 存: 本窗口只看到本窗口的选择 (旧全局清单里落在
  -- 本 scope 之外的条目一律忽略, 不提示)。
  local stored = module_selection.get(g, root, folder)
  local explicit_mode = stored ~= nil

  -- 勾选态从"实际生效的结果"反推: 会话 plan 里的 modules 就是当前真正
  -- 应用的集合 (auto / 根窗口 seed / 显式)。只读持久化记录正是 vscode 版
  -- 的老毛病: 记录为空/过期时, 已经生效的注入会显示成全未勾。
  local effective = nil
  if deps.effective_modules then
    local ok, mods = pcall(deps.effective_modules, root, folder)
    if ok and type(mods) == "table" then
      effective = mods
    end
  end
  local baseline = M.resolve_baseline(index, root, folder, stored, import_exclusions, effective)
  local base_set = {}
  local selected = {}
  for _, m in ipairs(baseline) do
    base_set[m] = true
    selected[m] = true
  end

  -- baseline may hold modules outside the candidate set (legacy explicit
  -- picks of jar-only or out-of-scope dirs): keep them visible so they can
  -- be unchecked.
  local have = {}
  for _, m in ipairs(modules) do
    have[m.dir] = true
  end
  for _, m in ipairs(baseline) do
    if not have[m] then
      modules[#modules + 1] = { dir = m, depth = 0 }
    end
  end

  -- order: checked first, then by dir (fixed at open time: live re-sort
  -- would lose the cursor position)
  table.sort(modules, function(a, b)
    local a_sel = selected[a.dir] == true
    local b_sel = selected[b.dir] == true
    if a_sel ~= b_sel then
      return a_sel
    end
    return a.dir < b.dir
  end)

  -- --------------------------------------------------------- UI ----
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  local scope_rel = pathutil.relative(root, folder)
  local where = (scope_rel ~= nil and scope_rel ~= "") and ("under " .. scope_rel) or "whole tree"
  local title =
    string.format(" aosp-nav: modules %s — %s ", where, explicit_mode and "[yours] " or "[auto] ")

  local filter = nil -- nil = unfiltered
  local show_all = false

  local function matches_filter(m)
    return filter == nil or m.dir:lower():find(filter, 1, true) ~= nil
  end

  -- filter searches every candidate; otherwise only shallow rows plus the
  -- checked ones are listed
  local function visible(m)
    if filter ~= nil then
      return matches_filter(m)
    end
    if selected[m.dir] then
      return true
    end
    return show_all or m.depth <= M.VISIBLE_DEPTH
  end

  local function visible_rows()
    local out = {}
    for _, m in ipairs(modules) do
      if visible(m) then
        out[#out + 1] = m
      end
    end
    return out
  end

  local function hidden_count()
    return #modules - #visible_rows()
  end

  local function row_text(m)
    -- roots are materialized lazily: the candidate filter only needed the
    -- boolean, and the full (sorted) root list is memoized per dir anyway
    local n = #mi.roots_for_path(index, m.dir).first_party
    local note
    if n == 0 then
      note = "jar only — no source roots"
    else
      note = string.format("%d first-party root%s", n, n == 1 and "" or "s")
    end
    local mark
    if not selected[m.dir] then
      mark = "[ ]"
    elseif explicit_mode or not base_set[m.dir] then
      mark = "[x]"
    else
      mark = "[a]"
    end
    return string.format("%s %s  (%s)", mark, m.dir, note)
  end

  local function build_lines()
    local lines = {}
    for _, m in ipairs(visible_rows()) do
      lines[#lines + 1] = row_text(m)
    end
    if #lines == 0 then
      lines[1] = filter and ("(no module dir matches /" .. filter .. "/)")
        or "(no modules with source roots under the window scope)"
    end
    if filter == nil and not show_all and hidden_count() > 0 then
      lines[#lines + 1] =
        string.format("… %d deeper module(s) hidden — Tab to expand", hidden_count())
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = "[a] auto (current plan)   [x] your pick   [ ] off"
    lines[#lines + 1] = "<Space> toggle  / filter  Tab expand  r auto  <CR> accept  q cancel"
    return lines
  end

  local width = math.min(140, math.max(96, #title + 2))
  local ui = vim.api.nvim_list_uis()[1]
  local row0 = 0
  local col0 = 0
  local function height_for()
    local n = #build_lines()
    return math.min(M.MAX_HEIGHT, math.max(10, n + 2))
  end
  local height = height_for()
  row0 = math.floor(((ui and ui.height or 40) - height) / 2)
  col0 = math.floor(((ui and ui.width or 120) - width) / 2)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = row0,
    col = col0,
    style = "minimal",
    border = "rounded",
    title = title,
    title_pos = "center",
  })

  ---Redraw and keep the cursor on the same module. build_lines() is a full
  ---replacement, so a filter/expand/toggle that removes rows above the cursor
  ---would otherwise leave it pointing at a different row (or a footer), and
  ---the next <Space> would toggle the wrong module.
  local function render(anchor_dir)
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, build_lines())
    vim.bo[buf].modifiable = false
    pcall(vim.api.nvim_win_set_config, win, {
      relative = "editor",
      width = width,
      height = height_for(),
      row = row0,
      col = col0,
      style = "minimal",
      border = "rounded",
      title = title,
      title_pos = "center",
    })
    if anchor_dir ~= nil then
      local target = 1
      for i, m in ipairs(visible_rows()) do
        if m.dir == anchor_dir then
          target = i
          break
        end
      end
      pcall(vim.api.nvim_win_set_cursor, win, { target, 0 })
    end
  end

  ---The module currently under the cursor, or nil on a footer/empty line.
  local function cursor_dir()
    local row = vim.api.nvim_win_get_cursor(win)[1]
    local m = visible_rows()[row]
    return m and m.dir or nil
  end

  render()

  local function close()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end

  local function confirm()
    local picked = {}
    for _, m in ipairs(modules) do
      if selected[m.dir] then
        picked[#picked + 1] = m.dir
      end
    end
    table.sort(picked)
    local base = {}
    for _, m in ipairs(baseline) do
      base[#base + 1] = m
    end
    table.sort(base)
    close()
    if same_set(picked, base) then
      -- 没有改动: 不写状态, 不重跑注入 (空确认绝不能变成"清空选择")。
      return
    end
    module_selection.set(deps.store, root, folder, picked)
    deps.apply_selection(root)
  end

  ---Reset to the AUTO selection: forget the explicit pick so the per-scope
  ---auto set applies. Already-auto is a no-op.
  local function reset_to_auto()
    close()
    if not explicit_mode then
      return
    end
    module_selection.set(deps.store, root, folder, nil)
    deps.apply_selection(root)
  end

  local keymap_opts = { noremap = true, silent = true, buffer = buf }
  vim.keymap.set("n", "<Space>", function()
    local row = vim.api.nvim_win_get_cursor(win)[1]
    local m = visible_rows()[row]
    if not m then
      return -- footer line
    end
    selected[m.dir] = not selected[m.dir]
    render(m.dir)
  end, keymap_opts)
  vim.keymap.set("n", "/", function()
    local ok, pat = pcall(function()
      return vim.fn.input({ prompt = "filter: " })
    end)
    if not ok or pat == nil then
      return
    end
    local anchor = cursor_dir()
    filter = (pat == "") and nil or pat:lower()
    render(anchor)
  end, keymap_opts)
  vim.keymap.set("n", "<Tab>", function()
    local anchor = cursor_dir()
    show_all = not show_all
    render(anchor)
  end, keymap_opts)
  vim.keymap.set("n", "r", reset_to_auto, keymap_opts)
  vim.keymap.set("n", "<CR>", confirm, keymap_opts)
  vim.keymap.set("n", "q", close, keymap_opts)
  vim.keymap.set("n", "<Esc>", close, keymap_opts)
end

return M
