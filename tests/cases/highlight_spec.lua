-- Tests for highlight groups — verify CcXxx groups are applied correctly.
local helpers = dofile('tests/helpers.lua')
local MiniTest = require('mini.test')
local eq = MiniTest.expect.equality

--- Check if a highlight group appears in the syntax stack at a position.
---@param child table
---@param row integer 1-based
---@param col integer 1-based
---@param group string expected highlight group name
local function assert_hl_in_stack(child, row, col, group)
  local stack = helpers.get_syn_stack(child, row, col)
  for _, name in ipairs(stack) do
    if name == group then return end
  end
  error(string.format('Highlight %q not in syntax stack at (%d,%d). Stack: %s',
    group, row, col, table.concat(stack, ', ')), 2)
end

local T = MiniTest.new_set({
  hooks = {
    pre_case = function() _G.child = helpers.new_child() end,
    post_case = function() if _G.child then _G.child.stop() end end,
  },
})

T['highlight_groups'] = MiniTest.new_set()

T['highlight_groups']['CcUser on User: line'] = function()
  helpers.render_fixture(_G.child, 'simple_text')
  local lines = helpers.get_buffer_lines(_G.child)
  for i, line in ipairs(lines) do
    if line:match('User:') then
      local col = line:find('User')
      assert_hl_in_stack(_G.child, i, col, 'CcUser')
      return
    end
  end
  error('No User: line found')
end

T['highlight_groups']['CcAgent on Agent: line'] = function()
  helpers.render_fixture(_G.child, 'simple_text')
  local lines = helpers.get_buffer_lines(_G.child)
  for i, line in ipairs(lines) do
    if line:match('Agent:') then
      local col = line:find('Agent')
      assert_hl_in_stack(_G.child, i, col, 'CcAgent')
      return
    end
  end
  error('No Agent: line found')
end

T['highlight_groups']['CcTool on tool header line'] = function()
  helpers.render_fixture(_G.child, 'tool_read')
  local lines = helpers.get_buffer_lines(_G.child)
  for i, line in ipairs(lines) do
    local col = line:find('Read:')
    if col and line:match('^%s+%S+%s+Read:') then
      assert_hl_in_stack(_G.child, i, col, 'CcTool')
      return
    end
  end
  error('No Read tool header found')
end

-- Regression: MCP tool headers contain hyphens in the server name
-- (e.g. `mcp__claude-in-chrome__navigate`). The CcTool syntax pattern must
-- match those hyphens, not just \w.
T['highlight_groups']['CcTool on mcp__ tool header with hyphens'] = function()
  helpers.render_fixture(_G.child, 'mcp_chrome')
  local lines = helpers.get_buffer_lines(_G.child)
  for i, line in ipairs(lines) do
    local col = line:find('mcp__claude%-in%-chrome__')
    if col and line:match('^%s+%S+%s+mcp__claude%-in%-chrome__') then
      assert_hl_in_stack(_G.child, i, col, 'CcTool')
      return
    end
  end
  error('No mcp__claude-in-chrome__ tool header found')
end

T['highlight_groups']['CcOutput on Output: line'] = function()
  helpers.render_fixture(_G.child, 'tool_read')
  local lines = helpers.get_buffer_lines(_G.child)
  for i, line in ipairs(lines) do
    if line:match('Output:') then
      local col = line:find('Output')
      assert_hl_in_stack(_G.child, i, col, 'CcOutput')
      return
    end
  end
  error('No Output: line found')
end

-- Regression: headers appearing after a markdown region (e.g. a tool result
-- containing backticks/code fences opens markdownCodeBlock) must still win.
-- containedin=ALL on the CcXxx matches makes them fire even when nested
-- inside markdown regions.
T['highlight_groups']['CcTool wins after markdown region'] = function()
  helpers.render_fixture(_G.child, 'multi_turn')
  local lines = helpers.get_buffer_lines(_G.child)
  local tool_header_count = 0
  for i, line in ipairs(lines) do
    if line:match('^%s+%S+%s+%u%w*:') then
      tool_header_count = tool_header_count + 1
      if tool_header_count >= 2 then
        -- Find the column of the tool name (after icon + space).
        local col = line:find('%u%w*:')
        assert_hl_in_stack(_G.child, i, col, 'CcTool')
        return
      end
    end
  end
  error('multi_turn fixture expected to have at least 2 tool headers')
end

T['highlight_groups']['CcOutput wins after markdown region'] = function()
  helpers.render_fixture(_G.child, 'multi_turn')
  local lines = helpers.get_buffer_lines(_G.child)
  local output_count = 0
  for i, line in ipairs(lines) do
    if line:match('^%s+Output:%s*$') then
      output_count = output_count + 1
      if output_count >= 2 then
        local col = line:find('Output')
        assert_hl_in_stack(_G.child, i, col, 'CcOutput')
        return
      end
    end
  end
  error('multi_turn fixture expected to have at least 2 Output: headers')
end

T['highlight_groups']['CcDiffAdd syntax match is defined'] = function()
  helpers.render_fixture(_G.child, 'tool_edit')
  -- Verify the syntax match exists (even if overridden by markdown regions)
  _G.child.lua([==[
    _G._test_syn_exists = vim.fn.hlexists('CcDiffAdd') == 1
  ]==])
  eq(_G.child.lua_get('_G._test_syn_exists'), true)
end

T['highlight_groups']['CcDiffDelete syntax match is defined'] = function()
  helpers.render_fixture(_G.child, 'tool_edit')
  _G.child.lua([==[
    _G._test_syn_exists = vim.fn.hlexists('CcDiffDelete') == 1
  ]==])
  eq(_G.child.lua_get('_G._test_syn_exists'), true)
end

T['highlight_groups']['CcDiffHunk syntax match is defined'] = function()
  helpers.render_fixture(_G.child, 'tool_edit')
  _G.child.lua([==[
    _G._test_syn_exists = vim.fn.hlexists('CcDiffHunk') == 1
  ]==])
  eq(_G.child.lua_get('_G._test_syn_exists'), true)
end

-- Regression: when the cc-output buffer was filetype=markdown, vim's
-- runtime markdown.vim loaded html.vim, whose "bogus comment" region (start
-- `<!`, end `>`) rendered intervening content as htmlCommentError -> Error
-- (red). E.g. a Bash command like `... 2>&1` after a stray `<!` got painted
-- red up to the `>`. Switching the buffer to filetype=cc-output stops
-- markdown.vim/html.vim from loading at all.
T['highlight_groups']['no html error highlight bleeds across lines'] = function()
  helpers.render_fixture(_G.child, 'simple_text')
  _G.child.lua([==[
    -- Inject lines that previously triggered the bug: `<!` opens the bogus
    -- comment region, the next line's `>` closes it, painting the
    -- intervening content red.
    vim.bo[_G._test_bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(_G._test_bufnr, -1, -1, false, {
      '    Some prior <! bogus content',
      '    cd /tmp && git fetch origin foo 2>&1 | tail -5',
    })
    vim.bo[_G._test_bufnr].modifiable = false
    vim.cmd('redraw')
    -- Collect every syntax group on the cd line.
    local last = vim.api.nvim_buf_line_count(_G._test_bufnr)
    local line = vim.api.nvim_buf_get_lines(_G._test_bufnr, last - 1, last, false)[1]
    local seen = {}
    for col = 1, #line do
      local ids = vim.fn.synstack(last, col)
      for _, id in ipairs(ids) do
        seen[vim.fn.synIDattr(id, 'name')] = true
      end
    end
    _G._test_groups_seen = seen
  ]==])
  local seen = _G.child.lua_get('_G._test_groups_seen')
  for _, bad in ipairs({ 'htmlError', 'htmlCommentError', 'htmlComment', 'htmlTag' }) do
    if seen[bad] then
      error(string.format('Expected no %s on cd line, but it was present. Groups seen: %s',
        bad, vim.inspect(seen)))
    end
  end
end

-- Regression: when the output buffer was filetype=markdown, the markdown_inline
-- TS parser was injected over every paragraph in the buffer. With no blank
-- line between a tool header and an indented diff body, the diff lines were
-- swallowed into the same paragraph as the header — so a `~` in `~=` opened
-- a strikethrough delimiter that closed at the next `~` (often many lines
-- later, on another `~=` in another diff line). The fix moves the buffer to
-- filetype=cc-output and scopes the markdown parser via cc.md_highlight to
-- only the agent-prose line ranges, so tool input is invisible to the parser.
--
-- This test verifies the scoping: the parser's included_regions include the
-- agent prose row but exclude any row of the diff body.
T['highlight_groups']['md_highlight scopes parser to agent prose ranges'] = function()
  _G.child.lua([==[
    local Output = require('cc.output')
    local Session = require('cc.session')
    require('cc.config').setup({})

    local session = Session.new()
    local output = Output.new(session, 'cc-test-strike')
    local bufnr = output:ensure_buffer()
    vim.api.nvim_set_current_buf(bufnr)

    output:begin_assistant_turn()

    -- Agent prose with a ~~strikethrough~~ marker.
    output:on_content_block_start({ type = 'text' })
    output:on_delta('text', 'Here is ~~stricken~~ text inline.')
    output:on_content_block_stop({ type = 'text' })

    -- Tool input containing Lua `~=` — the bug case.
    output:on_content_block_start({ type = 'tool_use', id = 'x1', name = 'Edit' })
    output:on_content_block_stop({
      type = 'tool_use', id = 'x1', name = 'Edit',
      input = {
        file_path = '/tmp/foo.lua',
        old_string = "if state.session_name and state.session_name ~= '' then\n  return true\nend",
        new_string = "if name and name ~= '' then\n  return true\nend",
      },
    })

    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local strike_lnum, code_lnum
    for i, line in ipairs(lines) do
      if line:find('stricken') then strike_lnum = i end
      if not code_lnum and line:find('~=') then code_lnum = i end
    end
    _G._t_strike_lnum = strike_lnum
    _G._t_code_lnum = code_lnum

    _G._t_filetype = vim.bo[bufnr].filetype

    local ok, parser = pcall(vim.treesitter.get_parser, bufnr, 'markdown')
    _G._t_has_parser = ok and parser ~= nil
    if ok and parser then
      local regions = parser:included_regions() or {}
      _G._t_regions = regions
      -- Helper: 0-indexed row inside any included region?
      -- Range is either a 4-tuple {sr, sc, er, ec} or a 6-tuple
      -- {sr, sc, sb, er, ec, eb}; the row indices live at [1] and [#range/2+1].
      local function row_covered(row)
        for _, region in ipairs(regions) do
          for _, range in ipairs(region) do
            local sr = range[1]
            local er = #range == 6 and range[4] or range[3]
            local ec = #range == 6 and range[5] or range[4]
            -- Filter out the void placeholder where the whole range is zeros.
            local is_void = sr == 0 and er == 0 and ec == 0
            if not is_void and row >= sr and row <= er then return true end
          end
        end
        return false
      end
      _G._t_strike_covered = strike_lnum and row_covered(strike_lnum - 1)
      _G._t_code_covered = code_lnum and row_covered(code_lnum - 1)
    end
  ]==])

  -- Filetype must be cc-output, not markdown — that's what stops the runtime
  -- markdown.vim/html.vim and any global TS markdown highlighter from
  -- attaching globally and treating tool input as markdown source.
  local ft = _G.child.lua_get('_G._t_filetype')
  if ft ~= 'cc-output' then
    error("Expected output buffer filetype 'cc-output', got '" .. tostring(ft) .. "'")
  end
  if not _G.child.lua_get('_G._t_has_parser') then
    error('markdown parser was not attached to cc-output buffer')
  end
  if not _G.child.lua_get('_G._t_strike_lnum') then
    error('agent prose line with ~~stricken~~ not found')
  end
  if not _G.child.lua_get('_G._t_code_lnum') then
    error('tool input line with ~= not found')
  end
  if _G.child.lua_get('_G._t_strike_covered') ~= true then
    error('Agent prose row is NOT covered by markdown parser regions; markdown highlighting will not apply.')
  end
  if _G.child.lua_get('_G._t_code_covered') ~= false then
    error('Tool input row IS covered by markdown parser regions; markdown will leak strikethrough into code. Regions: '
      .. vim.inspect(_G.child.lua_get('_G._t_regions')))
  end
end

-- The user prompt content lines should be inside the markdown parser's
-- regions when config.markdown_highlight.user is true, so things like
-- `**bold**` or backticked code in a user message render as markdown.
T['highlight_groups']['md_highlight covers user content when enabled'] = function()
  _G.child.lua([==[
    local Output = require('cc.output')
    local Session = require('cc.session')
    require('cc.config').setup({ markdown_highlight = { agent = true, user = true } })

    local session = Session.new()
    local output = Output.new(session, 'cc-test-user-md')
    local bufnr = output:ensure_buffer()
    vim.api.nvim_set_current_buf(bufnr)

    output:render_user_turn('hello **world** with `code`')

    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local user_content_lnum
    for i, line in ipairs(lines) do
      if line:find('hello %*%*world%*%*') then user_content_lnum = i end
    end
    _G._t_user_lnum = user_content_lnum

    local ok, parser = pcall(vim.treesitter.get_parser, bufnr, 'markdown')
    _G._t_has_parser = ok and parser ~= nil
    if ok and parser then
      local regions = parser:included_regions() or {}
      local function row_covered(row)
        for _, region in ipairs(regions) do
          for _, range in ipairs(region) do
            local sr = range[1]
            local er = #range == 6 and range[4] or range[3]
            local ec = #range == 6 and range[5] or range[4]
            local is_void = sr == 0 and er == 0 and ec == 0
            if not is_void and row >= sr and row <= er then return true end
          end
        end
        return false
      end
      _G._t_user_covered = user_content_lnum and row_covered(user_content_lnum - 1)
    end
  ]==])
  if not _G.child.lua_get('_G._t_user_lnum') then
    error('user content line not found')
  end
  if not _G.child.lua_get('_G._t_has_parser') then
    error('markdown parser was not attached')
  end
  if _G.child.lua_get('_G._t_user_covered') ~= true then
    error('User content row is NOT covered by markdown regions when user=true')
  end
end

-- When markdown_highlight.user = false, user content must NOT be inside any
-- markdown region — preserves the pre-feature behavior for users who don't
-- want their prompts re-rendered.
T['highlight_groups']['md_highlight skips user content when disabled'] = function()
  _G.child.lua([==[
    local Output = require('cc.output')
    local Session = require('cc.session')
    require('cc.config').setup({ markdown_highlight = { agent = true, user = false } })

    local session = Session.new()
    local output = Output.new(session, 'cc-test-user-md-off')
    local bufnr = output:ensure_buffer()
    vim.api.nvim_set_current_buf(bufnr)

    output:render_user_turn('hello **world**')

    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local user_content_lnum
    for i, line in ipairs(lines) do
      if line:find('hello') then user_content_lnum = i end
    end

    local user_covered = false
    local ok, parser = pcall(vim.treesitter.get_parser, bufnr, 'markdown')
    if ok and parser and user_content_lnum then
      local regions = parser:included_regions() or {}
      for _, region in ipairs(regions) do
        for _, range in ipairs(region) do
          local sr = range[1]
          local er = #range == 6 and range[4] or range[3]
          local ec = #range == 6 and range[5] or range[4]
          local is_void = sr == 0 and er == 0 and ec == 0
          if not is_void and (user_content_lnum - 1) >= sr and (user_content_lnum - 1) <= er then
            user_covered = true
          end
        end
      end
    end
    _G._t_user_covered = user_covered
  ]==])
  if _G.child.lua_get('_G._t_user_covered') ~= false then
    error('User content row IS covered by markdown regions when user=false')
  end
end

-- Streaming markdown: while a text block is mid-stream (deltas have arrived
-- but content_block_stop hasn't fired), inline markup like `**bold**` must
-- already be parsed and captured. Regression: prior implementation passed
-- parser:included_regions() (a reference to the parser's internal table)
-- back into set_included_regions after mutating one entry. Because the new
-- and stored regions were the same table, _iter_regions saw no diff and
-- never invalidated, so the markdown_inline child injection's stale
-- zero-length region (clamped by tree:edit) was never refreshed and bold/
-- italic capture never appeared during streaming.
T['highlight_groups']['md_highlight streams inline markup mid-delta'] = function()
  _G.child.lua([==[
    local Output = require('cc.output')
    local Session = require('cc.session')
    require('cc.config').setup({ markdown_highlight = { agent = true, user = true } })

    local session = Session.new()
    local output = Output.new(session, 'cc-test-stream-md')
    local bufnr = output:ensure_buffer()
    vim.api.nvim_set_current_buf(bufnr)

    output:begin_assistant_turn()
    output:on_content_block_start({ type = 'text' })
    -- Deliver bold mid-stream; do NOT call content_block_stop yet.
    output:on_delta('text', 'hello **bold** there')

    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local lnum, bold_col
    for i, line in ipairs(lines) do
      local c = line:find('%*%*')
      if c then lnum, bold_col = i, c; break end
    end
    _G._t_lnum = lnum
    _G._t_bold_col = bold_col

    if lnum and bold_col then
      local caps = vim.treesitter.get_captures_at_pos(bufnr, lnum - 1, bold_col)
      _G._t_capture_names = {}
      for _, c in ipairs(caps) do
        table.insert(_G._t_capture_names, c.capture)
      end
    end
  ]==])

  if not _G.child.lua_get('_G._t_lnum') then
    error('mid-stream line with **bold** not found')
  end
  local names = _G.child.lua_get('_G._t_capture_names') or {}
  local has_strong = false
  for _, n in ipairs(names) do
    if n == 'markup.strong' then has_strong = true end
  end
  if not has_strong then
    error('Expected markup.strong capture mid-stream, got: ' .. vim.inspect(names))
  end
end

T['highlight_groups']['all default groups exist'] = function()
  _G.child.lua([==[
    require('cc.config').setup({})
    require('cc.highlight').set_defaults()
    _G._hl_groups = {}
    local groups = {'CcUser', 'CcAgent', 'CcTool', 'CcOutput', 'CcError',
                    'CcCost', 'CcNotice', 'CcHook', 'CcPermission', 'CcCaret',
                    'CcDiffAdd', 'CcDiffDelete', 'CcDiffHunk'}
    for _, name in ipairs(groups) do
      local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = name })
      _G._hl_groups[name] = ok and next(hl) ~= nil
    end
  ]==])
  local groups = _G.child.lua_get('_G._hl_groups')
  for name, exists in pairs(groups) do
    if not exists then
      error('Highlight group ' .. name .. ' is not defined')
    end
  end
end

return T
