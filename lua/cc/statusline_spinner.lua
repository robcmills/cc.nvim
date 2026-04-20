-- Animated spinner driven by session.turn_active and rendered into the
-- statusline (not the output buffer). A per-instance timer advances a frame
-- index and triggers a statusline redraw each tick.
--
-- The spinner is active from the moment the user submits a prompt through
-- the final `result` message (the full "agent is busy" window, including
-- tool execution and permission prompts). On start it also primes a
-- refresh so the first frame appears immediately without waiting one tick.

local M = {}

---@class cc.StatuslineSpinnerState
---@field timer userdata?
---@field frame integer 1-indexed

---@type table<cc.Instance, cc.StatuslineSpinnerState>
local state_by_instance = {}

---@return string[]
local function frames()
  local cfg = require('cc.config').options.statusline or {}
  local sp = cfg.spinner or {}
  if type(sp.frames) == 'table' and #sp.frames > 0 then
    return sp.frames
  end
  local use_nf = sp.use_nerdfont
  if use_nf == nil then use_nf = require('cc.icons').detect_nerdfont() end
  local set = use_nf and sp.frames_nerdfont or sp.frames_unicode
  if type(set) == 'table' and #set > 0 then return set end
  return use_nf and { '\xef\x89\x94' } or { '⏳' }
end

---@return integer
local function interval_ms()
  local cfg = require('cc.config').options.statusline or {}
  local sp = cfg.spinner or {}
  local v = sp.interval_ms
  if type(v) ~= 'number' or v <= 0 then return 120 end
  return math.floor(v)
end

---@param instance cc.Instance
---@return string
function M.current_frame(instance)
  local f = frames()
  local s = state_by_instance[instance]
  local idx = s and s.frame or 1
  if idx < 1 or idx > #f then idx = 1 end
  return f[idx]
end

---@param instance cc.Instance
function M.start(instance)
  if not instance then return end
  local s = state_by_instance[instance]
  if s and s.timer then return end
  s = s or { frame = 1 }
  state_by_instance[instance] = s
  local Statusline = require('cc.statusline')
  local fs = frames()
  local ms = interval_ms()
  local timer = (vim.uv or vim.loop).new_timer()
  s.timer = timer
  timer:start(ms, ms, vim.schedule_wrap(function()
    local cur = state_by_instance[instance]
    if not cur or not cur.timer then return end
    cur.frame = (cur.frame % #fs) + 1
    pcall(Statusline.refresh, instance)
  end))
  pcall(Statusline.refresh, instance)
end

---@param instance cc.Instance
function M.stop(instance)
  if not instance then return end
  local s = state_by_instance[instance]
  if not s then return end
  if s.timer then
    s.timer:stop()
    s.timer:close()
    s.timer = nil
  end
  s.frame = 1
  state_by_instance[instance] = nil
end

--- Sync the spinner to the session's current turn_active state. Safe to call
--- any time; idempotent.
---@param instance cc.Instance
function M.sync(instance)
  if not instance or not instance.session then return end
  if instance.session.turn_active then
    M.start(instance)
  else
    M.stop(instance)
  end
end

--- Test helper.
function M._reset()
  for inst, s in pairs(state_by_instance) do
    if s.timer then pcall(function() s.timer:stop() end); pcall(function() s.timer:close() end) end
    state_by_instance[inst] = nil
  end
end

return M
