-- Cached probe of the claude CLI version.

local M = {}

local cached ---@type string?
local probed = false

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

---@param on_update function? called if the background probe populates the value
---@return string?
function M.get(on_update)
  if not probed then
    probe(on_update)
  end
  return cached
end

--- For tests.
function M._reset()
  cached = nil
  probed = false
end

return M
