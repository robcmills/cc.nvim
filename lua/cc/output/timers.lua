-- Per-tool elapsed-time timers. Each function takes an Output instance as
-- self; output.lua attaches them to the Output class so callers use them
-- as instance methods (output:start_tool_timer(id), etc.).

local M = {}

--- Start a local timer that ticks update_tool_elapsed every second so the
--- tool header shows live progress regardless of whether the SDK emits
--- tool_progress events. Stopped by stop_tool_timer when the result lands.
---@param tool_use_id string
function M.start(self, tool_use_id)
  if not tool_use_id or tool_use_id == '' then return end
  self._tool_timers = self._tool_timers or {}
  if self._tool_timers[tool_use_id] then return end
  local uv = vim.uv or vim.loop
  local timer = uv.new_timer()
  if not timer then return end
  local rec = { timer = timer, start_ms = uv.now() }
  self._tool_timers[tool_use_id] = rec
  timer:start(1000, 1000, vim.schedule_wrap(function()
    if not vim.api.nvim_buf_is_valid(self.bufnr) then
      self:stop_tool_timer(tool_use_id)
      return
    end
    local elapsed = (uv.now() - rec.start_ms) / 1000
    self:update_tool_elapsed(tool_use_id, elapsed)
  end))
end

--- Stop and close the local timer for a tool, if any. Writes one final
--- elapsed-time tick so even tools that finished in under a second show
--- a (Ns) suffix matching their actual duration.
---@param tool_use_id string
function M.stop(self, tool_use_id)
  if not self._tool_timers then return end
  local rec = self._tool_timers[tool_use_id]
  if not rec then return end
  self._tool_timers[tool_use_id] = nil
  if vim.api.nvim_buf_is_valid(self.bufnr) then
    local uv = vim.uv or vim.loop
    self:update_tool_elapsed(tool_use_id, (uv.now() - rec.start_ms) / 1000)
  end
  if not rec.timer:is_closing() then
    rec.timer:stop()
    rec.timer:close()
  end
end

--- Update a tool header line in-place with the timer suffix
--- (" <icon> [timeout Ns] (Ns)"). This function owns the entire timer
--- suffix — icon and duration are written and stripped together so the
--- two glyphs never appear apart.
---@param tool_use_id string
---@param elapsed_seconds number
function M.update_elapsed(self, tool_use_id, elapsed_seconds)
  local output = require('cc.output')
  local state = output._buf_state[self.bufnr]
  local meta = state and state.tool_blocks[tool_use_id]
  if not meta or not meta.header_lnum then return end
  local bufnr = self.bufnr
  if meta.header_lnum > vim.api.nvim_buf_line_count(bufnr) then return end
  local lines = vim.api.nvim_buf_get_lines(bufnr, meta.header_lnum - 1, meta.header_lnum, false)
  if not lines[1] then return end
  local new_ms = math.floor(elapsed_seconds * 1000)
  -- Elapsed time only goes up; if a larger value is already displayed
  -- (e.g. SDK tool_progress reported 5s while the local timer still says 0s
  -- in synchronous fixture replay), keep the larger value.
  local cur_secs = tonumber(lines[1]:match(' %((%d+)s%)$'))
  local cur_ms_val = tonumber(lines[1]:match(' %((%d+)ms%)$'))
  local cur_ms = cur_ms_val or (cur_secs and cur_secs * 1000) or nil
  if cur_ms and new_ms < cur_ms then return end

  local icons = require('cc.icons')
  local timer_icon = icons.timer_icon()
  -- Strip any prior timer suffix off the line. Match either "<icon>...(Ns)"
  -- (the canonical form this function produces) or a stray "(Ns)" with no
  -- icon (a transient state from prior buggy paths — kept defensive).
  local base = lines[1]
    :gsub(' ' .. vim.pesc(timer_icon) .. '.*$', '')
    :gsub(' %(%d+m?s%)$', '')
  local suffix = ' ' .. timer_icon
  local input = meta.input
  if meta.tool_name == 'Bash' and type(input) == 'table'
      and type(input.timeout) == 'number' and input.timeout > 0 then
    suffix = suffix .. string.format(' timeout %ds', math.floor(input.timeout / 1000))
  end
  if new_ms < 1000 then
    suffix = suffix .. string.format(' (%dms)', new_ms)
  else
    suffix = suffix .. string.format(' (%ds)', math.floor(new_ms / 1000))
  end
  self:_with_tail_anchor(function()
    vim.bo[bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(bufnr, meta.header_lnum - 1, meta.header_lnum, false,
      { base .. suffix })
    vim.bo[bufnr].modifiable = false
  end)
  -- nvim_buf_set_lines drifts inline virt_text extmarks within the deleted
  -- range down to the line below; refresh synchronously so the caret stays
  -- visually anchored to the header.
  output.refresh_carets(bufnr)
end

return M
