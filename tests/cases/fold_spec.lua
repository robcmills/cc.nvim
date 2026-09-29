-- Tests for fold levels and progressive disclosure.
local helpers = dofile('tests/helpers.lua')
local MiniTest = require('mini.test')
local eq = MiniTest.expect.equality

local T = MiniTest.new_set({
  hooks = helpers.shared_child_hooks(),
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

T['fold_levels']['lone tool header gets >2'] = function()
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

T['fold_levels']['lone tool result header gets >3'] = function()
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

T['fold_levels']['lone tool result content gets level 3'] = function()
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

T['fold_levels']['lone edit diff lines get level 2'] = function()
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
  -- At the default foldlevel 2 the lone tool is open, but its depth-3
  -- Output: fold must be closed around its content.
  eq(_G.child.lua_get('_G._fc_output'), output_start)
  eq(_G.child.lua_get('_G._fc_content'), output_start)
  eq(_G.child.lua_get('_G._flv_content'), 3)
end

T['applied_folds']['history finalization closes results before output focus'] = function()
  _G.child.lua([[
    local Output = require('cc.output')
    local Session = require('cc.session')
    require('cc.config').setup({})

    -- Install the output buffer into a window that is not focused. This is the
    -- resume/reuse path where BufWinEnter cannot initialize window options.
    local original_winid = vim.api.nvim_get_current_win()
    vim.cmd('split')
    local output_winid = vim.api.nvim_get_current_win()
    vim.api.nvim_set_current_win(original_winid)
    local output = Output.new(Session.new(), 'cc-test-inactive-history')
    local bufnr = output:ensure_buffer()
    vim.api.nvim_win_set_buf(output_winid, bufnr)
    output:set_window(output_winid)
    vim.wo[output_winid].wrap = false

    local prompt_lines = {}
    for i = 1, 25 do prompt_lines[i] = 'history line ' .. i end
    output:render_user_turn(table.concat(prompt_lines, '\n'))
    output:begin_assistant_turn()
    output:on_content_block_start({ type = 'tool_use', id = 't1', name = 'Bash' })
    output:on_content_block_stop({
      type = 'tool_use', id = 't1', name = 'Bash', input = { command = 'printf hi' },
    }, { historical = true })
    local result_lines = {}
    for i = 1, 20 do result_lines[i] = 'result line ' .. i end
    output:render_tool_result('t1', table.concat(result_lines, '\n'), false)
    output:render_notice('resumed history')

    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local output_lnum
    for i, line in ipairs(lines) do
      if line:match('Output:') then output_lnum = i; break end
    end

    -- Recreate the pre-finalization viewport: the long result is expanded and
    -- the last line is bottom-anchored. Collapsing the result shrinks the
    -- display above the cursor, so history finalization must run zb again.
    vim.api.nvim_win_set_cursor(output_winid, { output_lnum, 0 })
    vim.fn.win_execute(output_winid, 'silent! normal! zo')
    local last_lnum = vim.api.nvim_buf_line_count(bufnr)
    vim.api.nvim_win_set_cursor(output_winid, { last_lnum, 0 })
    vim.fn.win_execute(output_winid, 'silent! normal! zb')

    _G._focus_before_finalize = vim.api.nvim_get_current_win()
    output:finalize_history_replay()
    vim.g._history_fold_before_focus = -99
    vim.g._history_view_before_focus = {}
    vim.fn.win_execute(output_winid,
      'let g:_history_fold_before_focus = foldclosed(' .. output_lnum .. ')'
      .. ' | let g:_history_view_before_focus = {'
      .. '"cursor": line("."), "botline": line("w$"),'
      .. '"winline": winline(), "height": winheight(0)}')
    _G._focus_after_finalize = vim.api.nvim_get_current_win()
    _G._history_foldmethod_before_focus = vim.wo[output_winid].foldmethod

    vim.api.nvim_set_current_win(output_winid)
    _G._history_fold_after_focus = vim.fn.foldclosed(output_lnum)
    _G._history_output_lnum = output_lnum
    _G._history_last_lnum = last_lnum
  ]])
  eq(_G.child.lua_get('_G._focus_after_finalize'),
    _G.child.lua_get('_G._focus_before_finalize'))
  eq(_G.child.lua_get('_G._history_foldmethod_before_focus'), 'expr')
  local output_lnum = _G.child.lua_get('_G._history_output_lnum')
  eq(_G.child.lua_get('vim.g._history_fold_before_focus'), output_lnum)
  eq(_G.child.lua_get('_G._history_fold_after_focus'), output_lnum)
  local view = _G.child.lua_get('vim.g._history_view_before_focus')
  local last_lnum = _G.child.lua_get('_G._history_last_lnum')
  eq(view.cursor, last_lnum)
  eq(view.botline, last_lnum)
  eq(view.winline, view.height)
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

T['win_enter']['re-entering window preserves explicit foldenable choice'] = function()
  helpers.render_fixture(_G.child, 'tool_read')
  _G.child.lua([[
    local bufnr = _G._test_bufnr
    local winid
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_buf(w) == bufnr then winid = w; break end
    end
    -- Equivalent to the user invoking zi.
    vim.wo[winid].foldenable = false
    vim.cmd('vsplit')
    local other = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(other, vim.api.nvim_create_buf(false, true))
    vim.api.nvim_set_current_win(winid)
    vim.api.nvim_exec_autocmds('WinEnter', { buffer = bufnr })
    _G._foldenable_after = vim.wo[winid].foldenable
  ]])
  eq(_G.child.lua_get('_G._foldenable_after'), false)
end

-- Regression: navigating away from cc (replacing the cc buffer in a window
-- via :edit) and back (via :b cc-nvim-output) must preserve the user's
-- foldlevel. The vsplit-only test above doesn't catch this because the
-- output buffer is never replaced in its window — BufWinLeave doesn't fire,
-- so the window-local cc_output_fold_initialized flag is never cleared.
T['win_enter']['nav away and back preserves user foldlevel'] = function()
  _G.child.lua([[require('cc').load_fixture('simple_text')]])
  _G.child.lua([[
    local cc = require('cc')
    local inst = cc._get_instance()
    local output_winid = inst.output_winid
    -- User explicitly sets foldlevel to 0 (everything collapsed).
    vim.wo[output_winid].foldlevel = 0
    _G._fold_before = vim.wo[output_winid].foldlevel

    -- :edit a regular file from prompt window, then :b cc-nvim-output back.
    vim.api.nvim_set_current_win(inst.prompt_winid)
    pcall(vim.cmd, 'edit plugin/cc.lua')
    vim.wait(50, function() return false end)
    vim.cmd('buffer ' .. inst.output.bufnr)
    vim.wait(100, function() return false end)

    local new_winid
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_buf(w) == inst.output.bufnr then
        new_winid = w; break
      end
    end
    _G._fold_after = vim.wo[new_winid].foldlevel
  ]])
  eq(_G.child.lua_get('_G._fold_before'), 0)
  eq(_G.child.lua_get('_G._fold_after'), 0)
end

T['nav_away_back'] = MiniTest.new_set()

-- Regression: navigating away from cc and back must preserve the user's
-- manually-resized prompt window height. Reopen always set height to
-- Config.options.prompt_height, clobbering the user's choice.
T['nav_away_back']['preserves user-resized prompt height'] = function()
  _G.child.lua([[require('cc').load_fixture('simple_text')]])
  _G.child.lua([[
    local cc = require('cc')
    local inst = cc._get_instance()
    -- User resizes prompt to 20 (default is 10).
    vim.api.nvim_win_set_height(inst.prompt_winid, 20)
    require('cc.autosize')._handle_winresized(inst, { inst.prompt_winid })
    _G._height_before = vim.api.nvim_win_get_height(inst.prompt_winid)

    -- :edit a regular file from prompt window (closes both cc windows),
    -- then :b cc-nvim-output back (recreates layout).
    pcall(vim.cmd, 'edit plugin/cc.lua')
    vim.wait(50, function() return false end)
    vim.cmd('buffer ' .. inst.output.bufnr)
    vim.wait(100, function() return false end)

    _G._height_after = inst.prompt_winid
        and vim.api.nvim_win_is_valid(inst.prompt_winid)
        and vim.api.nvim_win_get_height(inst.prompt_winid)
        or -1
  ]])
  eq(_G.child.lua_get('_G._height_before'), 20)
  eq(_G.child.lua_get('_G._height_after'), 20)
end

-- This test relies on a window that has never had a fold manually toggled.
-- Vim's per-window "user opened a fold" state is sticky across buffer
-- changes and survives our normal reset_test_state cleanup, so we restart
-- the child once for this group.
T['manual_open'] = MiniTest.new_set({
  hooks = {
    pre_once = function()
      if _G.child then _G.child.stop() end
      _G.child = helpers.new_child()
    end,
  },
})

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

    -- The second call grouped the turn, shifting Tool 1 down a line.
    lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    _G._t1_output_lnum, _G._t2_output_lnum = nil, nil
    for i, l in ipairs(lines) do
      if l:match('Output:') then
        if not _G._t1_output_lnum then _G._t1_output_lnum = i else _G._t2_output_lnum = i end
      end
    end
    -- Tool 2 follows foldlevel 2: its tool fold (and so its Output:) is closed.
    _G._t2_closed = vim.fn.foldclosed(_G._t2_output_lnum) ~= -1
    -- Tool 1's Output: must remain manually opened (not re-closed by our fix).
    _G._t1_still_open = vim.fn.foldclosed(_G._t1_output_lnum) == -1
  ]])
  eq(_G.child.lua_get('_G._t1_open_after_zo'), true)
  eq(_G.child.lua_get('_G._t2_closed'), true)
  eq(_G.child.lua_get('_G._t1_still_open'), true)
end

T['tool_groups'] = MiniTest.new_set()

-- Builds a live (non-historical) output in the current window. _G._tg.tool
-- streams one tool call the way the router does: a fresh assistant message,
-- the tool_use block, then its result.
local TG_PRELUDE = [[
  local Output = require('cc.output')
  require('cc.config').setup({ tool_icons = { use_nerdfont = false }, show_thinking = true,
    tool_timer_interval_ms = 600000 })
  local output = Output.new(require('cc.session').new(), 'cc-test-tool-groups')
  local bufnr = output:ensure_buffer()
  vim.api.nvim_set_current_buf(bufnr)
  vim.api.nvim_exec_autocmds('BufWinEnter', { buffer = bufnr })
  output:set_window(vim.api.nvim_get_current_win())
  vim.wo.wrap = false
  _G._test_bufnr = bufnr
  _G._test_output = output
  _G._tg = {}
  function _G._tg.tool(id, command, result, is_error)
    output:begin_assistant_turn()
    local block = { type = 'tool_use', id = id, name = 'Bash', input = { command = command } }
    output:on_content_block_start(block)
    output:on_content_block_stop(block)
    if result then output:render_tool_result(id, result, is_error or false) end
  end
  function _G._tg.prose(kind, text)
    output:begin_assistant_turn()
    output:on_content_block_start({ type = kind })
    if text then output:on_delta(kind, text) end
    output:on_content_block_stop({ type = kind })
  end
  function _G._tg.text(text) _G._tg.prose('text', text) end
  function _G._tg.find(pattern)
    for i, l in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
      if l:match(pattern) then return i end
    end
  end
  -- Line text as displayed: inline virtual indent (absorbed prose) + text.
  function _G._tg.display(lnum)
    local text = vim.fn.getline(lnum)
    local marks = vim.api.nvim_buf_get_extmarks(bufnr, Output.NS_GROUP_INDENT,
      { lnum - 1, 0 }, { lnum - 1, 0 }, { details = true })
    for _, m in ipairs(marks) do
      text = m[4].virt_text[1][1] .. text
    end
    return text
  end
  function _G._tg.displayed()
    local out = {}
    for l = 1, vim.api.nvim_buf_line_count(bufnr) do out[l] = _G._tg.display(l) end
    return out
  end
  function _G._tg.level(pattern)
    return Output._buf_state[bufnr].fold_levels[_G._tg.find(pattern)]
  end
  -- What the window shows at `:CcFold level`: open lines trimmed, a closed
  -- fold as its foldtext.
  function _G._tg.visible(level)
    output:set_fold_level(level)
    vim.cmd('redraw')
    local out, l = {}, 1
    local n = vim.api.nvim_buf_line_count(bufnr)
    while l <= n do
      if vim.fn.foldclosed(l) == l then
        table.insert(out, vim.fn.foldtextresult(l))
        l = vim.fn.foldclosedend(l) + 1
      else
        table.insert(out, vim.trim(vim.fn.getline(l)))
        l = l + 1
      end
    end
    return out
  end
  -- Lines where Vim's fold level disagrees with the recorded foldexpr.
  function _G._tg.mismatches()
    local state = Output._buf_state[bufnr]
    local bad = {}
    for l = 1, vim.api.nvim_buf_line_count(bufnr) do
      local raw = state.fold_levels[l]
      local ours = type(raw) == 'number' and raw or (tonumber(tostring(raw):match('%d+')) or 0)
      if vim.fn.foldlevel(l) ~= ours then
        bad[#bad + 1] = ('%d: vim=%d ours=%s'):format(l, vim.fn.foldlevel(l), tostring(raw))
      end
    end
    return bad
  end
]]

local function tg(script)
  _G.child.lua(TG_PRELUDE .. script)
end

T['tool_groups']['a lone tool call renders ungrouped at the turn indent'] = function()
  tg([[
    output:render_user_turn('go')
    _G._tg.tool('t1', 'ls', 'a')
    _G._tg.text('Done.')
    _G._groups = #Output._buf_state[bufnr].tool_groups
    _G._lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    _G._tool_fl = _G._tg.level('Bash: ls')
    _G._out_fl = _G._tg.level('Output:')
  ]])
  eq(_G.child.lua_get('_G._groups'), 0)
  eq(_G.child.lua_get('_G._lines'), {
    'User:', '  go', '', 'Agent:', '', '  ❯ Bash: ls', '    Output:', '      a', '', '  Done.',
  })
  -- One level shallower than a grouped tool, so no fold skips a level.
  eq(_G.child.lua_get('_G._tool_fl'), '>2')
  eq(_G.child.lua_get('_G._out_fl'), '>3')
  eq(helpers.implicit_fold_violations(_G.child), {})
end

T['tool_groups']['a second call groups the turn after the fact'] = function()
  tg([[
    output:render_user_turn('go')
    _G._tg.text('Let me look.')
    _G._tg.tool('t1', 'ls', 'a')
    _G._tg.tool('t2', 'pwd', 'b')
    local state = Output._buf_state[bufnr]
    _G._groups = #state.tool_groups
    _G._lines = _G._tg.displayed()
    _G._fl = {}
    for i = 1, #_G._lines do _G._fl[i] = state.fold_levels[i] end
    _G._indent = state.tool_blocks.t1.indent
    vim.cmd('redraw')
    _G._bad = _G._tg.mismatches()
  ]])
  eq(_G.child.lua_get('_G._groups'), 1)
  eq(_G.child.lua_get('_G._lines'), {
    'User:', '  go', '', 'Agent:',
    '  ⚒ Work: 2 tool calls',
    '    Let me look.',
    '',
    '    ❯ Bash: ls', '      Output:', '        a',
    '',
    '    ❯ Bash: pwd', '      Output:', '        b',
  })
  eq(_G.child.lua_get('_G._fl'), {
    '>1', 1, 0, '>1', '>2', 2, 2, '>3', '>4', 4, 2, '>3', '>4', 4,
  })
  eq(_G.child.lua_get('_G._indent'), 4)
  eq(_G.child.lua_get('_G._bad'), {})
end

T['tool_groups']['text between calls is in the group, trailing text is not'] = function()
  tg([[
    output:render_user_turn('go')
    _G._tg.tool('t1', 'ls', 'a')
    _G._tg.text('Looked around.')
    _G._tg.tool('t2', 'pwd', 'b')
    _G._tg.text('All done.')
    output:end_assistant_turn()
    _G._between = { _G._tg.display(_G._tg.find('Looked around')), _G._tg.level('Looked around') }
    _G._trailing = { _G._tg.display(_G._tg.find('All done')), _G._tg.level('All done') }
    vim.cmd('redraw')
    _G._bad = _G._tg.mismatches()
  ]])
  eq(_G.child.lua_get('_G._between'), { '    Looked around.', 2 })
  eq(_G.child.lua_get('_G._trailing'), { '  All done.', 1 })
  eq(_G.child.lua_get('_G._bad'), {})
end

T['tool_groups']['a later call pulls the trailing text into the group'] = function()
  tg([[
    vim.wo.foldlevel = 1
    output:render_user_turn('go')
    _G._tg.tool('t1', 'ls', 'a')
    _G._tg.tool('t2', 'pwd', 'b')
    _G._tg.text('Checking **one** more thing.')
    vim.cmd('redraw')
    _G._before = { _G._tg.display(_G._tg.find('Checking')), _G._tg.level('Checking') }
    _G._tg.tool('t3', 'date', 'c')
    vim.cmd('redraw')
    local row = _G._tg.find('Checking')
    _G._after = { _G._tg.display(row), _G._tg.level('Checking') }
    _G._text = vim.fn.getline(row)
    _G._header = vim.fn.getline(_G._tg.find('Work:'))
    local header = _G._tg.find('Work:')
    _G._closed_to_end = vim.fn.foldclosed(header) == header
      and vim.fn.foldclosedend(header) == vim.api.nvim_buf_line_count(bufnr)
    _G._bad = _G._tg.mismatches()
    -- Markdown still highlights the prose: its text keeps a 2-space indent
    -- (4 would make it an indented code block) and its region still covers it.
    _G._md_covered = false
    local ok, parser = pcall(vim.treesitter.get_parser, bufnr, 'markdown')
    if ok and parser then
      for _, region in ipairs(parser:included_regions()) do
        for _, r in ipairs(region) do
          local er = r[#r == 6 and 4 or 3]
          if r[1] <= row - 1 and er >= row - 1 then _G._md_covered = true end
        end
      end
    end
  ]])
  eq(_G.child.lua_get('_G._before'), { '  Checking **one** more thing.', 1 })
  eq(_G.child.lua_get('_G._after'), { '    Checking **one** more thing.', 2 })
  eq(_G.child.lua_get('_G._header'), '  ⚒ Work: 3 tool calls')
  eq(_G.child.lua_get('_G._closed_to_end'), true)
  eq(_G.child.lua_get('_G._bad'), {})
  eq(_G.child.lua_get('_G._text'), '  Checking **one** more thing.')
  eq(_G.child.lua_get('_G._md_covered'), true)
end

T['tool_groups']['empty thinking is dropped from the group, thinking with text kept'] = function()
  tg([[
    output:render_user_turn('go')
    _G._tg.prose('thinking')
    _G._tg.tool('t1', 'ls', 'a')
    _G._tg.prose('thinking', 'pondering the output')
    _G._tg.prose('thinking')
    _G._tg.tool('t2', 'pwd', 'b')
    _G._lines = _G._tg.displayed()
    vim.cmd('redraw')
    _G._bad = _G._tg.mismatches()
  ]])
  eq(_G.child.lua_get('_G._lines'), {
    'User:', '  go', '', 'Agent:',
    '  ⚒ Work: 2 tool calls',
    '    ❯ Bash: ls', '      Output:', '        a',
    '',
    '    ∴ Thinking... pondering the output',
    '',
    '    ❯ Bash: pwd', '      Output:', '        b',
  })
  eq(_G.child.lua_get('_G._bad'), {})
end

T['tool_groups']['empty thinking outside a group stays'] = function()
  tg([[
    output:render_user_turn('go')
    _G._tg.prose('thinking')
    _G._tg.tool('t1', 'ls', 'a')
    _G._thinking = _G._tg.find('∴ Thinking%.%.%.')
  ]])
  eq(_G.child.lua_get('_G._thinking') ~= nil, true)
end

T['tool_groups']['level 1 matches the collapsed mock'] = function()
  tg([[
    output:render_user_turn('go')
    _G._tg.prose('thinking')
    _G._tg.tool('t1', 'ls', 'a')
    _G._tg.tool('t2', 'pwd', 'b')
    _G._tg.text('Now the last check.')
    _G._tg.tool('t3', 'date', 'c')
    _G._tg.text('Report: all good.')
    output:end_assistant_turn()
    _G._visible = _G._tg.visible(1)
  ]])
  eq(_G.child.lua_get('_G._visible'), {
    'User:', 'go', '',
    'Agent:',
    '  ▸ ⚒ Work: 3 tool calls',
    '',
    'Report: all good.',
  })
end

T['tool_groups']['level 2 opens the group with each tool collapsed'] = function()
  tg([[
    output:render_user_turn('go')
    _G._tg.tool('t1', 'ls', 'a')
    _G._tg.text('Between.')
    _G._tg.tool('t2', 'pwd', 'b')
    _G._tg.text('Report.')
    _G._visible = _G._tg.visible(2)
  ]])
  eq(_G.child.lua_get('_G._visible'), {
    'User:', 'go', '',
    'Agent:',
    '⚒ Work: 2 tool calls',
    '    ▸ ❯ Bash: ls',
    '',
    'Between.',
    '',
    '    ▸ ❯ Bash: pwd',
    '',
    'Report.',
  })
end

T['tool_groups']['a fresh session renders at the default level 2'] = function()
  tg([[
    output:render_user_turn('lone')
    _G._tg.tool('t1', 'ls', 'a')
    _G._tg.text('One call.')
    output:render_result({})
    output:render_user_turn('grouped')
    _G._tg.tool('t2', 'pwd', 'b')
    _G._tg.tool('t3', 'date', 'c')
    _G._tg.text('Two calls.')
    vim.cmd('redraw')
    _G._level = vim.wo.foldlevel
    local out, l, n = {}, 1, vim.api.nvim_buf_line_count(bufnr)
    while l <= n do
      if vim.fn.foldclosed(l) == l then
        table.insert(out, vim.fn.foldtextresult(l)); l = vim.fn.foldclosedend(l) + 1
      else
        table.insert(out, vim.trim(vim.fn.getline(l))); l = l + 1
      end
    end
    _G._visible = out
  ]])
  eq(_G.child.lua_get('_G._level'), 2)
  eq(_G.child.lua_get('_G._visible'), {
    'User:', 'lone', '',
    'Agent:', '', '❯ Bash: ls', '    ▸ Output: ⟨2 lines⟩', '', 'One call.',
    '',
    'User:', 'grouped', '',
    'Agent:', '⚒ Work: 2 tool calls', '    ▸ ❯ Bash: pwd', '', '    ▸ ❯ Bash: date', '', 'Two calls.',
  })
end

T['tool_groups']['level 3 opens grouped inputs with results collapsed'] = function()
  tg([[
    output:render_user_turn('go')
    _G._tg.tool('t1', 'ls', 'a\nb')
    _G._tg.tool('t2', 'pwd', 'c\nd')
    _G._visible = _G._tg.visible(3)
  ]])
  local visible = _G.child.lua_get('_G._visible')
  eq(visible[#visible - 1], '❯ Bash: pwd')
  eq(visible[#visible], '      ▸ Output: ⟨3 lines⟩')

end

T['tool_groups']['a lone tool folds at its own raw depths at 0..4'] = function()
  tg([[
    output:render_user_turn('go')
    _G._tg.tool('t1', 'ls', 'a')
    _G._tg.text('Report.')
    _G._v = {}
    for level = 0, 4 do _G._v[level + 1] = _G._tg.visible(level) end
  ]])
  local v = _G.child.lua_get('_G._v')
  eq(v[1], { '▸ User: go', '', '▸ Agent: (1 tools) Report.' })
  eq(v[2], { 'User:', 'go', '', 'Agent:', '', '  ▸ ❯ Bash: ls', '', 'Report.' })
  -- One level shallower than a grouped tool, so it opens one level earlier.
  eq(v[3], { 'User:', 'go', '', 'Agent:', '', '❯ Bash: ls', '    ▸ Output: ⟨2 lines⟩', '', 'Report.' })
  local open = { 'User:', 'go', '', 'Agent:', '', '❯ Bash: ls', 'Output:', 'a', '', 'Report.' }
  eq(v[4], open)
  eq(v[5], open)
end

T['tool_groups']['fold keys are left to Vim'] = function()
  tg([[
    _G._maps = {}
    for _, key in ipairs({ 'zx', 'zX', 'zr', 'zm' }) do
      local m = vim.fn.maparg(key, 'n', false, true)
      _G._maps[key] = m.buffer == 1
    end
  ]])
  eq(_G.child.lua_get('_G._maps'), { zx = false, zX = false, zr = false, zm = false })
end

T['tool_groups']['one zo on a collapsed lone tool opens it'] = function()
  tg([[
    output:render_user_turn('go')
    _G._tg.tool('t1', 'ls', 'a')
    _G._tg.text('Report.')
    _G._tg.visible(1)
    vim.api.nvim_win_set_cursor(0, { _G._tg.find('Bash: ls'), 0 })
    vim.cmd('normal! zo')
    local out, l, n = {}, 1, vim.api.nvim_buf_line_count(bufnr)
    while l <= n do
      if vim.fn.foldclosed(l) == l then
        table.insert(out, vim.fn.foldtextresult(l)); l = vim.fn.foldclosedend(l) + 1
      else
        table.insert(out, vim.trim(vim.fn.getline(l))); l = l + 1
      end
    end
    _G._after_zo = out
  ]])
  eq(_G.child.lua_get('_G._after_zo'),
    { 'User:', 'go', '', 'Agent:', '', '❯ Bash: ls', '    ▸ Output: ⟨2 lines⟩', '', 'Report.' })
end

T['tool_groups']['no fold opens more than one level, in groups or out'] = function()
  tg([[
    output:render_user_turn('go')
    _G._tg.prose('thinking')
    _G._tg.tool('t1', 'ls', 'a')
    output:render_hook('PostToolUse', 'response', 0.1)
    _G._tg.text('Between.')
    output:render_hook('Stop', 'started')
    _G._tg.tool('t2', 'pwd', 'b')
    output:render_permission_request('Bash', { command = 'rm x' })
    _G._tg.text('Report.')
    output:render_user_turn('again')
    _G._tg.tool('t3', 'date', 'c')
    output:render_hook('PostToolUse', 'response')
    _G._tg.text('Lone report.')
  ]])
  eq(helpers.implicit_fold_violations(_G.child), {})
end

T['tool_groups']['carets sit at each header indent'] = function()
  tg([[
    output:render_user_turn('go')
    _G._tg.tool('t1', 'ls', 'a')
    _G._tg.tool('t2', 'pwd', 'b')
    Output.refresh_carets(bufnr)
    local ns = vim.api.nvim_create_namespace('cc.carets')
    _G._cols = {}
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, {})) do
      local text = vim.fn.getline(m[2] + 1)
      _G._cols[vim.trim(text)] = m[3]
    end
  ]])
  local cols = _G.child.lua_get('_G._cols')
  eq(cols['Agent:'], 0)
  eq(cols['⚒ Work: 2 tool calls'], 2)
  eq(cols['❯ Bash: ls'], 4)
  eq(cols['Output:'], 6)
end

T['tool_groups']['collapsed header shows the running call, then only the count'] = function()
  tg([[
    vim.wo.foldlevel = 1
    output:render_user_turn('go')
    _G._tg.tool('t1', 'ls', 'a')
    local header
    output:begin_assistant_turn()
    local block = { type = 'tool_use', id = 't2', name = 'Bash', input = { command = 'yarn lint' } }
    output:on_content_block_start(block)
    output:start_tool_timer('t2')
    output:on_content_block_stop(block)
    output:update_tool_elapsed('t2', 5)
    header = _G._tg.find('Work:')
    vim.cmd('redraw')
    _G._running = vim.fn.foldtextresult(header)
    output:update_tool_elapsed('t2', 7)
    vim.cmd('redraw')
    _G._ticked = vim.fn.foldtextresult(header)
    output:render_tool_result('t2', 'clean', false)
    vim.cmd('redraw')
    _G._done = vim.fn.foldtextresult(header)
    _G._line = vim.fn.getline(header)
  ]])
  eq(_G.child.lua_get('_G._running'), '  ▸ ⚒ Work: 2 tool calls · ❯ Bash: yarn lint ⏱ 5s')
  eq(_G.child.lua_get('_G._ticked'), '  ▸ ⚒ Work: 2 tool calls · ❯ Bash: yarn lint ⏱ 7s')
  eq(_G.child.lua_get('_G._done'), '  ▸ ⚒ Work: 2 tool calls')
  eq(_G.child.lua_get('_G._line'), '  ⚒ Work: 2 tool calls')
end

T['tool_groups']['an error result also clears the status'] = function()
  tg([[
    vim.wo.foldlevel = 1
    output:render_user_turn('go')
    _G._tg.tool('t1', 'ls', 'a')
    output:begin_assistant_turn()
    local block = { type = 'tool_use', id = 't2', name = 'Bash', input = { command = 'false' } }
    output:on_content_block_start(block)
    output:start_tool_timer('t2')
    output:on_content_block_stop(block)
    output:render_tool_result('t2', 'exit 1', true)
    local header = _G._tg.find('Work:')
    vim.cmd('redraw')
    _G._ft = vim.fn.foldtextresult(header)
    _G._err_fl = _G._tg.level('Error:')
  ]])
  eq(_G.child.lua_get('_G._ft'), '  ▸ ⚒ Work: 2 tool calls')
  eq(_G.child.lua_get('_G._err_fl'), '>4')
end

T['tool_groups']['a permission prompt for a grouped call stays in the group'] = function()
  tg([[
    output:render_user_turn('go')
    _G._tg.tool('t1', 'ls', 'a')
    _G._tg.tool('t2', 'rm x')
    output:render_permission_request('Bash', { command = 'rm x' })
    output:render_permission_outcome('allow', 'Bash')
    output:render_tool_result('t2', 'ok', false)
    _G._tg.text('Report.')
    _G._perm = { vim.fn.getline(_G._tg.find('Allowed: Bash')), _G._tg.level('Allowed: Bash') }
    _G._visible = _G._tg.visible(1)
  ]])
  eq(_G.child.lua_get('_G._perm'), { '    ✓ Allowed: Bash', 2 })
  eq(_G.child.lua_get('_G._visible'), {
    'User:', 'go', '', 'Agent:', '  ▸ ⚒ Work: 2 tool calls', '', 'Report.',
  })
end

T['tool_groups']['tool_group_format and the ToolGroup icon override the header'] = function()
  tg([[
    require('cc.config').setup({
      tool_icons = { use_nerdfont = false, icons = { ToolGroup = '#' } },
      tool_group_format = function(n) return n .. ' steps' end,
    })
    output:render_user_turn('go')
    _G._tg.tool('t1', 'ls', 'a')
    _G._tg.tool('t2', 'pwd', 'b')
    _G._header_text = vim.fn.getline(_G._tg.find('steps'))
  ]])
  eq(_G.child.lua_get('_G._header_text'), '  # 2 steps')
end

T['tool_groups']['the nerdfont group icon is the wrench'] = function()
  _G.child.lua([[
    require('cc.config').setup({ tool_icons = { use_nerdfont = true } })
    _G._icon = require('cc.icons').for_tool('ToolGroup')
  ]])
  eq(_G.child.lua_get('_G._icon'), '\xef\x82\xad')
end

T['tool_groups']['a resumed multi-tool turn renders one group without empty thinking'] = function()
  helpers.render_fixture(_G.child, 'multi_turn', { tool_icons = { use_nerdfont = false }, show_thinking = true })
  local lines = helpers.get_buffer_lines(_G.child)
  local fl = helpers.get_fold_levels(_G.child)
  eq(lines[1], 'Agent:')
  eq(lines[2], '  ⚒ Work: 5 tool calls')
  eq(fl[2], '>2')
  local bare_thinking = 0
  for _, l in ipairs(lines) do
    if vim.trim(l) == '∴ Thinking...' then bare_thinking = bare_thinking + 1 end
  end
  eq(bare_thinking, 0)
  eq(helpers.implicit_fold_violations(_G.child), {})
end

-- Every resumed and streamed fixture, grouped or not, subagents included.
T['tool_groups']['no fixture opens a fold more than one level deep'] = function()
  for _, f in ipairs(vim.fn.globpath(helpers.fixtures_dir, '*.jsonl', false, true)) do
    helpers.reset_test_state(_G.child)
    helpers.render_fixture(_G.child, vim.fn.fnamemodify(f, ':t:r'), { show_thinking = true })
    eq({ f, helpers.implicit_fold_violations(_G.child) }, { f, {} })
  end
  -- Fixtures with control_response messages need a live provider.
  local ndjson = vim.tbl_filter(function(f)
    return table.concat(vim.fn.readfile(f), '\n'):find('"control_response"', 1, true) == nil
  end, vim.fn.globpath(helpers.ndjson_fixtures_dir, '*.ndjson', false, true))
  for _, f in ipairs(ndjson) do
    helpers.reset_test_state(_G.child)
    helpers.replay_streaming(_G.child, vim.fn.fnamemodify(f, ':t:r'), { show_thinking = true })
    eq({ f, helpers.implicit_fold_violations(_G.child) }, { f, {} })
  end
end

T['tool_groups']['agent and group foldtext report tool counts'] = function()
  tg([[
    output:render_user_turn('go')
    _G._tg.tool('t1', 'ls', 'a')
    _G._tg.tool('t2', 'pwd', 'b')
    _G._tg.text('Done.')
    require('cc.config').setup({
      tool_icons = { use_nerdfont = false },
      foldtext = function(info) _G._infos[info.role] = info.tool_count end,
    })
    _G._infos = {}
    local header = _G._tg.find('Work:')
    local agent = _G._tg.find('^Agent:')
    vim.v.foldstart, vim.v.foldend = header, header + 1
    Output.foldtext()
    vim.v.foldstart, vim.v.foldend = agent, vim.api.nvim_buf_line_count(bufnr)
    Output.foldtext()
  ]])
  -- Redraws may also evaluate the closed Output: folds; only these two matter.
  eq(_G.child.lua_get('_G._infos.tool_group'), 2)
  eq(_G.child.lua_get('_G._infos.agent'), 2)
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
