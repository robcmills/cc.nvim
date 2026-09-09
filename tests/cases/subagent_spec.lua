-- Subagent Activity: nested rendering of parent_tool_use_id-tagged messages
-- under the parent Agent tool block, and the folded-header live status.

local helpers = dofile('tests/helpers.lua')
local MiniTest = require('mini.test')
local eq = MiniTest.expect.equality

local T = MiniTest.new_set({ hooks = helpers.shared_child_hooks() })

local function find_line(lines, pattern, from)
  for i = from or 1, #lines do
    if lines[i]:match(pattern) then return i end
  end
  return nil
end

local function contains(s, needle)
  return type(s) == 'string' and s:find(needle, 1, true) ~= nil
end

-- ---------------------------------------------------------------------------
-- Fixture replay: layout and fold levels
-- ---------------------------------------------------------------------------
T['layout'] = MiniTest.new_set()

T['layout']['activity header sits between parent prompt and parent output at depth 3'] = function()
  helpers.replay_streaming(_G.child, 'subagent_tasks')
  local lines = helpers.get_buffer_lines(_G.child)
  local fl = helpers.get_fold_levels(_G.child)
  local prompt = find_line(lines, '^    prompt: List all source files')
  local activity = find_line(lines, '^    Activity:$')
  local output = find_line(lines, '^    Output:$')
  eq(prompt ~= nil and activity ~= nil and output ~= nil, true)
  eq(prompt < activity, true)
  eq(activity < output, true)
  eq(fl[activity], '>3')
  -- Parent result content follows its own header, after the section.
  eq(lines[output + 1], '      Found 42 source files across 6 directories')
end

T['layout']['nested tool renders header, input and result two depths deeper'] = function()
  helpers.replay_streaming(_G.child, 'subagent_tasks')
  local lines = helpers.get_buffer_lines(_G.child)
  local fl = helpers.get_fold_levels(_G.child)
  local header = find_line(lines, '^      %S+ Bash: Count Lua files')
  eq(header ~= nil, true)
  eq(fl[header], '>4')
  eq(lines[header + 1], "        find . -name '*.lua' | wc -l")
  eq(fl[header + 1], 4)
  eq(lines[header + 2], '        Output:')
  eq(fl[header + 2], '>5')
  eq(lines[header + 3], '          42')
  eq(fl[header + 3], 5)
end

T['layout']['nested tool_progress updates the nested header timer'] = function()
  helpers.replay_streaming(_G.child, 'subagent_tasks')
  local lines = helpers.get_buffer_lines(_G.child)
  local read = find_line(lines, '^      %S+ Read: lua/cc/output%.lua')
  eq(read ~= nil, true)
  eq(lines[read]:match(' 2s$') ~= nil, true)
end

T['layout']['nested text and thinking render at depth 3 inside the section'] = function()
  helpers.replay_streaming(_G.child, 'subagent_tasks', { show_thinking = true })
  local lines = helpers.get_buffer_lines(_G.child)
  local fl = helpers.get_fold_levels(_G.child)
  local activity = find_line(lines, '^    Activity:$')
  local output = find_line(lines, '^    Output:$')
  local thinking = find_line(lines, '^      ∴ Thinking%.%.%. 42 files%.')
  local text = find_line(lines, '^      Found 42 source files', activity)
  eq(thinking ~= nil and text ~= nil, true)
  eq(activity < thinking and thinking < text and text < output, true)
  eq(fl[thinking], 3)
  eq(fl[text], 3)
end

T['layout']['nested thinking honours show_thinking=false'] = function()
  helpers.replay_streaming(_G.child, 'subagent_tasks', { show_thinking = false })
  local lines = helpers.get_buffer_lines(_G.child)
  eq(find_line(lines, 'Thinking'), nil)
  -- The rest of the section still renders.
  eq(find_line(lines, '^      %S+ Read: lua/cc/output%.lua') ~= nil, true)
end

T['layout']['subagent prompt echo and lifecycle notices are not rendered'] = function()
  helpers.replay_streaming(_G.child, 'subagent_tasks')
  local lines = helpers.get_buffer_lines(_G.child)
  -- The prompt appears once, as the parent tool's input.
  local n = 0
  for _, l in ipairs(lines) do
    if l:find('List all source files', 1, true) then n = n + 1 end
  end
  eq(n, 1)
  eq(find_line(lines, 'Task started'), nil)
  eq(find_line(lines, 'Task done'), nil)
  eq(find_line(lines, 'Running Count Lua files'), nil)
end

T['layout']['nested tools stay out of the top-level session tool_calls'] = function()
  helpers.replay_streaming(_G.child, 'subagent_tasks')
  eq(_G.child.lua_get('_G._test_session.tool_calls["toolu_sub01"] == nil'), true)
  eq(_G.child.lua_get('_G._test_session.tool_calls["toolu_04test"] ~= nil'), true)
end

-- ---------------------------------------------------------------------------
-- Fold state and folded-header status
-- ---------------------------------------------------------------------------
T['folds'] = MiniTest.new_set()

T['folds']['activity is closed by default and shows the latest item as foldtext'] = function()
  helpers.replay_streaming(_G.child, 'subagent_tasks')
  _G.child.lua([[
    local bufnr = _G._test_bufnr
    vim.api.nvim_exec_autocmds('BufWinEnter', { buffer = bufnr })
    require('cc.output')._flush_pending_fold_closes(bufnr)
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local activity, parent, nested
    for i, l in ipairs(lines) do
      if l:match('^  %S+ Subagent:') then parent = i end
      if l:match('^    Activity:$') then activity = i end
      if not nested and l:match('^      %S+ Bash:') then nested = i end
    end
    _G._activity, _G._parent, _G._nested = activity, parent, nested
    local winid = vim.fn.bufwinid(bufnr)
    vim.api.nvim_win_call(winid, function()
      vim.cmd('redraw')
      _G._parent_closed = vim.fn.foldclosed(parent)
      _G._activity_closed = vim.fn.foldclosed(activity)
      _G._foldtext = vim.fn.foldtextresult(activity)
      -- User opens the section: header text carries no status, nested
      -- tool folds remain closed at foldlevel 2.
      vim.api.nvim_win_set_cursor(winid, { activity, 0 })
      vim.cmd('normal! zo')
      _G._activity_after_zo = vim.fn.foldclosed(activity)
      _G._nested_after_zo = vim.fn.foldclosed(nested)
      _G._header_text = vim.fn.getline(activity)
    end)
  ]])
  local activity = _G.child.lua_get('_G._activity')
  eq(_G.child.lua_get('_G._parent_closed'), -1)
  eq(_G.child.lua_get('_G._activity_closed'), activity)
  local ft = _G.child.lua_get('_G._foldtext')
  eq(contains(ft, 'Activity: Found 42 source files across 6 directories'), true)
  eq(_G.child.lua_get('_G._activity_after_zo'), -1)
  eq(_G.child.lua_get('_G._nested_after_zo'), _G.child.lua_get('_G._nested'))
  eq(_G.child.lua_get('_G._header_text'), '    Activity:')
end

T['folds']['foldlevel 3 opens the section but keeps nested tools closed'] = function()
  helpers.replay_streaming(_G.child, 'subagent_tasks')
  _G.child.lua([[
    local bufnr = _G._test_bufnr
    vim.api.nvim_exec_autocmds('BufWinEnter', { buffer = bufnr })
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local activity, nested
    for i, l in ipairs(lines) do
      if l:match('^    Activity:$') then activity = i end
      if not nested and l:match('^      %S+ Bash:') then nested = i end
    end
    _G._nested = nested
    local winid = vim.fn.bufwinid(bufnr)
    _G._test_output.winid = winid
    _G._test_output:set_fold_level(3)
    vim.api.nvim_win_call(winid, function()
      vim.cmd('redraw')
      _G._activity_fc = vim.fn.foldclosed(activity)
      _G._nested_fc = vim.fn.foldclosed(nested)
    end)
  ]])
  eq(_G.child.lua_get('_G._activity_fc'), -1)
  eq(_G.child.lua_get('_G._nested_fc'), _G.child.lua_get('_G._nested'))
end

-- ---------------------------------------------------------------------------
-- Live API: deferred start, running status, completion ordering
-- ---------------------------------------------------------------------------
T['live'] = MiniTest.new_set()

T['live']['status tracks the running nested tool and then the latest text'] = function()
  _G.child.lua([[
    local Output = require('cc.output')
    local Session = require('cc.session')
    require('cc.config').setup({})
    local session = Session.new()
    local output = Output.new(session, 'cc-test-subagent-live')
    local bufnr = output:ensure_buffer()
    vim.api.nvim_set_current_buf(bufnr)
    vim.api.nvim_exec_autocmds('BufWinEnter', { buffer = bufnr })
    local winid = vim.fn.bufwinid(bufnr)
    output.winid = winid

    output:render_user_turn('go')
    output:begin_assistant_turn()
    output:on_content_block_start({ type = 'tool_use', id = 'p1', name = 'Agent' })
    -- Subagent activity that races ahead of the parent's content_block_stop
    -- is held until the parent input has rendered.
    output:subagent_tool_use('p1', { id = 's1', name = 'Read', input = { file_path = 'lua/cc/output.lua' } })
    local early = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    _G._early_activity = false
    for _, l in ipairs(early) do
      if l:match('Activity:') then _G._early_activity = true end
    end
    output:on_content_block_stop({
      type = 'tool_use', id = 'p1', name = 'Agent',
      input = { description = 'Look around', prompt = 'read stuff' },
    })
    output:update_tool_elapsed('s1', 2)

    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local act
    for i, l in ipairs(lines) do
      if l:match('^    Activity:$') then act = i end
    end
    _G._act = act
    vim.api.nvim_win_call(winid, function()
      vim.cmd('redraw')
      _G._closed = vim.fn.foldclosed(act)
      _G._ft_running = vim.fn.foldtextresult(act)
    end)

    output:subagent_tool_result('p1', 's1', 'file contents', false)
    output:subagent_text('p1', 'All done here.\nSecond line.')
    vim.api.nvim_win_call(winid, function()
      vim.cmd('redraw')
      _G._ft_text = vim.fn.foldtextresult(act)
    end)

    output:render_tool_result('p1', 'parent summary', false)
    _G._lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    _G._test_bufnr = bufnr
  ]])
  eq(_G.child.lua_get('_G._early_activity'), false)
  local act = _G.child.lua_get('_G._act')
  eq(_G.child.lua_get('_G._closed'), act)
  local running = _G.child.lua_get('_G._ft_running')
  eq(contains(running, 'Activity:'), true)
  eq(contains(running, 'Read: lua/cc/output.lua'), true)
  eq(running:match(' 2s') ~= nil, true)
  eq(contains(_G.child.lua_get('_G._ft_text'), 'Activity: All done here.'), true)

  local lines = _G.child.lua_get('_G._lines')
  local nested_out = find_line(lines, '^        Output:$')
  local text = find_line(lines, '^      All done here%.$')
  local parent_out = find_line(lines, '^    Output:$')
  eq(nested_out ~= nil and text ~= nil and parent_out ~= nil, true)
  eq(lines[nested_out + 1], '          file contents')
  eq(act < nested_out and nested_out < text and text < parent_out, true)
  eq(lines[parent_out + 1], '      parent summary')
end

T['live']['messages for an unknown parent are dropped without error'] = function()
  _G.child.lua([[
    local Output = require('cc.output')
    local Session = require('cc.session')
    require('cc.config').setup({})
    local output = Output.new(Session.new(), 'cc-test-subagent-orphan')
    local bufnr = output:ensure_buffer()
    output:render_user_turn('go')
    output:begin_assistant_turn()
    output:subagent_tool_use('nope', { id = 'x1', name = 'Bash', input = { command = 'ls' } })
    output:subagent_text('nope', 'hello')
    output:subagent_tool_result('nope', 'x1', 'out', false)
    _G._lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    _G._test_bufnr = bufnr
  ]])
  local lines = _G.child.lua_get('_G._lines')
  eq(find_line(lines, 'Activity:'), nil)
  eq(find_line(lines, 'Bash:'), nil)
end

T['live']['interleaved agents keep activity folds closed during every update'] = function()
  _G.child.lua([[
    local Output = require('cc.output')
    require('cc.config').setup({})
    local output = Output.new(require('cc.session').new(), 'cc-test-interleaved')
    local buf = output:ensure_buffer()
    vim.api.nvim_set_current_buf(buf)
    output:set_window(vim.api.nvim_get_current_win())
    output:render_user_turn(string.rep('preamble\n', 40))
    output:begin_assistant_turn()
    local state = Output._buf_state[buf]
    for i = 1, 3 do
      local block = { type = 'tool_use', id = 'p' .. i, name = 'Agent',
        input = { description = 'worker ' .. i } }
      output:on_content_block_start(block)
      output:on_content_block_stop(block)
    end
    _G._test_output = output
    _G._test_bufnr = buf
    _G._test_check = function()
      vim.api.nvim_win_call(output.winid, function()
        vim.cmd('redraw')
        assert(output:_is_following_tail(), 'lost tail after interleaved update')
        for _, sub in pairs(state.subagents) do
          assert(vim.fn.foldclosed(sub.header_lnum) == sub.header_lnum,
            'Activity not closed at ' .. sub.header_lnum)
          local parent = state.tool_blocks[sub.parent_id]
          assert(vim.fn.foldclosed(parent.header_lnum) == -1, 'parent disappeared')
        end
      end)
    end
    _G._test_anchor = function()
      return vim.api.nvim_win_call(output.winid, function()
        local view = vim.fn.winsaveview()
        return { view.topline, view.topfill, view.skipcol, vim.fn.winline() }
      end)
    end
    vim.cmd('botright 5new')
  ]])
  for round = 1, 4 do
    if round == 2 then
      _G.child.lua([[
        local o = _G._test_output
        vim.api.nvim_win_call(o.winid, function()
          local sub = require('cc.output')._buf_state[o.bufnr].subagents.p1
          vim.api.nvim_win_set_cursor(o.winid, { sub.header_lnum, 0 })
          vim.cmd('normal! zo')
          vim.cmd('normal! zc')
        end)
        o:follow_tail()
        _G._test_check()
      ]])
    end
    for i = 1, 3 do
      _G.child.lua(string.format([[
        local o = _G._test_output
        o:subagent_tool_use('p%d', { id = 's%d_%d', name = 'Read',
          input = { file_path = 'lua/cc/output.lua' } })
        o:update_tool_elapsed('p%d', 2)
        o:update_tool_elapsed('s%d_%d', 2)
        _G._test_check()
      ]], i, i, round, i, i, round))
      local anchor = _G.child.lua_get('_G._test_anchor()')
      _G.child.lua(string.format([[
        _G._test_output:subagent_tool_result('p%d', 's%d_%d', string.rep('result\n', 30), false)
        _G._test_check()
      ]], i, i, round))
      eq(_G.child.lua_get('_G._test_anchor()'), anchor)
    end
  end
end

T['live']['closing a tail activity keeps subsequent updates following the tail'] = function()
  _G.child.lua([[
    local Output = require('cc.output')
    require('cc.config').setup({})
    local o = Output.new(require('cc.session').new(), 'cc-test-tail-activity')
    local b = o:ensure_buffer()
    vim.api.nvim_set_current_buf(b)
    o:set_window(vim.api.nvim_get_current_win())
    o:render_user_turn('go')
    o:begin_assistant_turn()
    local block = { type = 'tool_use', id = 'p', name = 'Agent', input = { description = 'worker' } }
    o:on_content_block_start(block)
    o:on_content_block_stop(block)
    o:subagent_text('p', string.rep('working\n', 30) .. 'tail')
    vim.cmd('redraw')
    local sub = Output._buf_state[b].subagents.p
    vim.api.nvim_win_set_cursor(0, { sub.header_lnum, 0 })
    _G._test_following = o:_is_following_tail()
    o:subagent_text('p', 'another update')
    vim.cmd('redraw')
    assert(o:_is_following_tail(), 'lost tail on next update')
    assert(vim.fn.foldclosed(sub.header_lnum) == sub.header_lnum, 'tail activity opened')
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    o:subagent_text('p', 'background update')
    assert(vim.api.nvim_win_get_cursor(0)[1] == 1, 'scrolled away from user position')
  ]])
  eq(_G.child.lua_get('_G._test_following'), true)
end

T['live']['single-line nested tools never close their activity or parent'] = function()
  _G.child.lua([[
    local Output = require('cc.output')
    require('cc.config').setup({ default_fold_level = 3 })
    local o = Output.new(require('cc.session').new(), 'cc-test-empty-nested')
    local b = o:ensure_buffer()
    vim.api.nvim_set_current_buf(b)
    o:set_window(vim.api.nvim_get_current_win())
    o:render_user_turn('go')
    o:begin_assistant_turn()
    for i = 1, 2 do
      local block = { type = 'tool_use', id = 'p' .. i, name = 'Agent', input = { description = 'worker' } }
      o:on_content_block_start(block)
      o:on_content_block_stop(block)
    end
    o:subagent_tool_use('p1', { id = 'empty', name = 'Unknown' })
    vim.cmd('redraw')
    local sub = Output._buf_state[b].subagents.p1
    _G._test_activity_closed = vim.fn.foldclosed(sub.header_lnum)
    o:subagent_tool_result('p1', 'empty', 'now has a body', false)
    vim.cmd('redraw')
    assert(vim.fn.foldclosed(sub.header_lnum) == -1, 'activity closed when tool grew')
    local nested = Output._buf_state[b].tool_blocks.empty.header_lnum
    assert(vim.fn.foldclosed(nested) == nested, 'grown tool did not close')
  ]])
  eq(_G.child.lua_get('_G._test_activity_closed'), -1)
end

return T
