-- t_log.lua: util/log.lua 的契约 —— 阈值、user 档绕过阈值、会话内去重、前缀。
-- 契约来源: refactor 的 "NOTIFICATION POLICY" 段。回归点: 阈值化后
-- 音量与重要性必须重新对齐; once 被阈值挡下时不能"消费"掉登记。
local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
local PLUGIN = vim.fn.fnamemodify(here .. "/..", ":p"):gsub("/$", "")
vim.opt.runtimepath:prepend(PLUGIN)
local H = dofile(here .. "/helper.lua")

local log = require("aosp-nav.util.log")

local ORDER = { debug = 1, info = 2, warn = 3, error = 4, off = 5 }

-- ---------------------------------------------------------------------------
-- a. 阈值: level=warn 时 info/debug 静默, warn/error 出声
-- ---------------------------------------------------------------------------
log.reset()
log.set_level("warn")
H.eq(#H.capture_notify(function() log.info("threshold-info") end), 0,
  "level=warn: log.info 被抑制")
H.eq(#H.capture_notify(function() log.debug("threshold-debug") end), 0,
  "level=warn: log.debug 被抑制")
H.eq(#H.capture_notify(function() log.warn("threshold-warn") end), 1,
  "level=warn: log.warn 出声")
H.eq(#H.capture_notify(function() log.error("threshold-error") end), 1,
  "level=warn: log.error 出声")

-- ---------------------------------------------------------------------------
-- b. user 档绕过阈值: error 与 off 下都必须出声; 而 off 下普通档全静默
-- ---------------------------------------------------------------------------
log.set_level("error")
H.eq(#H.capture_notify(function() log.user("user-at-error") end), 1,
  "log.user 在 level=error 下仍出声")
H.eq(#H.capture_notify(function() log.info("info-at-error") end), 0,
  "level=error: log.info 仍被抑制")

log.set_level("off")
H.eq(#H.capture_notify(function() log.user("user-at-off") end), 1,
  "log.user 在 level=off 下仍出声")
H.eq(#H.capture_notify(function() log.error("error-at-off") end), 0,
  "level=off: log.error 被抑制")

-- ---------------------------------------------------------------------------
-- c. 被阈值挡下的调用不得消费 once 登记 (调高阈值后仍能触发)
-- ---------------------------------------------------------------------------
log.reset()
log.set_level("warn")
H.eq(#H.capture_notify(function() log.info("once-late", { once = true }) end), 0,
  "低于阈值的 once 消息被抑制")
log.set_level("info")
H.eq(#H.capture_notify(function() log.info("once-late", { once = true }) end), 1,
  "事后调高阈值, once 消息仍然触发")
H.eq(#H.capture_notify(function() log.info("once-late", { once = true }) end), 0,
  "已触发的 once 消息不再重复")

-- ---------------------------------------------------------------------------
-- d. "[aosp-nav] " 前缀恰好加一次
-- ---------------------------------------------------------------------------
log.reset()
log.set_level("warn")
local n1 = H.capture_notify(function() log.warn("plain message") end)
H.eq(n1[1] and n1[1].msg, "[aosp-nav] plain message",
  "普通消息会补上 [aosp-nav] 前缀")
local n2 = H.capture_notify(function() log.warn("[aosp-nav] already tagged") end)
H.eq(n2[1] and n2[1].msg, "[aosp-nav] already tagged",
  "已带前缀的消息不再补第二层")
H.eq(#n2 == 1 and H.count(n2[1].msg, "[aosp-nav]"), 1,
  "前缀在最终消息里恰好出现一次")

-- ---------------------------------------------------------------------------
-- e. log.enabled() 与实际是否出声一致 (全阈值 x 全档位矩阵)
-- ---------------------------------------------------------------------------
log.reset()
for _, thresh in ipairs({ "debug", "info", "warn", "error", "off" }) do
  log.set_level(thresh)
  for _, lvl in ipairs({ "debug", "info", "warn", "error" }) do
    local want = ORDER[lvl] >= ORDER[thresh]
    H.eq(log.enabled(lvl), want, ("enabled(%s) at level=%s"):format(lvl, thresh))
    local notes = H.capture_notify(function()
      log[lvl](("emit-%s-%s"):format(thresh, lvl))
    end)
    H.eq(#notes > 0, want, ("%s emitted at level=%s"):format(lvl, thresh))
  end
end

H.finish("t_log")
