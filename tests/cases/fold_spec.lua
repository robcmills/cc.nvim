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
-- foldlevel=1. Verify Vim's live fold computation matches state.fold_levels.
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
  local tool_start = _G.child.lua_get('_G._tool_start')
  -- At default foldlevel=1, the level-2 fold at the tool header should be closed and
  -- must contain both the Output: subheader and its content lines.
  eq(_G.child.lua_get('_G._fc_output'), tool_start)
  eq(_G.child.lua_get('_G._fc_content'), tool_start)
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
    _G._t1_lnum = nil
    for i, l in ipairs(lines) do
      if l:match('^%s+%S+%s+Read:') then _G._t1_lnum = i; break end
    end
    -- User manually opens Tool 1's fold.
    vim.api.nvim_win_set_cursor(winid, { _G._t1_lnum, 0 })
    vim.cmd('normal! zo')
    _G._t1_open_after_zo = vim.fn.foldclosed(_G._t1_lnum) == -1

    -- Now append a second tool.
    output:on_content_block_start({ type = 'tool_use', id = 't2', name = 'Bash' })
    output:on_content_block_stop({ type = 'tool_use', id = 't2', name = 'Bash', input = { command = 'ls' } })
    output:render_tool_result('t2', 'a\nb\nc', false)
    vim.wait(50, function() return false end)

    lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    _G._t2_lnum = nil
    for i, l in ipairs(lines) do
      if l:match('^%s+%S+%s+Bash:') then _G._t2_lnum = i; break end
    end
    _G._t2_closed = vim.fn.foldclosed(_G._t2_lnum) == _G._t2_lnum
    -- Tool 1 must remain manually opened (not re-closed by our fix).
    _G._t1_still_open = vim.fn.foldclosed(_G._t1_lnum) == -1
  ]])
  eq(_G.child.lua_get('_G._t1_open_after_zo'), true)
  eq(_G.child.lua_get('_G._t2_closed'), true)
  eq(_G.child.lua_get('_G._t1_still_open'), true)
end

return T
