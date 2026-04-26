-- Cached probes of claude CLI versions:
--   M.get()        — installed version (from `claude --version`)
--   M.get_latest() — latest version on the npm registry

local M = {}

local cached ---@type string?
local probed = false

local cached_latest ---@type string?
local probed_latest = false
local probing_latest = false
local latest_callbacks = {} ---@type function[]

---@param on_done function?
local function probe(on_done)
  local cmd = require('cc.config').options.claude_cmd
  if vim.fn.executable(cmd) ~= 1 then
    cached = nil
    probed = true
    return
  end
  vim.system(
    { cmd, '--version' },
    { text = true },
    vim.schedule_wrap(function(res)
      probed = true
      if res and res.code == 0 and res.stdout then
        cached = res.stdout:match('(%d+%.%d+%.%d+)')
      end
      if on_done then pcall(on_done) end
    end)
  )
end

local function probe_latest()
  if probing_latest or probed_latest then return end
  if vim.fn.executable('curl') ~= 1 then
    probed_latest = true
    return
  end
  probing_latest = true
  vim.system(
    {
      'curl', '-fsSL', '--max-time', '3',
      'https://registry.npmjs.org/@anthropic-ai/claude-code/latest',
    },
    { text = true },
    vim.schedule_wrap(function(res)
      probing_latest = false
      probed_latest = true
      if res and res.code == 0 and res.stdout then
        cached_latest = res.stdout:match('"version"%s*:%s*"([%d%.]+)"')
      end
      local cbs = latest_callbacks
      latest_callbacks = {}
      for _, cb in ipairs(cbs) do pcall(cb) end
    end)
  )
end

---@param on_update function? called if the background probe populates the value
---@return string?
function M.get(on_update)
  if not probed then
    probe(on_update)
  end
  return cached
end

--- Latest version of @anthropic-ai/claude-code on the npm registry.
--- Probes once per nvim session; returns nil while probing or on failure.
---@param on_update function? called when the background probe completes
---@return string?
function M.get_latest(on_update)
  if not probed_latest then
    if on_update then table.insert(latest_callbacks, on_update) end
    probe_latest()
  end
  return cached_latest
end

--- For tests.
function M._reset()
  cached = nil
  probed = false
  cached_latest = nil
  probed_latest = false
  probing_latest = false
  latest_callbacks = {}
end

return M
