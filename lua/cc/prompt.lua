-- Prompt buffer: editable markdown buffer for composing messages.
-- Submission reads content, clears the buffer, caller forwards to process.

local M = {}

---@class cc.Prompt
---@field bufnr integer
---@field winid integer?
local Prompt = {}
Prompt.__index = Prompt

local BUF_NAME_DEFAULT = 'cc-nvim'

---@param buf_name string? override buffer name (for multiple instances)
function M.new(buf_name)
  return setmetatable({
    bufnr = -1,
    winid = nil,
    buf_name = buf_name or BUF_NAME_DEFAULT,
  }, Prompt)
end

function Prompt:ensure_buffer()
  if self.bufnr > 0 and vim.api.nvim_buf_is_valid(self.bufnr) then
    return self.bufnr
  end
  self.bufnr = vim.api.nvim_create_buf(true, true)
  vim.api.nvim_buf_set_name(self.bufnr, self.buf_name)
  vim.bo[self.bufnr].buftype = 'nofile'
  vim.bo[self.bufnr].bufhidden = 'hide'
  vim.bo[self.bufnr].buflisted = true
  vim.bo[self.bufnr].swapfile = false
  vim.bo[self.bufnr].filetype = 'markdown'

  -- Omnifunc fallback for users without nvim-cmp.
  vim.bo[self.bufnr].omnifunc = "v:lua.require'cc.prompt'.omnifunc"

  self:_setup_window_opts_for_buffer()

  -- If nvim-cmp is available, override buffer-local sources so our slash
  -- source wins over the user's global `path` source (which would otherwise
  -- expand `/` to filesystem paths).
  local ok_cmp, cmp = pcall(require, 'cmp')
  if ok_cmp then
    pcall(function()
      cmp.setup.buffer({
        sources = cmp.config.sources(
          { { name = 'cc_slash' } },
          { { name = 'buffer' } }
        ),
      })
    end)
  end

  return self.bufnr
end

--- Omnifunc for slash command completion. Fallback for users without nvim-cmp.
--- Invoked twice: findstart=1 returns the starting column; findstart=0 with
--- the base prefix returns the matches.
---@param findstart integer 0 | 1
---@param base string? the partial word when findstart=0
---@return integer|table
function M.omnifunc(findstart, base)
  if findstart == 1 then
    local line = vim.api.nvim_get_current_line()
    local col = vim.api.nvim_win_get_cursor(0)[2]
    -- Find the `/` at or before col.
    local before = line:sub(1, col)
    local slash = before:find('/[^%s/]*$')
    if not slash then return -1 end
    return slash - 1 -- 0-indexed start column (omnifunc convention)
  end
  -- findstart == 0: return matches
  local ok_cc, cc = pcall(require, 'cc')
  local session_cmds = ok_cc and cc.get_slash_commands() or nil
  local cmds = require('cc.slash').list(session_cmds)
  local matches = {}
  local prefix = (base or ''):gsub('^/', '')
  for _, c in ipairs(cmds) do
    if prefix == '' or c.name:sub(1, #prefix) == prefix then
      table.insert(matches, {
        word = '/' .. c.name,
        abbr = '/' .. c.name,
        menu = c.description or c.source or '',
      })
    end
  end
  return matches
end

--- Configure window-local options on windows showing this prompt buffer.
function Prompt:_setup_window_opts_for_buffer()
  local bufnr = self.bufnr
  local group = vim.api.nvim_create_augroup('cc.prompt.win.' .. bufnr, { clear = true })
  vim.api.nvim_create_autocmd({ 'BufWinEnter', 'WinEnter' }, {
    group = group,
    buffer = bufnr,
    callback = function()
      local winid = vim.api.nvim_get_current_win()
      if vim.api.nvim_win_get_buf(winid) ~= bufnr then
        return
      end
      local config = require('cc.config').options
      vim.wo[winid].number = config.line_numbers and config.line_numbers.prompt or false
      vim.wo[winid].relativenumber = false
      vim.wo[winid].wrap = config.wrap == nil or config.wrap.prompt ~= false
    end,
  })
end

function Prompt:set_window(winid)
  self.winid = winid
end

--- Read current prompt buffer content as a single string.
---@return string
function Prompt:read()
  local bufnr = self:ensure_buffer()
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  return table.concat(lines, '\n')
end

--- Clear the prompt buffer.
function Prompt:clear()
  local bufnr = self:ensure_buffer()
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { '' })
end

--- Whether the prompt has non-whitespace content.
function Prompt:has_content()
  local text = self:read()
  return text:match('%S') ~= nil
end

M.Prompt = Prompt
return M
