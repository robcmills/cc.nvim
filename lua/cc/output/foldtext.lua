-- Fold rendering: foldexpr, fold info, default foldtext, caret extmarks.
-- Reads cc.output._buf_state but does not write to it. cc.output keeps
-- aliases for foldexpr/foldtext/default_foldtext/refresh_carets so the
-- v:lua callback strings (foldexpr/foldtext options) and external
-- callers don't have to change.

local M = {}

local NS_CARETS = vim.api.nvim_create_namespace('cc.carets')
local CARET_OPEN = '▾'
local CARET_FOLDED = '▸'

--- Expose foldexpr via require('cc.output').foldexpr(v:lnum).
---@param lnum integer 1-indexed
---@return string|integer
function M.foldexpr(lnum)
  local bufnr = vim.api.nvim_get_current_buf()
  local state = require('cc.output')._buf_state[bufnr]
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
  local state = require('cc.output')._buf_state[bufnr]
  local header = vim.fn.getline(foldstart)
  local line_count = foldend - foldstart + 1

  -- Fold depth of the header (">3" → 3). Tool groups sit at depth 2, tool
  -- headers at 3 (5 when nested in a subagent Activity section), and their
  -- Output: folds one deeper.
  local output = require('cc.output')
  local raw = state and state.fold_levels and state.fold_levels[foldstart]
  local depth = 0
  if type(raw) == 'string' then
    depth = tonumber(raw:match('[>%<]?(%d+)')) or 0
  elseif type(raw) == 'number' then
    depth = raw
  end

  -- Tool groups and tool headers are found by line number; their text is
  -- user-configurable (group label, icons) so it can't be pattern-matched.
  local group, tool_block
  if state then
    for _, g in ipairs(state.tool_groups or {}) do
      if g.header_lnum == foldstart then group = g; break end
    end
    if not group then
      for _, block in pairs(state.tool_blocks or {}) do
        if block.header_lnum == foldstart then tool_block = block; break end
      end
    end
  end

  -- Detect role from header line content.
  local role = 'unknown'
  if header:match('^%s*User:') then
    role = 'user'
  elseif header:match('^%s*Agent:') then
    role = 'agent'
  elseif header:match('^%s*Output:') or header:match('^%s*Error:') then
    role = 'result'
  elseif header:match('^%s*Activity:') then
    role = 'activity'
  elseif group then
    role = 'tool_group'
  elseif tool_block or depth == output.TOOL_GROUP_DEPTH then
    -- Untracked tool-group-depth folds are plan snapshots and stray hooks.
    role = 'tool'
  elseif depth > output.TOOL_GROUP_DEPTH then
    role = 'result'
  end

  local info = {
    role = role,
    depth = depth,
    header = header,
    line_count = line_count,
    fold_start = foldstart,
    fold_end = foldend,
    bufnr = bufnr,
    tool_count = 0,
    first_text = nil,
    tool_name = nil,
    tool_input = nil,
    status = nil,
  }

  -- Subagent Activity folds show their latest item while collapsed.
  if role == 'activity' then
    info.status = output.subagent_status(bufnr, foldstart)
  end

  -- Tool groups show their current or most recent call the same way.
  if group then
    info.tool_count = group.count
    info.status = output.tool_group_status(bufnr, foldstart)
  end

  -- For tool folds, attach the originating tool block's name and input so
  -- foldtext can derive a fold-only summary for tools in tool_body.SUMMARY_FOLD_ONLY.
  if tool_block then
    info.tool_name = tool_block.tool_name
    info.tool_input = tool_block.input
  end

  -- For user/agent turns, scan content to count tools and find preview text.
  if state and (role == 'user' or role == 'agent') and foldend > foldstart then
    local tool_count = 0
    local last_block_text = nil
    local prev_was_text = false
    local tool_header = '>' .. output.TOOL_DEPTH
    local fold_lines = vim.fn.getline(foldstart + 1, foldend)
    for i, line in ipairs(fold_lines) do
      local lnum = foldstart + i
      local fl = state.fold_levels[lnum]
      if fl == tool_header then
        tool_count = tool_count + 1
        prev_was_text = false
      elseif fl == 1 then
        local trimmed = vim.trim(line)
        if #trimmed > 0 and not trimmed:match('^∴ Thinking%.%.%.') then
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

--- Pick the primary highlight group for a fold's content text based on role.
---@param info table
---@return string
local function role_hl(info)
  if info.role == 'user' then return 'CcUser' end
  if info.role == 'agent' then return 'CcAgent' end
  if info.role == 'tool' or info.role == 'tool_group' then return 'CcTool' end
  if info.role == 'activity' then return 'CcActivity' end
  if info.role == 'result' then
    if info.header and info.header:match('^%s*Error:') then return 'CcError' end
    return 'CcOutput'
  end
  return 'CcFolded'
end

--- Default fold text function. Exposed for use in custom foldtext callbacks
--- that want to extend rather than replace it. Returns a list of
--- { text, hl_group } chunks so the collapsed line keeps its semantic color
--- (Vim only applies the Folded group to plain-string foldtext, which would
--- otherwise drop our syntax highlighting).
---@param info table fold context from build_fold_info
---@return table list of { text, hl } chunks
function M.default_foldtext(info)
  local hl = role_hl(info)
  -- Caret indent matches the header's visual depth (see refresh_carets).
  local caret = string.rep(' ', math.max(0, (info.depth or 1) - 1) * 2) .. '▸ '
  if info.role == 'user' then
    local body
    if info.first_text and #info.first_text > 0 then
      body = 'User: ' .. info.first_text
    else
      body = 'User:  ⟨' .. info.line_count .. ' lines⟩'
    end
    return { { '▸ ', 'CcCaret' }, { body, hl } }
  elseif info.role == 'agent' then
    local parts = {}
    if info.tool_count > 0 then
      table.insert(parts, '(' .. info.tool_count .. ' tools)')
    end
    if info.first_text and #info.first_text > 0 then
      table.insert(parts, info.first_text)
    end
    local body
    if #parts > 0 then
      body = 'Agent: ' .. table.concat(parts, ' ')
    else
      body = 'Agent:  ⟨' .. info.line_count .. ' lines⟩'
    end
    return { { '▸ ', 'CcCaret' }, { body, hl } }
  elseif info.role == 'tool_group' then
    local body = info.header:gsub('^%s*', '')
    if info.status and info.status ~= '' then
      body = body .. ' · ' .. info.status
    end
    return { { caret, 'CcCaret' }, { body, hl } }
  elseif info.role == 'tool' then
    local stripped = info.header:gsub('^%s*', '')
    local tool_body = require('cc.output.tool_body')
    if info.tool_name and tool_body.SUMMARY_FOLD_ONLY[info.tool_name] and info.tool_input then
      local summary = tool_body.summarize_tool_input(info.tool_name, info.tool_input)
      if summary and summary ~= '' then
        stripped = stripped .. ' ' .. summary
      end
    end
    return { { caret, 'CcCaret' }, { stripped, hl } }
  elseif info.role == 'activity' then
    local body = 'Activity:'
    if info.status and info.status ~= '' then
      body = body .. ' ' .. info.status
      return { { caret, 'CcCaret' }, { body, hl } }
    end
    return {
      { caret, 'CcCaret' },
      { body, hl },
      { ' ⟨' .. info.line_count .. ' lines⟩', 'CcFolded' },
    }
  elseif info.role == 'result' then
    local stripped = info.header:gsub('^%s*', '')
    return {
      { caret, 'CcCaret' },
      { stripped, hl },
      { ' ⟨' .. info.line_count .. ' lines⟩', 'CcFolded' },
    }
  end
  return { { info.header .. '  ⟨' .. info.line_count .. ' lines⟩', 'CcFolded' } }
end

--- Custom foldtext: builds context info and delegates to config.foldtext
--- or the default implementation. Returns either a string or a list of
--- { text, hl } chunks (Neovim draws the list like overlay virt_text).
---@return string|table
function M.foldtext()
  local bufnr = vim.api.nvim_get_current_buf()
  local info = build_fold_info(bufnr, vim.v.foldstart, vim.v.foldend)

  local config = require('cc.config').options
  if config.foldtext then
    local ok, result = pcall(config.foldtext, info)
    if ok then
      if type(result) == 'table' then
        return result
      end
      if type(result) == 'string' then
        -- Wrap the user's plain string with the role's highlight so it
        -- doesn't lose color when the fold is closed.
        return { { result, role_hl(info) } }
      end
    end
  end
  return M.default_foldtext(info)
end

--- Refresh caret extmarks to match current fold state.
---@param bufnr integer
function M.refresh_carets(bufnr)
  local state = require('cc.output')._buf_state[bufnr]
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
        -- Prefer foldclosed() once the fold engine has evaluated this line
        -- (authoritative in both directions, so user zo/zc is respected).
        -- Fall back to the recorded fold-expr value when the engine hasn't
        -- run yet (headless mode, right after buffer edits).
        local raw = state.fold_levels[lnum]
        local my_level = 0
        if type(raw) == 'string' then
          my_level = tonumber(raw:match('[>%<]?(%d+)')) or 0
        elseif type(raw) == 'number' then
          my_level = raw
        end
        local effective_level = vim.fn.foldlevel(lnum)
        local is_folded
        if effective_level == 0 and my_level > 0 then
          is_folded = my_level > wfl
        else
          is_folded = vim.fn.foldclosed(lnum) ~= -1
        end
        local char = is_folded and CARET_FOLDED or CARET_OPEN
        local old_id = state.extmark_ids[lnum]
        if old_id then
          pcall(vim.api.nvim_buf_del_extmark, bufnr, NS_CARETS, old_id)
        end
        -- Indent the inline caret to match the header's visual depth so the
        -- expanded view aligns with the folded (foldtext) view. Depth 1
        -- headers sit at col 0, depth 2 at col 2, depth 3 at col 4, etc.
        local caret_col = math.max(0, (my_level - 1) * 2)
        local ok, id = pcall(vim.api.nvim_buf_set_extmark, bufnr, NS_CARETS, lnum - 1, caret_col, {
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

return M
