-- Per-tool elapsed-time timers. Each function takes an Output instance as
-- self; output.lua attaches them to the Output class so callers use them
-- as instance methods (output:start_tool_timer(id), etc.).
--
-- One clock per Output ticks every running tool, so N tools share one
-- redraw per second. The elapsed value lives in the tool's metadata
-- (meta.elapsed_ms); a header is rewritten only when its text changes and
-- someone can see it. A header hidden inside a closed fold or scrolled off
-- screen is marked stale and written once it comes into view (see the
-- decoration provider at the bottom). Folded summaries read the value from
-- metadata through M.header_text, so they stay current without the write.

local M = {}

local uv = vim.uv or vim.loop

--- Outputs with running tools, keyed by bufnr, for the decoration provider.
---@type table<integer, table>
local outputs = {}

local function interval_ms()
  -- Overridable via cc.config.tool_timer_interval_ms so tests can exercise
  -- the timer path without sleeping a full second.
  local cfg_ok, cfg = pcall(require, 'cc.config')
  return (cfg_ok and cfg.options and cfg.options.tool_timer_interval_ms) or 1000
end

local function stop_clock(self)
  local clock = self._tool_clock
  self._tool_clock = nil
  outputs[self.bufnr] = nil
  if clock and not clock:is_closing() then
    clock:stop()
    clock:close()
  end
end

--- Start tracking a running tool so its header shows live progress
--- regardless of whether the SDK emits tool_progress events. Stopped by
--- stop_tool_timer when the result lands.
---@param tool_use_id string
function M.start(self, tool_use_id)
  if not tool_use_id or tool_use_id == '' then return end
  self._tool_timers = self._tool_timers or {}
  if self._tool_timers[tool_use_id] then return end
  self._tool_timers[tool_use_id] = { start_ms = uv.now() }
  -- Folded tool group headers show a call only while this flag is set.
  local state = require('cc.output')._buf_state[self.bufnr]
  local meta = state and state.tool_blocks[tool_use_id]
  if meta then meta.running = true end
  if self._tool_clock then return end
  local clock = uv.new_timer()
  if not clock then return end
  self._tool_clock = clock
  outputs[self.bufnr] = self
  local interval = interval_ms()
  clock:start(interval, interval, vim.schedule_wrap(function() M.tick(self) end))
end

--- One clock tick: advance every running tool. A tool younger than one
--- interval waits for the next tick, so a header never shows a sub-second
--- value just because it started right before a shared tick.
function M.tick(self)
  if not vim.api.nvim_buf_is_valid(self.bufnr) then
    M.stop_all(self)
    stop_clock(self)
    return
  end
  local now = uv.now()
  local interval = interval_ms()
  local summaries = {}
  for tool_use_id, rec in pairs(self._tool_timers or {}) do
    local elapsed_ms = now - rec.start_ms
    if elapsed_ms >= interval then
      local folds = self:update_tool_elapsed(tool_use_id, elapsed_ms / 1000)
      for _, f in ipairs(folds or {}) do
        summaries[f.winid .. ':' .. f.lnum] = f
      end
    end
  end
  -- A hidden header's value shows only through the foldtext of the closed
  -- fold around it, which Neovim redraws only when that line changes.
  -- Repaint those fold lines, and only when their foldtext changed: many
  -- (a folded Agent turn, say) don't show the timer at all.
  self._summary_text = self._summary_text or {}
  local seen = {}
  for key, f in pairs(summaries) do
    local text = vim.api.nvim_win_call(f.winid, function()
      return vim.fn.foldtextresult(f.lnum)
    end)
    seen[key] = text
    if self._summary_text[key] ~= text then
      pcall(vim.api.nvim__redraw, { win = f.winid, range = { f.lnum - 1, f.lnum } })
    end
  end
  self._summary_text = seen
end

--- Stop tracking a tool. Writes one final elapsed value, even into a hidden
--- header, so every finished tool's header carries its actual duration.
---@param tool_use_id string
function M.stop(self, tool_use_id)
  if not self._tool_timers then return end
  local rec = self._tool_timers[tool_use_id]
  if not rec then return end
  self._tool_timers[tool_use_id] = nil
  local state = require('cc.output')._buf_state[self.bufnr]
  local meta = state and state.tool_blocks[tool_use_id]
  if meta then meta.running = nil end
  if vim.api.nvim_buf_is_valid(self.bufnr) then
    self:update_tool_elapsed(tool_use_id, (uv.now() - rec.start_ms) / 1000, { force = true })
  end
  if self._stale_headers then self._stale_headers[tool_use_id] = nil end
  if next(self._tool_timers) == nil then stop_clock(self) end
end

--- Stop every outstanding tool timer. Called when a turn ends (a `result`
--- message, or an acknowledged interrupt) so a tool whose tool_result never
--- arrives — e.g. a long-running tool aborted mid-flight by an interrupt —
--- doesn't tick forever. Each gets the same final elapsed write stop()
--- does, freezing the header at its actual duration. Keys are collected
--- before stopping since stop() mutates _tool_timers.
function M.stop_all(self)
  if not self._tool_timers then return end
  local ids = {}
  for tool_use_id in pairs(self._tool_timers) do
    ids[#ids + 1] = tool_use_id
  end
  for _, tool_use_id in ipairs(ids) do
    self:stop_tool_timer(tool_use_id)
  end
end

--- A tool header's text with the timer suffix for meta.elapsed_ms
--- (" <icon> Ns [(timeout Ns)]"). This module owns the entire suffix: icon
--- and duration are written and stripped together so the two glyphs never
--- appear apart. Returns `line` unchanged when no elapsed time is recorded.
---@param meta table tool_blocks entry
---@param line string current header line
---@return string
function M.header_text(meta, line)
  local ms = meta.elapsed_ms
  if not ms then return line end
  local timer_icon = require('cc.icons').timer_icon()
  local tre = vim.pesc(timer_icon)
  -- Strip any prior timer suffix off the line. Match either "<icon>..."
  -- (the canonical form this function produces) or a stray "(Ns)" with no
  -- icon (a transient state from prior buggy paths — kept defensive).
  local base = line
    :gsub(' ' .. tre .. '.*$', '')
    :gsub(' %(%d+m?s%)$', '')
  local suffix = ' ' .. timer_icon
  if ms < 1000 then
    suffix = suffix .. string.format(' %dms', ms)
  else
    suffix = suffix .. string.format(' %ds', math.floor(ms / 1000))
  end
  local input = meta.input
  if meta.tool_name == 'Bash' and type(input) == 'table'
      and type(input.timeout) == 'number' and input.timeout > 0 then
    suffix = suffix .. string.format(' (timeout %ds)', math.floor(input.timeout / 1000))
  end
  return base .. suffix
end

--- Whether any window shows header line `lnum`: not inside an enclosing
--- closed fold (a closed fold starting at the header shows its foldtext,
--- which includes the header text) and between w0 and w$. When it is
--- hidden, also returns the on-screen closed fold lines that contain it.
---@param bufnr integer
---@param lnum integer
---@return boolean visible
---@return {winid: integer, lnum: integer}[] folds
local function header_visibility(bufnr, lnum)
  local folds = {}
  for _, winid in ipairs(vim.fn.win_findbuf(bufnr)) do
    local closed = vim.api.nvim_win_call(winid, function()
      return vim.fn.foldclosed(lnum)
    end)
    local shown = closed == -1 and lnum or closed
    if shown >= vim.fn.line('w0', winid) and shown <= vim.fn.line('w$', winid) then
      if shown == lnum then return true, {} end
      folds[#folds + 1] = { winid = winid, lnum = shown }
    end
  end
  return false, folds
end

--- Record a tool's elapsed time and rewrite its header if that changes
--- what someone sees.
---@param tool_use_id string
---@param elapsed_seconds number
---@param opts? {force: boolean} write even if the header is hidden
---@return {winid: integer, lnum: integer}[]? folds closed fold lines that
---  show a hidden header's value through their foldtext
function M.update_elapsed(self, tool_use_id, elapsed_seconds, opts)
  local output = require('cc.output')
  local state = output._buf_state[self.bufnr]
  local meta = state and state.tool_blocks[tool_use_id]
  if not meta or not meta.header_lnum then return end
  -- Elapsed time only goes up; if a larger value is already recorded (e.g.
  -- SDK tool_progress reported 5s while the local timer still says 0s in
  -- synchronous fixture replay), keep the larger value.
  local new_ms = math.floor(elapsed_seconds * 1000)
  if not meta.elapsed_ms or new_ms > meta.elapsed_ms then meta.elapsed_ms = new_ms end
  return M.render(self, tool_use_id, opts and opts.force)
end

--- Bring a tool header's text up to date with its metadata, unless nobody
--- can see it (then mark it stale) or it is already current.
---@param tool_use_id string
---@param force boolean? write even if hidden
---@return {winid: integer, lnum: integer}[]? folds see update_elapsed
function M.render(self, tool_use_id, force)
  local output = require('cc.output')
  local bufnr = self.bufnr
  local state = output._buf_state[bufnr]
  local meta = state and state.tool_blocks[tool_use_id]
  if not meta or not meta.header_lnum then return end
  local lnum = meta.header_lnum
  if lnum > vim.api.nvim_buf_line_count(bufnr) then return end
  local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1]
  if not line then return end
  self._stale_headers = self._stale_headers or {}
  local text = M.header_text(meta, line)
  if text == line then
    self._stale_headers[tool_use_id] = nil
    return
  end
  if not force then
    local visible, folds = header_visibility(bufnr, lnum)
    if not visible then
      self._stale_headers[tool_use_id] = true
      return folds
    end
  end
  self._stale_headers[tool_use_id] = nil
  self:_with_tail_anchor(function()
    -- In-place rewrite of a fold header: see Output:_set_line for why this
    -- must not use nvim_buf_set_lines.
    self:_set_line(lnum, text)
  end, lnum)
  output.refresh_caret(bufnr, lnum)
end

--- Write every stale header that has come into view.
function M.sync_stale(self)
  if not vim.api.nvim_buf_is_valid(self.bufnr) then return end
  for tool_use_id in pairs(self._stale_headers or {}) do
    M.render(self, tool_use_id)
  end
end

-- Reveal path. A stale header can come into view through zo, zR, :CcFold,
-- scrolling, a resize or showing the buffer in a window. Rather than hook
-- each, watch redraws: when a window draws rows that include a stale
-- header, sync stale headers right after the redraw. Buffer writes are not
-- allowed during redraw, hence the schedule.
local NS = vim.api.nvim_create_namespace('cc.tool_timers')
vim.api.nvim_set_decoration_provider(NS, {
  on_win = function(_, _, bufnr, toprow, botrow)
    local self = outputs[bufnr]
    if not self or self._sync_scheduled then return false end
    local stale = self._stale_headers
    if not stale or next(stale) == nil then return false end
    local state = require('cc.output')._buf_state[bufnr]
    if not state then return false end
    for tool_use_id in pairs(stale) do
      local meta = state.tool_blocks[tool_use_id]
      local row = meta and meta.header_lnum and meta.header_lnum - 1
      if row and row >= toprow and row <= botrow then
        self._sync_scheduled = true
        vim.schedule(function()
          self._sync_scheduled = false
          M.sync_stale(self)
        end)
        break
      end
    end
    return false
  end,
})

return M
