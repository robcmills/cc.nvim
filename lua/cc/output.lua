-- Output buffer: renders conversation state with foldable tree.
-- Fold level scheme (per-line, fed to foldexpr):
--   >1  User/Agent headers         (fold depth 1)
--    1  Turn content (agent text)
--   >2  Tool header                (fold depth 2 inside a turn)
--    2  Tool input lines
--   >3  Tool result sub-header     (fold depth 3 inside a tool)
--    3  Tool result content
--
-- User-facing :CcFold N maps to Vim foldlevel=N:
--   0 = turns collapsed (only User/Agent headers visible)
--   1 = turns open, tools collapsed        (default)
--   2 = tools open (input visible), results collapsed
--   3 = everything visible
--
-- Carets (▸ folded, ▾ open) are inline virt_text extmarks at the start of
-- header lines, synced to Vim's fold state on CursorMoved.

local M = {}

local NS_CARETS = vim.api.nvim_create_namespace('cc.carets')
local BUF_NAME_DEFAULT = 'cc-output'

local CARET_OPEN = '▾'
local CARET_FOLDED = '▸'

-- Per-buffer fold tracking (keyed by bufnr)
---@class cc.OutputBufState
---@field fold_levels table<integer, string|integer>  line number -> foldexpr value
---@field fold_headers table<integer, boolean>         line numbers that get a caret
---@field extmark_ids table<integer, integer>         line -> extmark id (1-indexed line)
---@field tool_blocks table<string, cc.OutputToolBlock> tool_use_id -> render metadata
M._buf_state = {}

---@class cc.OutputToolBlock
---@field bufnr integer
---@field header_lnum integer 1-indexed line number of "▾ Tool: X" line
---@field result_header_lnum integer? line where "▾ Output:" was inserted
---@field input_rendered boolean

---@class cc.Output
---@field bufnr integer
---@field winid integer?
---@field session cc.Session
---@field streaming_block_type string?
---@field streaming_tool_id string? currently-streaming tool_use id
local Output = {}
Output.__index = Output

---@param session cc.Session
---@param buf_name string? override buffer name (for multiple instances)
function M.new(session, buf_name)
  return setmetatable({
    bufnr = -1,
    winid = nil,
    session = session,
    buf_name = buf_name or BUF_NAME_DEFAULT,
    streaming_block_type = nil,
    streaming_tool_id = nil,
    spinner = nil, -- cc.Spinner, active during an assistant turn
    last_turn_role = nil, ---@type 'user'|'agent'|nil tracks consecutive turns
    agent_header_lnum = nil, ---@type integer? header line of current agent fold
  }, Output)
end

---@return integer
function Output:ensure_buffer()
  if self.bufnr > 0 and vim.api.nvim_buf_is_valid(self.bufnr) then
    return self.bufnr
  end
  self.bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(self.bufnr, self.buf_name)
  vim.bo[self.bufnr].buftype = 'nofile'
  vim.bo[self.bufnr].bufhidden = 'hide'
  vim.bo[self.bufnr].swapfile = false
  vim.bo[self.bufnr].filetype = 'markdown'
  vim.bo[self.bufnr].modifiable = false

  M._buf_state[self.bufnr] = {
    fold_levels = {},
    fold_headers = {},
    extmark_ids = {},
    tool_blocks = {},
  }

  self:_setup_window_opts_for_buffer()
  self:_setup_autocmds()
  require('cc.highlight').apply_buffer_syntax(self.bufnr)
  return self.bufnr
end

--- Configure fold options and caret refresh on windows showing this buffer.
function Output:_setup_window_opts_for_buffer()
  local bufnr = self.bufnr
  local config = require('cc.config').options
  local group = vim.api.nvim_create_augroup('cc.output.win.' .. bufnr, { clear = true })
  vim.api.nvim_create_autocmd({ 'BufWinEnter', 'WinEnter' }, {
    group = group,
    buffer = bufnr,
    callback = function()
      local winid = vim.api.nvim_get_current_win()
      if vim.api.nvim_win_get_buf(winid) ~= bufnr then
        return
      end
      vim.wo[winid].foldmethod = 'expr'
      vim.wo[winid].foldexpr = "v:lua.require'cc.output'.foldexpr(v:lnum)"
      vim.wo[winid].foldenable = true
      vim.wo[winid].foldtext = "v:lua.require'cc.output'.foldtext()"
      vim.wo[winid].fillchars = 'fold: '
      -- foldlevel is user-adjustable (via :CcFold / zM / zR). Only seed it the
      -- first time this window shows the buffer so re-focusing doesn't undo
      -- the user's choice.
      if not vim.w[winid].cc_output_fold_initialized then
        vim.wo[winid].foldlevel = config.default_fold_level
        vim.w[winid].cc_output_fold_initialized = true
      end
      -- If the cursor is at the last line, re-anchor the view so topline
      -- is computed correctly now that the window is focused and folds
      -- are about to be evaluated. Without this, pre-render done from an
      -- unfocused window (e.g. :CcResume) can leave the last line at the
      -- top of the viewport after the user focuses the window. Run
      -- synchronously so the fix lands before the first redraw and the
      -- user does not see a flicker of the wrong state.
      local cursor_row = vim.api.nvim_win_get_cursor(winid)[1]
      local line_count = vim.api.nvim_buf_line_count(bufnr)
      if cursor_row >= line_count then
        pcall(vim.cmd, 'normal! Gzb')
      end
      vim.schedule(function()
        M.refresh_carets(bufnr)
      end)
    end,
  })
end

--- Listen for events that may change fold state.
function Output:_setup_autocmds()
  local bufnr = self.bufnr
  local group = vim.api.nvim_create_augroup('cc.output.buf.' .. bufnr, { clear = true })
  vim.api.nvim_create_autocmd({ 'CursorMoved', 'CursorMovedI', 'WinScrolled' }, {
    group = group,
    buffer = bufnr,
    callback = function()
      M.refresh_carets(bufnr)
    end,
  })
end

--- Expose foldexpr via require('cc.output').foldexpr(v:lnum).
---@param lnum integer 1-indexed
---@return string|integer
function M.foldexpr(lnum)
  local bufnr = vim.api.nvim_get_current_buf()
  local state = M._buf_state[bufnr]
  if not state then
    return 0
  end
  return state.fold_levels[lnum] or 0
end

--- Build fold context info table for the foldtext callback.
---@param bufnr integer
---@param foldstart integer 1-indexed
---@param foldend integer 1-indexed
---@return table
local function build_fold_info(bufnr, foldstart, foldend)
  local state = M._buf_state[bufnr]
  local header = vim.fn.getline(foldstart)
  local line_count = foldend - foldstart + 1

  -- Detect role from header line content.
  local role = 'unknown'
  if header:match('^%s*User:') then
    role = 'user'
  elseif header:match('^%s*Agent:') then
    role = 'agent'
  elseif header:match('^%s*Tool:') then
    role = 'tool'
  elseif header:match('^%s*Output:') or header:match('^%s*Error:') then
    role = 'result'
  end

  local info = {
    role = role,
    header = header,
    line_count = line_count,
    fold_start = foldstart,
    fold_end = foldend,
    bufnr = bufnr,
    tool_count = 0,
    first_text = nil,
  }

  -- For user/agent turns, scan content to count tools and find preview text.
  if state and (role == 'user' or role == 'agent') and foldend > foldstart then
    local tool_count = 0
    local last_block_text = nil
    local prev_was_text = false
    local fold_lines = vim.fn.getline(foldstart + 1, foldend)
    for i, line in ipairs(fold_lines) do
      local lnum = foldstart + i
      local fl = state.fold_levels[lnum]
      if fl == '>2' then
        tool_count = tool_count + 1
        prev_was_text = false
      elseif fl == 1 then
        local trimmed = vim.trim(line)
        if #trimmed > 0 and not trimmed:match('^∴ thinking:') then
          if not prev_was_text then
            last_block_text = trimmed
          end
          prev_was_text = true
        else
          prev_was_text = false
        end
      else
        prev_was_text = false
      end
    end
    info.tool_count = tool_count
    info.first_text = last_block_text
  end

  return info
end

--- Default fold text function. Exposed as M.default_foldtext for use in
--- custom foldtext callbacks that want to extend rather than replace it.
---@param info table fold context from build_fold_info
---@return string
function M.default_foldtext(info)
  if info.role == 'user' then
    if info.first_text and #info.first_text > 0 then
      return '▸ User: ' .. info.first_text
    end
    return '▸ User:  ⟨' .. info.line_count .. ' lines⟩'
  elseif info.role == 'agent' then
    local parts = {}
    if info.tool_count > 0 then
      table.insert(parts, '(' .. info.tool_count .. ' tools)')
    end
    if info.first_text and #info.first_text > 0 then
      table.insert(parts, info.first_text)
    end
    if #parts > 0 then
      return '▸ Agent: ' .. table.concat(parts, ' ')
    end
    return '▸ Agent:  ⟨' .. info.line_count .. ' lines⟩'
  elseif info.role == 'tool' then
    local stripped = info.header:gsub('^%s*', '')
    return '  ▸ ' .. stripped
  elseif info.role == 'result' then
    local stripped = info.header:gsub('^%s*', '')
    return '    ▸ ' .. stripped .. '  ⟨' .. info.line_count .. ' lines⟩'
  end
  -- Fallback for unknown fold types.
  return info.header .. '  ⟨' .. info.line_count .. ' lines⟩'
end

--- Custom foldtext: builds context info and delegates to config.foldtext
--- or the default implementation.
---@return string
function M.foldtext()
  local bufnr = vim.api.nvim_get_current_buf()
  local info = build_fold_info(bufnr, vim.v.foldstart, vim.v.foldend)

  local config = require('cc.config').options
  if config.foldtext then
    local ok, result = pcall(config.foldtext, info)
    if ok and type(result) == 'string' then
      return result
    end
  end
  return M.default_foldtext(info)
end

--- Refresh caret extmarks to match current fold state.
---@param bufnr integer
function M.refresh_carets(bufnr)
  local state = M._buf_state[bufnr]
  if not state then return end
  if not vim.api.nvim_buf_is_valid(bufnr) then return end

  -- foldclosed requires a window showing this buffer; find one.
  local winid = nil
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(w) == bufnr then
      winid = w
      break
    end
  end
  if not winid then return end

  vim.api.nvim_win_call(winid, function()
    local wfl = vim.wo[winid].foldlevel
    local line_count = vim.api.nvim_buf_line_count(bufnr)
    for lnum, _ in pairs(state.fold_headers) do
      if lnum <= line_count then
        -- Determine fold state from our recorded fold-expr value so we don't
        -- depend on Vim's lazy fold evaluation (which can lag in headless mode
        -- and right after buffer edits). foldclosed() remains authoritative
        -- only for user-manual fold toggles, which we check as an override.
        local raw = state.fold_levels[lnum]
        local my_level = 0
        if type(raw) == 'string' then
          my_level = tonumber(raw:match('[>%<]?(%d+)')) or 0
        elseif type(raw) == 'number' then
          my_level = raw
        end
        local is_folded = my_level > 0 and my_level > wfl
        local fc = vim.fn.foldclosed(lnum)
        if fc == lnum then
          is_folded = true
        elseif fc ~= -1 and fc < lnum then
          -- this line is hidden inside a closed outer fold
          is_folded = true
        end
        local char = is_folded and CARET_FOLDED or CARET_OPEN
        local old_id = state.extmark_ids[lnum]
        if old_id then
          pcall(vim.api.nvim_buf_del_extmark, bufnr, NS_CARETS, old_id)
        end
        local ok, id = pcall(vim.api.nvim_buf_set_extmark, bufnr, NS_CARETS, lnum - 1, 0, {
          virt_text = { { char .. ' ', 'CcCaret' } },
          virt_text_pos = 'inline',
        })
        if ok then
          state.extmark_ids[lnum] = id
        end
      end
    end
  end)
end

--- Set the window displaying this output buffer (used to auto-scroll).
function Output:set_window(winid)
  self.winid = winid
end

--- Append lines to end of buffer. fold_levels is a same-length array of
--- fold expression values for each appended line; nil means inherit from
--- previous line (or 0 if none).
---@param lines string[]
---@param fold_levels (string|integer)[]? optional, one per line
---@param is_header boolean? whether the FIRST line is a fold header (gets caret)
---@return integer first_line_num 1-indexed line of the first new line
function Output:_append(lines, fold_levels, is_header)
  local was_following = self:_is_following_tail()
  local bufnr = self:ensure_buffer()
  local state = M._buf_state[bufnr]
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  local replace_empty = line_count == 1
    and vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1] == ''

  -- Collapse consecutive blank lines: if buffer already ends with a blank
  -- line, strip leading blanks from the input so we never get double gaps.
  if not replace_empty and not is_header and #lines > 0 then
    local last_buf_line = vim.api.nvim_buf_get_lines(bufnr, line_count - 1, line_count, false)[1] or ''
    if vim.trim(last_buf_line) == '' then
      while #lines > 0 and lines[1] == '' do
        table.remove(lines, 1)
        if fold_levels and #fold_levels > 0 then
          table.remove(fold_levels, 1)
        end
      end
    end
  end

  if #lines == 0 then
    return line_count
  end

  local first_lnum = replace_empty and 1 or (line_count + 1)

  -- Record fold levels BEFORE inserting lines. Vim evaluates foldexpr
  -- synchronously during nvim_buf_set_lines; if state.fold_levels isn't
  -- populated yet, foldexpr returns 0 and the cached result sticks, leaving
  -- nested content (tool results, etc.) unfolded at default_fold_level.
  for i, _ in ipairs(lines) do
    local lnum = first_lnum + i - 1
    local fl = fold_levels and fold_levels[i]
    if fl ~= nil then
      state.fold_levels[lnum] = fl
    else
      state.fold_levels[lnum] = state.fold_levels[lnum - 1] or 0
    end
  end
  if is_header then
    state.fold_headers[first_lnum] = true
  end

  vim.bo[bufnr].modifiable = true
  if replace_empty then
    vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, lines)
  else
    vim.api.nvim_buf_set_lines(bufnr, line_count, line_count, false, lines)
  end
  vim.bo[bufnr].modifiable = false

  if was_following then
    self:_follow_tail()
  end
  -- Defer caret refresh so the fold engine has evaluated the new lines.
  vim.schedule(function() M.refresh_carets(bufnr) end)
  return first_lnum
end

--- Append text to the last line (streaming deltas). New lines spawned by
--- embedded \n inherit fold level from the current last line.
---@param text string
function Output:_append_to_last_line(text)
  local was_following = self:_is_following_tail()
  local bufnr = self:ensure_buffer()
  local state = M._buf_state[bufnr]
  vim.bo[bufnr].modifiable = true
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  local last_row = line_count - 1
  local last_line = vim.api.nvim_buf_get_lines(bufnr, last_row, last_row + 1, false)[1] or ''

  local chunks = vim.split(text, '\n', { plain = true })
  if #chunks == 1 then
    vim.api.nvim_buf_set_lines(bufnr, last_row, last_row + 1, false, { last_line .. chunks[1] })
  else
    local indent = '  '
    local new_lines = { last_line .. chunks[1] }
    for i = 2, #chunks do
      table.insert(new_lines, indent .. chunks[i])
    end
    -- Record fold levels before set_lines so foldexpr sees them.
    local inherit = state.fold_levels[last_row + 1] or 0
    for i = 2, #chunks do
      state.fold_levels[last_row + i] = inherit
    end
    vim.api.nvim_buf_set_lines(bufnr, last_row, last_row + 1, false, new_lines)
  end
  vim.bo[bufnr].modifiable = false
  if was_following then
    self:_follow_tail()
  end
end

--- Returns true if the user is "following the tail" — i.e. the output
--- window is showing this buffer and its cursor is on the last line.
--- Returns true if no window currently shows the buffer (so background
--- streaming defaults to follow-mode until a window appears).
function Output:_is_following_tail()
  if not self.winid or not vim.api.nvim_win_is_valid(self.winid) then
    return true
  end
  if vim.api.nvim_win_get_buf(self.winid) ~= self.bufnr then
    return true
  end
  local cursor_row = vim.api.nvim_win_get_cursor(self.winid)[1]
  local line_count = vim.api.nvim_buf_line_count(self.bufnr)
  return cursor_row >= line_count
end

--- Advance cursor to the new last line and keep it in view. Uses
--- nvim_win_call so topline calc and fold handling run in the target
--- window's own context (works correctly even when the output window
--- is not currently focused).
function Output:_follow_tail()
  if not self.winid or not vim.api.nvim_win_is_valid(self.winid) then
    return
  end
  if vim.api.nvim_win_get_buf(self.winid) ~= self.bufnr then
    return
  end
  pcall(vim.api.nvim_win_call, self.winid, function()
    vim.cmd('normal! G')
  end)
end

--- Render a user turn header + content.
---@param text string
function Output:render_user_turn(text)
  local is_continuation = (self.last_turn_role == 'user')
  self.last_turn_role = 'user'

  if is_continuation then
    -- Consecutive user turn: append content under the existing fold.
    local content_lines = { '' }
    local content_levels = { 1 }
    for _, l in ipairs(vim.split(text, '\n', { plain = true })) do
      table.insert(content_lines, '  ' .. l)
      table.insert(content_levels, 1)
    end
    self:_append(content_lines, content_levels, false)
    return
  end

  -- Blank separator (may be collapsed if buffer already ends with blank).
  self:_append({ '' }, { 0 }, false)
  -- Header line (is_header skips blank-line collapsing and registers caret).
  local header_lnum = self:_append({ 'User:' }, { '>1' }, true)

  local content_lines = {}
  local content_levels = {}
  for _, l in ipairs(vim.split(text, '\n', { plain = true })) do
    table.insert(content_lines, '  ' .. l)
    table.insert(content_levels, 1)
  end
  if #content_lines > 0 then
    self:_append(content_lines, content_levels, false)
  end
end

--- Start an assistant turn (header only; content streams in).
---@return integer header_lnum
function Output:begin_assistant_turn()
  local is_continuation = (self.last_turn_role == 'agent')
  self.last_turn_role = 'agent'
  self.streaming_block_type = nil
  self.streaming_tool_id = nil

  if is_continuation and self.agent_header_lnum then
    -- Consecutive agent turn: skip the header, stay inside existing fold.
    self:_append({ '' }, { 1 }, false)
    -- Restart spinner on the original header.
    if self.spinner then self.spinner:stop() end
    local Spinner = require('cc.spinner')
    self.spinner = Spinner.new(self.bufnr, self.agent_header_lnum)
    self.spinner:start()
    return self.agent_header_lnum
  end

  -- Blank separator (may be collapsed if buffer already ends with blank).
  self:_append({ '' }, { 0 }, false)
  -- Header line (is_header skips blank-line collapsing and registers caret).
  local header_lnum = self:_append({ 'Agent:' }, { '>1' }, true)
  self.agent_header_lnum = header_lnum
  -- Start spinner on the Agent header.
  if self.spinner then self.spinner:stop() end
  local Spinner = require('cc.spinner')
  self.spinner = Spinner.new(self.bufnr, header_lnum)
  self.spinner:start()
  return header_lnum
end

--- Stop the current assistant-turn spinner (called on message_stop / result).
function Output:stop_spinner()
  if self.spinner then
    self.spinner:stop()
    self.spinner = nil
  end
end

--- Content block started (text, thinking, or tool_use).
---@param block table
function Output:on_content_block_start(block)
  if block.type == 'text' then
    self:_append({ '  ' }, { 1 }, false)
    self.streaming_block_type = 'text'
  elseif block.type == 'thinking' then
    if require('cc.config').options.show_thinking then
      self:_append({ '  ∴ thinking:' }, { 1 }, false)
      self.streaming_block_type = 'thinking'
    else
      self.streaming_block_type = 'thinking_hidden'
    end
  elseif block.type == 'tool_use' then
    local header_text = '  Tool: ' .. (block.name or '?')
    local header_lnum = self:_append({ header_text }, { '>2' }, true)
    self.streaming_block_type = 'tool_use'
    self.streaming_tool_id = block.id
    local state = M._buf_state[self.bufnr]
    state.tool_blocks[block.id or ''] = {
      bufnr = self.bufnr,
      header_lnum = header_lnum,
      input_rendered = false,
    }
  end
end

--- Called on text_delta / thinking_delta within a text/thinking block.
---@param kind string 'text' | 'thinking'
---@param chunk string
function Output:on_delta(kind, chunk)
  if kind == 'text' and self.streaming_block_type == 'text' then
    self:_append_to_last_line(chunk)
  elseif kind == 'thinking' and self.streaming_block_type == 'thinking' then
    self:_append_to_last_line(chunk)
  end
end

--- Called when a content block completes. Renders tool input summary.
---@param block table
function Output:on_content_block_stop(block)
  if block and block.type == 'tool_use' then
    local state = M._buf_state[self.bufnr]
    local meta = state.tool_blocks[block.id or '']
    -- Append a compact one-liner as tool summary extension
    local summary = M.summarize_tool_input(block.name, block.input)
    if summary and summary ~= '' then
      -- Update the header line to include the summary: "Tool: Bash — git status"
      self:_update_tool_header_summary(meta and meta.header_lnum or nil, block.name, summary)
    end
    -- Render the full input at fold level 2 (multi-line if needed)
    if meta and not meta.input_rendered then
      self:_render_tool_input(block.name, block.input)
      meta.input_rendered = true
    end
  end
  self.streaming_block_type = nil
  self.streaming_tool_id = nil
end

--- Update an existing tool header line with a " — summary" suffix.
---@param lnum integer?
---@param tool_name string
---@param summary string
function Output:_update_tool_header_summary(lnum, tool_name, summary)
  if not lnum then return end
  local bufnr = self.bufnr
  if lnum > vim.api.nvim_buf_line_count(bufnr) then return end
  vim.bo[bufnr].modifiable = true
  local new_text = '  Tool: ' .. tool_name .. ' — ' .. summary
  vim.api.nvim_buf_set_lines(bufnr, lnum - 1, lnum, false, { new_text })
  vim.bo[bufnr].modifiable = false
end

--- Render tool input block at fold level 2 (below the tool header).
---@param tool_name string
---@param input table?
function Output:_render_tool_input(tool_name, input)
  if not input then return end
  local lines = {}
  local levels = {}

  if tool_name == 'Bash' and input.command then
    for _, l in ipairs(vim.split(tostring(input.command), '\n', { plain = true })) do
      table.insert(lines, '    ' .. l)
      table.insert(levels, 2)
    end
    if input.description then
      table.insert(lines, '    # ' .. input.description)
      table.insert(levels, 2)
    end
  elseif tool_name == 'Edit' then
    local diff = require('cc.diff').render_edit(input.old_string, input.new_string)
    for _, l in ipairs(diff) do
      table.insert(lines, l)
      table.insert(levels, 2)
    end
  elseif tool_name == 'MultiEdit' then
    local diff = require('cc.diff').render_multiedit(input.edits)
    for _, l in ipairs(diff) do
      table.insert(lines, l)
      table.insert(levels, 2)
    end
  elseif tool_name == 'Write' then
    local diff = require('cc.diff').render_write(input.content)
    for _, l in ipairs(diff) do
      table.insert(lines, l)
      table.insert(levels, 2)
    end
  else
    -- Default: pretty-print input as JSON lines
    local ok, encoded = pcall(vim.json.encode, input)
    if ok and encoded then
      for _, l in ipairs(vim.split(encoded, '\n', { plain = true })) do
        table.insert(lines, '    ' .. l)
        table.insert(levels, 2)
      end
    end
  end
  if #lines > 0 then
    self:_append(lines, levels, false)
  end
end

--- Render a tool_result block (from a user-type NDJSON message).
--- Appends a "▾ Output:" sub-header (fold level >3) and the content (level 3).
---@param tool_use_id string
---@param content string|table
---@param is_error boolean?
function Output:render_tool_result(tool_use_id, content, is_error)
  local state = M._buf_state[self.bufnr]
  local meta = state.tool_blocks[tool_use_id]
  if not meta then
    -- Tool not tracked (rare); render at end as a standalone note.
    return
  end

  -- Build result text from content (string or array of blocks).
  local text_parts = {}
  if type(content) == 'string' then
    table.insert(text_parts, content)
  elseif type(content) == 'table' then
    for _, blk in ipairs(content) do
      if type(blk) == 'table' and blk.type == 'text' and blk.text then
        table.insert(text_parts, blk.text)
      elseif type(blk) == 'table' and blk.type == 'image' then
        table.insert(text_parts, '[image]')
      end
    end
  end
  local text = table.concat(text_parts, '\n')

  -- Truncate for buffer display; full result stored on meta for lazy expansion.
  local config = require('cc.config').options
  local max_lines = config.max_tool_result_lines or 50
  local all_lines = vim.split(text, '\n', { plain = true })
  local display_lines = all_lines
  local truncated = false
  if #all_lines > max_lines then
    display_lines = {}
    for i = 1, max_lines do table.insert(display_lines, all_lines[i]) end
    truncated = true
  end

  local header_text = '    ' .. (is_error and 'Error:' or 'Output:')
  local header_lnum = self:_append({ header_text }, { '>3' }, true)
  meta.result_header_lnum = header_lnum
  meta.full_result = text

  local body_lines = {}
  local body_levels = {}
  for _, l in ipairs(display_lines) do
    table.insert(body_lines, '      ' .. l)
    table.insert(body_levels, 3)
  end
  if truncated then
    table.insert(body_lines, string.format('      [... %d more lines]', #all_lines - max_lines))
    table.insert(body_levels, 3)
  end
  if #body_lines > 0 then
    self:_append(body_lines, body_levels, false)
  end
end

--- Compact one-line summary of a tool input (used in tool header suffix).
---@param tool_name string
---@param input table?
---@return string
function M.summarize_tool_input(tool_name, input)
  if not input or type(input) ~= 'table' then
    return ''
  end
  if tool_name == 'Bash' then
    local cmd = tostring(input.command or ''):gsub('\n', ' ')
    if #cmd > 80 then cmd = cmd:sub(1, 77) .. '...' end
    return cmd
  elseif tool_name == 'Read' then
    local path = input.file_path or ''
    if input.offset or input.limit then
      path = path .. ':' .. tostring(input.offset or 1) .. '-' ..
        tostring((input.offset or 1) + (input.limit or 0))
    end
    return path
  elseif tool_name == 'Edit' or tool_name == 'Write' or tool_name == 'NotebookEdit' then
    return input.file_path or ''
  elseif tool_name == 'Glob' then
    return input.pattern or ''
  elseif tool_name == 'Grep' then
    return '"' .. (input.pattern or '') .. '"'
  elseif tool_name == 'WebFetch' then
    return input.url or ''
  elseif tool_name == 'WebSearch' then
    return input.query or ''
  elseif tool_name == 'TodoWrite' then
    return (input.todos and ('#' .. #input.todos)) or ''
  elseif tool_name == 'Agent' then
    return input.description or ''
  end
  local ok, s = pcall(vim.json.encode, input)
  if ok and s then
    if #s > 80 then s = s:sub(1, 77) .. '...' end
    return s
  end
  return ''
end

--- Render a result line (cost, usage) at the end of a turn.
---@param result table
function Output:render_result(result)
  self.last_turn_role = nil
  self:stop_spinner()
  local parts = {}
  if result.total_cost_usd then
    table.insert(parts, string.format('$%.4f', result.total_cost_usd))
  end
  if result.usage then
    local u = result.usage
    if u.input_tokens then
      table.insert(parts, string.format('%d in', u.input_tokens))
    end
    if u.output_tokens then
      table.insert(parts, string.format('%d out', u.output_tokens))
    end
  end
  if #parts == 0 then return end
  self:_append({ '  ── ' .. table.concat(parts, ' │ ') .. ' ──' }, { 0 }, false)
end

---@param text string
function Output:render_notice(text)
  self.last_turn_role = nil
  self:_append({ '  ── ' .. text .. ' ──' }, { 0 }, false)
end

---@param tool_name string
---@param input table?
function Output:render_permission_request(tool_name, input)
  local summary = M.summarize_tool_input(tool_name, input)
  local text = '  ⚠ Permission: ' .. tool_name
  if summary ~= '' then
    text = text .. ' — ' .. summary
  end
  self:_append({ text }, { 1 }, false)
end

---@param behavior string
---@param tool_name string
function Output:render_permission_outcome(behavior, tool_name)
  local icon = behavior == 'allow' and '✓' or '✗'
  local verb = behavior == 'allow' and 'Allowed' or 'Denied'
  local bufnr = self:ensure_buffer()
  vim.bo[bufnr].modifiable = true
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  local last_row = line_count - 1
  vim.api.nvim_buf_set_lines(bufnr, last_row, last_row + 1, false,
    { '  ' .. icon .. ' ' .. verb .. ': ' .. tool_name })
  vim.bo[bufnr].modifiable = false
end

--- Render a transcript record (from history.read_transcript) without the
--- streaming state machine. Used on resume to replay prior conversation.
---@param rec table one of { type='user_text'|'user_tool_result'|'assistant', ... }
function Output:render_historical_record(rec)
  if rec.type == 'user_text' then
    self:render_user_turn(rec.text or '')
  elseif rec.type == 'user_tool_result' then
    if rec.tool_use_id then
      self:render_tool_result(rec.tool_use_id, rec.content, rec.is_error)
    end
  elseif rec.type == 'assistant' then
    self:begin_assistant_turn()
    self:stop_spinner() -- no streaming for historical
    for _, block in ipairs(rec.blocks or {}) do
      if type(block) == 'table' then
        if block.type == 'text' then
          -- Append text paragraph at fold level 1.
          self:_append({ '  ' }, { 1 }, false)
          self:_append_to_last_line(block.text or '')
        elseif block.type == 'thinking' then
          local config = require('cc.config').options
          if config.show_thinking then
            self:_append({ '  ∴ thinking:' }, { 1 }, false)
            self:_append_to_last_line(block.thinking or '')
          end
        elseif block.type == 'tool_use' then
          self:on_content_block_start(block)
          self:on_content_block_stop(block)
        end
      end
    end
    -- Stamp the turn so subsequent tool_results find their tool_use.
    self.streaming_block_type = nil
    self.streaming_tool_id = nil
  end
end

--- Render a dim one-line hook lifecycle event at fold level 2.
---@param hook_name string
---@param phase string 'started' | 'response'
---@param elapsed_s number?
function Output:render_hook(hook_name, phase, elapsed_s)
  local icon = '⚙'
  local suffix = ''
  if elapsed_s then
    suffix = string.format(' (%.1fs)', elapsed_s)
  end
  local text = string.format('    %s Hook: %s [%s]%s', icon, hook_name, phase, suffix)
  self:_append({ text }, { 2 }, false)
end

--- Render a subagent task notice (nested under parent tool).
---@param phase string 'started' | 'progress' | 'done'
---@param description string
function Output:render_task(phase, description)
  local text = string.format('    ⤷ Task %s: %s', phase, description or '')
  self:_append({ text }, { 2 }, false)
end

--- Update a tool header line in-place with elapsed time during execution.
---@param tool_use_id string
---@param elapsed_seconds number
function Output:update_tool_elapsed(tool_use_id, elapsed_seconds)
  local state = M._buf_state[self.bufnr]
  local meta = state and state.tool_blocks[tool_use_id]
  if not meta or not meta.header_lnum then return end
  local bufnr = self.bufnr
  if meta.header_lnum > vim.api.nvim_buf_line_count(bufnr) then return end
  local lines = vim.api.nvim_buf_get_lines(bufnr, meta.header_lnum - 1, meta.header_lnum, false)
  if not lines[1] then return end
  local base = lines[1]:gsub(' %[%d+s%]$', '')
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, meta.header_lnum - 1, meta.header_lnum, false,
    { string.format('%s [%ds]', base, math.floor(elapsed_seconds)) })
  vim.bo[bufnr].modifiable = false
end

--- Set window-local foldlevel for the output window.
---@param level integer
function Output:set_fold_level(level)
  if self.winid and vim.api.nvim_win_is_valid(self.winid) then
    vim.wo[self.winid].foldlevel = level
    vim.schedule(function() M.refresh_carets(self.bufnr) end)
  end
end

M.Output = Output
return M
