-- Animated braille spinner shown as end-of-line extmark on the most recent
-- Agent: header line while streaming. Stops when end_message is called or
-- when the Output's render_result fires.

local M = {}

local NS = vim.api.nvim_create_namespace('cc.spinner')
local FRAMES = { '⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏' }
local INTERVAL_MS = 100

---@class cc.Spinner
---@field bufnr integer
---@field lnum integer 1-indexed
---@field timer userdata?
---@field frame integer
---@field extmark_id integer?
local Spinner = {}
Spinner.__index = Spinner

---@param bufnr integer
---@param lnum integer
---@return cc.Spinner
function M.new(bufnr, lnum)
  return setmetatable({
    bufnr = bufnr,
    lnum = lnum,
    timer = nil,
    frame = 1,
    extmark_id = nil,
  }, Spinner)
end

function Spinner:start()
  if self.timer then return end
  self:_tick()
  self.timer = (vim.uv or vim.loop).new_timer()
  self.timer:start(INTERVAL_MS, INTERVAL_MS, vim.schedule_wrap(function()
    self:_tick()
  end))
end

function Spinner:_tick()
  if not vim.api.nvim_buf_is_valid(self.bufnr) then
    self:stop()
    return
  end
  local line_count = vim.api.nvim_buf_line_count(self.bufnr)
  if self.lnum > line_count then
    self:stop()
    return
  end
  local char = FRAMES[self.frame]
  self.frame = (self.frame % #FRAMES) + 1
  if self.extmark_id then
    pcall(vim.api.nvim_buf_del_extmark, self.bufnr, NS, self.extmark_id)
  end
  local ok, id = pcall(vim.api.nvim_buf_set_extmark, self.bufnr, NS, self.lnum - 1, 0, {
    virt_text = { { '  ' .. char, 'CcSpinner' } },
    virt_text_pos = 'eol',
  })
  if ok then
    self.extmark_id = id
  end
end

function Spinner:stop()
  if self.timer then
    self.timer:stop()
    self.timer:close()
    self.timer = nil
  end
  if self.extmark_id and vim.api.nvim_buf_is_valid(self.bufnr) then
    pcall(vim.api.nvim_buf_del_extmark, self.bufnr, NS, self.extmark_id)
    self.extmark_id = nil
  end
end

M.Spinner = Spinner
return M
