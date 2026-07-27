-- Cached probes of provider CLI versions:
--   M.get(cb, cmd) — installed version (from `<cmd> --version`); cmd
--                    defaults to the configured claude binary
--   M.get_latest() — latest claude-code version on the npm registry
--                    (Claude-specific; never probed for other providers)

local M = {}
local Command = require('cc.command')

---@type table<string, { probed: boolean, value: string? }>
local by_cmd = {}

local cached_latest ---@type string?
local probed_latest = false
local probing_latest = false
local latest_callbacks = {} ---@type function[]

---@param cmd string
---@param on_done function?
local function probe(cmd, on_done)
  local entry = by_cmd[cmd]
  vim.system(
    Command.argv(cmd, { '--version' }),
    { text = true },
    vim.schedule_wrap(function(res)
      entry.probed = true
      if res and res.code == 0 and res.stdout then
        entry.value = res.stdout:match('(%d+%.%d+%.%d+)')
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
---@param cmd string? CLI binary to probe; defaults to the configured Claude cmd
---@return string?
function M.get(on_update, cmd)
  cmd = cmd or require('cc.providers.claude').options().cmd
  local entry = by_cmd[cmd]
  if not entry then
    entry = { probed = false, value = nil }
    by_cmd[cmd] = entry
    probe(cmd, on_update)
  end
  return entry.value
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
  by_cmd = {}
  cached_latest = nil
  probed_latest = false
  probing_latest = false
  latest_callbacks = {}
end

return M
