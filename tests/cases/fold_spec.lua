-- Tests for fold levels and progressive disclosure.
local helpers = dofile('tests/helpers.lua')
local MiniTest = require('mini.test')
local eq = MiniTest.expect.equality

local T = MiniTest.new_set({
  hooks = {
    pre_case = function() _G.child = helpers.new_child() end,
    post_case = function() if _G.child then _G.child.stop() end end,
  },
})

T['fold_levels'] = MiniTest.new_set()

T['fold_levels']['user header gets >1'] = function()
  helpers.render_fixture(_G.child, 'simple_text')
  local fl = helpers.get_fold_levels(_G.child)
  -- Find the User: line and check its fold level
  local lines = helpers.get_buffer_lines(_G.child)
  for i, line in ipairs(lines) do
    if line:match('User:') then
      eq(fl[i], '>1')
      return
    end
  end
  error('No User: line found')
end

T['fold_levels']['agent header gets >1'] = function()
  helpers.render_fixture(_G.child, 'simple_text')
  local fl = helpers.get_fold_levels(_G.child)
  local lines = helpers.get_buffer_lines(_G.child)
  for i, line in ipairs(lines) do
    if line:match('Agent:') then
      eq(fl[i], '>1')
      return
    end
  end
  error('No Agent: line found')
end

T['fold_levels']['agent text gets level 1'] = function()
  helpers.render_fixture(_G.child, 'simple_text')
  local fl = helpers.get_fold_levels(_G.child)
  local lines = helpers.get_buffer_lines(_G.child)
  for i, line in ipairs(lines) do
    if line:match('apple banana cherry') then
      eq(fl[i], 1)
      return
    end
  end
  error('No text line found')
end

T['fold_levels']['tool header gets >2'] = function()
  helpers.render_fixture(_G.child, 'tool_read')
  local fl = helpers.get_fold_levels(_G.child)
  local lines = helpers.get_buffer_lines(_G.child)
  for i, line in ipairs(lines) do
    if line:match('^%s+%S+%s+Read:') then
      eq(fl[i], '>2')
      return
    end
  end
  error('No Read tool header found')
end

T['fold_levels']['tool result header gets >3'] = function()
  helpers.render_fixture(_G.child, 'tool_read')
  local fl = helpers.get_fold_levels(_G.child)
  local lines = helpers.get_buffer_lines(_G.child)
  for i, line in ipairs(lines) do
    if line:match('Output:') then
      eq(fl[i], '>3')
      return
    end
  end
  error('No Output: line found')
end

T['fold_levels']['tool result content gets level 3'] = function()
  helpers.render_fixture(_G.child, 'tool_read')
  local fl = helpers.get_fold_levels(_G.child)
  local lines = helpers.get_buffer_lines(_G.child)
  -- Find a line after Output: that has content
  local after_output = false
  for i, line in ipairs(lines) do
    if line:match('Output:') then
      after_output = true
    elseif after_output and line:match('%S') then
      eq(fl[i], 3)
      return
    end
  end
  error('No content line after Output: found')
end

T['fold_levels']['edit diff lines get level 2'] = function()
  helpers.render_fixture(_G.child, 'tool_edit')
  local fl = helpers.get_fold_levels(_G.child)
  local lines = helpers.get_buffer_lines(_G.child)
  for i, line in ipairs(lines) do
    if line:match('^%s+@@') then
      eq(fl[i], 2)
      return
    end
  end
  error('No @@ hunk header found in edit diff')
end

T['applied_folds'] = MiniTest.new_set()

-- Regression: Vim evaluates foldexpr synchronously during nvim_buf_set_lines.
-- If state.fold_levels isn't populated first, foldexpr returns 0 and the
-- stale value sticks, so tool-result content stays visible at default
-- foldlevel=2. Verify Vim's live fold computation matches state.fold_levels.
T['applied_folds']['tool result content is inside closed fold at default level'] = function()
  helpers.render_fixture(_G.child, 'tool_read')
  _G.child.lua([[
    local bufnr = _G._test_bufnr
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local winid
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_buf(w) == bufnr then winid = w; break end
    end
    _G._tool_start, _G._output_start, _G._content_lnum = nil, nil, nil
    for i, l in ipairs(lines) do
      if not _G._tool_start and l:match('^%s+%S+%s+Read:') then _G._tool_start = i end
      if not _G._output_start and l:match('Output:') then _G._output_start = i end
      if _G._output_start and not _G._content_lnum and i > _G._output_start and l:match('%S') then
        _G._content_lnum = i
      end
    end
    vim.api.nvim_win_call(winid, function()
      _G._fc_output = vim.fn.foldclosed(_G._output_start)
      _G._fc_content = vim.fn.foldclosed(_G._content_lnum)
      _G._flv_content = vim.fn.foldlevel(_G._content_lnum)
    end)
  ]])
  local output_start = _G.child.lua_get('_G._output_start')
  -- At default foldlevel=2, the level-2 tool-header fold is open, but the
  -- level-3 Output: fold must be closed and contain the content lines.
  eq(_G.child.lua_get('_G._fc_output'), output_start)
  eq(_G.child.lua_get('_G._fc_content'), output_start)
  eq(_G.child.lua_get('_G._flv_content'), 3)
end

T['win_enter'] = MiniTest.new_set()

-- Regression: re-entering the output window must not reset the user's
-- foldlevel back to default_fold_level.
T['win_enter']['re-entering window preserves user foldlevel'] = function()
  helpers.render_fixture(_G.child, 'tool_read')
  _G.child.lua([[
    local bufnr = _G._test_bufnr
    local winid
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_buf(w) == bufnr then winid = w; break end
    end
    -- User expands everything.
    vim.wo[winid].foldlevel = 99
    -- Split to another window and come back (fires WinEnter on return).
    vim.cmd('vsplit')
    local other = vim.api.nvim_get_current_win()
    vim.api.nvim_set_current_win(winid)
    -- Trigger WinEnter explicitly to cover headless evaluation.
    vim.api.nvim_exec_autocmds('WinEnter', { buffer = bufnr })
    _G._foldlevel_after = vim.wo[winid].foldlevel
    vim.api.nvim_win_close(other, true)
  ]])
  eq(_G.child.lua_get('_G._foldlevel_after'), 99)
end

T['manual_open'] = MiniTest.new_set()

-- Regression: with foldmethod=expr, once the user has manually opened a fold
-- (zo), Vim leaves subsequently-created folds open too. New tool calls
-- appended after a user-opened fold must still be folded per foldlevel,
-- and the user's manually-opened fold must stay open.
T['manual_open']['new tool call is folded after user opens a prior fold'] = function()
  _G.child.lua([[
    local Output = require('cc.output')
    local Session = require('cc.session')
    local config = require('cc.config')
    config.setup({})
    local session = Session.new()
    local output = Output.new(session, 'cc-test-manual-open')
    local bufnr = output:ensure_buffer()
    vim.api.nvim_set_current_buf(bufnr)
    local winid = vim.api.nvim_get_current_win()
    vim.api.nvim_exec_autocmds('BufWinEnter', { buffer = bufnr })

    output:render_user_turn('hello')
    output:begin_assistant_turn()
    output:on_content_block_start({ type = 'tool_use', id = 't1', name = 'Read' })
    output:on_content_block_stop({ type = 'tool_use', id = 't1', name = 'Read', input = { file_path = '/tmp/x' } })
    output:render_tool_result('t1', 'line1\nline2', false)
    vim.wait(50, function() return false end)

    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    _G._t1_output_lnum = nil
    for i, l in ipairs(lines) do
      if l:match('Output:') then _G._t1_output_lnum = i; break end
    end
    -- User manually opens Tool 1's Output: (level-3) fold.
    vim.api.nvim_win_set_cursor(winid, { _G._t1_output_lnum, 0 })
    vim.cmd('normal! zo')
    _G._t1_open_after_zo = vim.fn.foldclosed(_G._t1_output_lnum) == -1

    -- Now append a second tool.
    output:on_content_block_start({ type = 'tool_use', id = 't2', name = 'Bash' })
    output:on_content_block_stop({ type = 'tool_use', id = 't2', name = 'Bash', input = { command = 'ls' } })
    output:render_tool_result('t2', 'a\nb\nc', false)
    vim.wait(50, function() return false end)

    lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    _G._t2_output_lnum = nil
    for i = #lines, 1, -1 do
      if lines[i]:match('Output:') then _G._t2_output_lnum = i; break end
    end
    _G._t2_closed = vim.fn.foldclosed(_G._t2_output_lnum) == _G._t2_output_lnum
    -- Tool 1's Output: must remain manually opened (not re-closed by our fix).
    _G._t1_still_open = vim.fn.foldclosed(_G._t1_output_lnum) == -1
  ]])
  eq(_G.child.lua_get('_G._t1_open_after_zo'), true)
  eq(_G.child.lua_get('_G._t2_closed'), true)
  eq(_G.child.lua_get('_G._t1_still_open'), true)
end

T['foldtext'] = MiniTest.new_set()

-- Collapsed folds would render with only the Folded highlight (plain text)
-- if foldtext returned a string. Returning a list of {text, hl} chunks keeps
-- the semantic color when collapsed.
T['foldtext']['returns chunk list with role highlights'] = function()
  _G.child.lua([[
    local Output = require('cc.output')
    _G._ft_user   = Output.default_foldtext({ role = 'user',   header = 'User:',        line_count = 3, first_text = 'hi' })
    _G._ft_agent  = Output.default_foldtext({ role = 'agent',  header = 'Agent:',       line_count = 5, tool_count = 0, first_text = 'ok' })
    _G._ft_tool   = Output.default_foldtext({ role = 'tool',   header = '  ▶ Read:',    line_count = 2 })
    _G._ft_out    = Output.default_foldtext({ role = 'result', header = '    Output:',  line_count = 4 })
    _G._ft_err    = Output.default_foldtext({ role = 'result', header = '    Error:',   line_count = 4 })
  ]])
  local function chunk_hls(name)
    local chunks = _G.child.lua_get('_G.' .. name)
    local hls = {}
    for _, c in ipairs(chunks) do table.insert(hls, c[2]) end
    return hls
  end
  eq(chunk_hls('_ft_user'),  { 'CcCaret', 'CcUser' })
  eq(chunk_hls('_ft_agent'), { 'CcCaret', 'CcAgent' })
  eq(chunk_hls('_ft_tool'),  { 'CcCaret', 'CcTool' })
  eq(chunk_hls('_ft_out'),   { 'CcCaret', 'CcOutput', 'CcFolded' })
  eq(chunk_hls('_ft_err'),   { 'CcCaret', 'CcError',  'CcFolded' })
end

-- config.foldtext may return a plain string; wrap it with the role highlight
-- so user-supplied foldtext doesn't lose color when collapsed.
T['foldtext']['wraps user string return with role highlight'] = function()
  _G.child.lua([[
    local Output = require('cc.output')
    local config = require('cc.config')
    config.setup({ foldtext = function(info) return '>> ' .. info.role end })
    local session = require('cc.session').new()
    local output = Output.new(session, 'cc-test-foldtext-wrap')
    local bufnr = output:ensure_buffer()
    vim.api.nvim_set_current_buf(bufnr)
    output:render_user_turn('hello')
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local user_lnum
    for i, l in ipairs(lines) do if l == 'User:' then user_lnum = i; break end end
    vim.v.foldstart, vim.v.foldend = user_lnum, user_lnum + 1
    _G._ft_wrapped = Output.foldtext()
  ]])
  local chunks = _G.child.lua_get('_G._ft_wrapped')
  eq(#chunks, 1)
  eq(chunks[1][2], 'CcUser')
  eq(chunks[1][1]:sub(1, 3), '>> ')
end

T['separator'] = MiniTest.new_set()

-- When a user turn's text ends with a trailing newline, the last content line
-- is an indent-only blank at fold level 1. The next turn's level-0 separator
-- gets collapsed by the consecutive-blanks dedup. The remaining blank must
-- be demoted to level 0 so it survives when the user fold closes — otherwise
-- the collapsed user header butts directly against the next Agent: header.
T['separator']['blank before next turn stays at level 0 after dedup'] = function()
  _G.child.lua([[
    local Output = require('cc.output')
    local Session = require('cc.session')
    local config = require('cc.config')
    config.setup({})
    local session = Session.new()
    local output = Output.new(session, 'cc-test-separator')
    local bufnr = output:ensure_buffer()
    vim.api.nvim_set_current_buf(bufnr)

    -- Trailing newline produces an indent-only blank as the last content line.
    output:render_user_turn('hello\n')
    output:begin_assistant_turn()

    local state = Output._buf_state[bufnr]
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    _G._user_lnum, _G._agent_lnum = nil, nil
    for i, l in ipairs(lines) do
      if l == 'User:' then _G._user_lnum = i end
      if l == 'Agent:' then _G._agent_lnum = i end
    end
    _G._sep_lnum = _G._agent_lnum - 1
    _G._sep_line = lines[_G._sep_lnum]
    _G._sep_level = state.fold_levels[_G._sep_lnum]

    -- Also verify live fold behavior: at foldlevel=0 the separator must
    -- remain visible between the two closed turn folds.
    local winid = vim.api.nvim_get_current_win()
    vim.wo[winid].foldlevel = 0
    vim.api.nvim_win_call(winid, function()
      _G._sep_foldclosed = vim.fn.foldclosed(_G._sep_lnum)
      _G._sep_foldlevel  = vim.fn.foldlevel(_G._sep_lnum)
    end)
  ]])
  -- A blank line physically sits between User content and Agent header.
  eq(_G.child.lua_get('vim.trim(_G._sep_line)'), '')
  -- Its recorded foldexpr level is 0 (not inherited from level-1 content).
  eq(_G.child.lua_get('_G._sep_level'), 0)
  -- Vim agrees: the separator is outside any fold.
  eq(_G.child.lua_get('_G._sep_foldclosed'), -1)
  eq(_G.child.lua_get('_G._sep_foldlevel'), 0)
end

return T
