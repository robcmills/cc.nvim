-- Save/restore window-local options so cc's overrides don't leak to other
-- buffers that later occupy the same window (e.g. after `gf` or :edit).
--
-- Neovim's window-local options stick with the WINDOW, not the buffer. So
-- when cc sets `number=false` via vim.wo[winid], and the user replaces the
-- cc buffer in that window, the new buffer inherits `number=false`. The
-- fix is to snapshot the prior values on entry and restore them on
-- BufWinLeave (which fires when the buffer is replaced in the window but
-- not on mere focus changes between windows).

local M = {}

--- Snapshot the current window-local values for the given option names
--- into window variables keyed by `token`. Idempotent per (winid, token).
---@param winid integer
---@param token string namespace so multiple callers can coexist
---@param names string[]
function M.save(winid, token, names)
  local flag = 'cc_winopts_saved_' .. token
  if vim.w[winid][flag] then return end
  for _, name in ipairs(names) do
    vim.w[winid]['cc_winopts_' .. token .. '_' .. name] = vim.wo[winid][name]
  end
  vim.w[winid][flag] = true
end

--- Like `save`, but record values from a caller-provided table. Use this
--- when the window-local values aren't reliable (e.g. the window was
--- created via `:split` from another cc window and inherited cc's
--- overrides) and vim.go is also corrupted (some "g+l" options like
--- 'number' route vim.wo writes to the global too). Caller is expected
--- to have captured the user's actual defaults at a clean moment.
---@param winid integer
---@param token string
---@param names string[]
---@param values table<string, any>
function M.save_table(winid, token, names, values)
  local flag = 'cc_winopts_saved_' .. token
  if vim.w[winid][flag] then return end
  for _, name in ipairs(names) do
    if values[name] ~= nil then
      vim.w[winid]['cc_winopts_' .. token .. '_' .. name] = values[name]
    end
  end
  vim.w[winid][flag] = true
end

--- Restore previously-saved values and clear the snapshot flag.
---@param winid integer
---@param token string
---@param names string[]
function M.restore(winid, token, names)
  if not vim.api.nvim_win_is_valid(winid) then return end
  local flag = 'cc_winopts_saved_' .. token
  if not vim.w[winid][flag] then return end
  for _, name in ipairs(names) do
    local key = 'cc_winopts_' .. token .. '_' .. name
    local v = vim.w[winid][key]
    if v ~= nil then
      vim.wo[winid][name] = v
    end
    vim.w[winid][key] = nil
  end
  vim.w[winid][flag] = nil
end

return M
