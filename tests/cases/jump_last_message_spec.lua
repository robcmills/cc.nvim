-- jump_to_last_message_on_turn_end and :CcJumpToLastMessage: at turn end a
-- tailing output window moves its cursor to the first line of the turn's last
-- agent message (the text after its last tool call) and scrolls it to the top.
local helpers = dofile('tests/helpers.lua')
local MiniTest = require('mini.test')
local eq = MiniTest.expect.equality

local T = MiniTest.new_set({
  hooks = helpers.shared_child_hooks(),
})

--- Claude router over a stub process, shown in a 10-line window. Defines
--- _G._turn(n, opts) to stream turn n: narration, a Bash call, its result,
--- then a 30-line final message starting "Final n.1", then the result line.
---@param config_opts string? Lua table literal for cc.config.setup
local function setup(config_opts)
  _G.child.lua(string.format([==[
    require('cc.config').setup(%s)
    local Router = require('cc.router')
    local Output = require('cc.output')
    local Session = require('cc.session')
    local session = Session.new()
    local output = Output.new(session, 'cc-test-output')
    local bufnr = output:ensure_buffer()
    vim.api.nvim_set_current_buf(bufnr)
    vim.cmd('resize 10')
    output:set_window(vim.api.nvim_get_current_win())
    local process = { write = function() end, is_alive = function() return true end }
    local router = Router.new({ session = session, output = output, process = process })
    local inst = { session = session, output = output, process = process }
    router.instance = inst
    require('cc')._register_test_instance(bufnr, inst)

    local function ev(e) router:dispatch({ type = 'stream_event', event = e }) end
    local function text_block(text)
      ev({ type = 'content_block_start', index = 0, content_block = { type = 'text', text = '' } })
      ev({ type = 'content_block_delta', index = 0, delta = { type = 'text_delta', text = text } })
      ev({ type = 'content_block_stop', index = 0 })
    end
    _G._stream_turn = function(n, opts)
      opts = opts or {}
      session.turn_active = true
      ev({ type = 'message_start', message = { id = 'a' .. n, role = 'assistant' } })
      text_block('Let me check ' .. n .. '.')
      ev({ type = 'content_block_start', index = 1,
        content_block = { type = 'tool_use', id = 'tool' .. n, name = 'Bash', input = {} } })
      ev({ type = 'content_block_delta', index = 1,
        delta = { type = 'input_json_delta', partial_json = '{"command":"ls"}' } })
      ev({ type = 'content_block_stop', index = 1 })
      ev({ type = 'message_stop' })
      router:dispatch({ type = 'user', message = { role = 'user', content = {
        { type = 'tool_result', tool_use_id = 'tool' .. n, content = 'out', is_error = false } } } })
      if opts.no_final then return end
      ev({ type = 'message_start', message = { id = 'b' .. n, role = 'assistant' } })
      local lines = {}
      for i = 1, 30 do lines[i] = 'Final ' .. n .. '.' .. i end
      text_block(table.concat(lines, '\n'))
      ev({ type = 'message_stop' })
    end
    _G._end_turn = function()
      router:dispatch({ type = 'result', subtype = 'success', total_cost_usd = 0.01,
        usage = { input_tokens = 1, output_tokens = 1 } })
    end
    _G._turn = function(n, opts)
      _G._stream_turn(n, opts)
      _G._end_turn()
    end
    _G._find = function(text)
      for i, l in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
        if vim.trim(l) == text then return i end
      end
    end
    _G._view = function()
      local v = vim.fn.winsaveview()
      return { lnum = v.lnum, topline = v.topline, last = vim.api.nvim_buf_line_count(bufnr) }
    end
    _G._test_bufnr = bufnr
    _G._test_output = output
    _G._test_router = router
    _G._test_inst = inst
  ]==], config_opts or '{}'))
end

local function view() return _G.child.lua_get('_G._view()') end
local function find(text) return _G.child.lua_get('_G._find(...)', { text }) end

T['option off leaves the view on the tail'] = function()
  setup('{ jump_to_last_message_on_turn_end = false }')
  _G.child.lua('_G._turn(1)')
  local v = view()
  eq(v.lnum, v.last)
end

T['tailing view jumps to the final message at turn end'] = function()
  setup()
  _G.child.lua('_G._turn(1)')
  local target = find('Final 1.1')
  local v = view()
  eq(v.lnum, target)
  eq(v.topline, target)
end

T['defaults to on'] = function()
  setup()
  eq(_G.child.lua_get("require('cc.config').options.jump_to_last_message_on_turn_end"), true)
end

T['a scrolled view is left alone'] = function()
  setup()
  _G.child.lua([[
    _G._stream_turn(1)
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    vim.cmd('normal! zt')
    _G._before = _G._view()
    _G._end_turn()
  ]])
  local before = _G.child.lua_get('_G._before')
  local v = view()
  eq(v.lnum, 3)
  eq(v.topline, before.topline)
end

T['later turns do not move the view after a jump'] = function()
  setup()
  _G.child.lua('_G._turn(1)')
  local first = view()
  _G.child.lua('_G._turn(2)')
  local v = view()
  eq(v.lnum, first.lnum)
  eq(v.topline, first.topline)
  eq(v.lnum == v.last, false)
end

T['returning to the tail re-enables the jump'] = function()
  setup()
  _G.child.lua('_G._turn(1)')
  _G.child.lua("vim.cmd('normal! G')")
  _G.child.lua('_G._turn(2)')
  local target = find('Final 2.1')
  eq(view().lnum, target)
  eq(view().topline, target)
end

T['command jumps with the option off from a scrolled view'] = function()
  setup('{ jump_to_last_message_on_turn_end = false }')
  _G.child.lua('_G._turn(1)')
  _G.child.lua('_G._turn(2)')
  _G.child.lua([[
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    vim.cmd('normal! zt')
    vim.cmd('CcJumpToLastMessage')
  ]])
  local target = find('Final 2.1')
  eq(view().lnum, target)
  eq(view().topline, target)
end

T['command targets the latest turn with a final message'] = function()
  setup('{ jump_to_last_message_on_turn_end = false }')
  _G.child.lua('_G._turn(1)')
  _G.child.lua('_G._turn(2, { no_final = true })')
  _G.child.lua("vim.cmd('CcJumpToLastMessage')")
  eq(view().lnum, find('Final 1.1'))
end

T['command does nothing before any message'] = function()
  setup()
  _G.child.lua("vim.cmd('normal! G')")
  local before = view()
  _G.child.lua("vim.cmd('CcJumpToLastMessage')")
  eq(view(), before)
end

T['narration is not the last message'] = function()
  setup()
  _G.child.lua('_G._turn(1)')
  eq(view().lnum == find('Let me check 1.'), false)
  eq(view().lnum, find('Final 1.1'))
end

T['a textless turn end does not move the view'] = function()
  setup()
  _G.child.lua([[
    _G._stream_turn(1, { no_final = true })
    _G._end_turn()
  ]])
  local v = view()
  eq(v.lnum, v.last)
end

T['interrupted turn without text does not jump'] = function()
  setup()
  _G.child.lua([[
    _G._stream_turn(1, { no_final = true })
    _G._test_router:_finish_interrupted_turn()
  ]])
  local v = view()
  eq(v.lnum, v.last)
end

T['interrupted turn with a final message jumps'] = function()
  setup()
  _G.child.lua([[
    _G._stream_turn(1)
    _G._test_router:_finish_interrupted_turn()
  ]])
  eq(view().lnum, find('Final 1.1'))
end

T['target inside a closed fold lands on the fold line'] = function()
  setup('{ jump_to_last_message_on_turn_end = false }')
  _G.child.lua('_G._turn(1)')
  _G.child.lua('_G._turn(2)')
  local header = _G.child.lua_get([[(function()
    local target = _G._find('Final 2.1')
    vim.api.nvim_win_set_cursor(0, { target, 0 })
    vim.cmd('normal! zc')
    local closed = vim.fn.foldclosed(target)
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    vim.cmd('CcJumpToLastMessage')
    return closed
  end)()]])
  eq(header > 0, true)
  eq(view().lnum, header)
  eq(_G.child.lua_get('vim.fn.foldclosed(vim.fn.line("."))'), header)
end

T['hidden output gets the jump written into its saved view'] = function()
  setup()
  _G.child.lua([[
    _G._stream_turn(1)
    _G._test_inst.saved_output_view = { lnum = 40, topline = 31 }
    _G._test_inst.saved_output_following_tail = true
    vim.cmd('enew')
    _G._end_turn()
  ]])
  _G.child.lua('vim.api.nvim_set_current_buf(_G._test_bufnr)')
  local target = find('Final 1.1')
  local inst = _G.child.lua_get('{ view = _G._test_inst.saved_output_view, tail = _G._test_inst.saved_output_following_tail }')
  eq(inst.view.lnum, target)
  eq(inst.view.topline, target)
  eq(inst.tail, false)
end

T['hidden output scrolled away when hidden keeps its saved view'] = function()
  setup()
  _G.child.lua([[
    _G._stream_turn(1)
    _G._test_inst.saved_output_view = { lnum = 3, topline = 1 }
    _G._test_inst.saved_output_following_tail = false
    vim.cmd('enew')
    _G._end_turn()
  ]])
  eq(_G.child.lua_get('_G._test_inst.saved_output_view'), { lnum = 3, topline = 1 })
end

T['output in an inactive tab jumps at turn end'] = function()
  setup()
  _G.child.lua([[
    _G._stream_turn(1)
    _G._out_win = vim.api.nvim_get_current_win()
    vim.cmd('tabnew')
    _G._end_turn()
    _G._out_view = vim.api.nvim_win_call(_G._out_win, vim.fn.winsaveview)
  ]])
  local v = _G.child.lua_get('_G._out_view')
  local target = find('Final 1.1')
  eq(v.lnum, target)
  eq(v.topline, target)
  eq(_G.child.lua_get('vim.api.nvim_win_get_buf(0) ~= _G._test_bufnr'), true)
end

T['reopening hidden output draws the target first, never the tail'] = function()
  -- A real instance (fixture-loaded, so no process) with cc's BufWinEnter
  -- restore path. A decoration provider records every redraw of the output
  -- window, which is every frame the user could see.
  _G.child.lua([==[
    require('cc.config').setup({})
    local cc = require('cc')
    cc.load_fixture('tool_bash.ndjson')
    local inst = cc._get_instance()
    _G._test_inst = inst
    _G._test_bufnr = inst.output.bufnr
    vim.api.nvim_set_current_win(inst.output_winid)
    vim.cmd('normal! G')
  ]==])
  -- Leave the output (tailing), then let the layout collapse.
  _G.child.lua("vim.cmd('enew')")
  _G.child.lua('vim.wait(50)')
  _G.child.lua([==[
    local inst = _G._test_inst
    local router = inst.router
    local function ev(e) router:dispatch({ type = 'stream_event', event = e }) end
    inst.session.turn_active = true
    ev({ type = 'message_start', message = { id = 'x', role = 'assistant' } })
    ev({ type = 'content_block_start', index = 0,
      content_block = { type = 'tool_use', id = 't9', name = 'Bash', input = {} } })
    ev({ type = 'content_block_stop', index = 0 })
    ev({ type = 'message_stop' })
    router:dispatch({ type = 'user', message = { role = 'user', content = {
      { type = 'tool_result', tool_use_id = 't9', content = 'out', is_error = false } } } })
    ev({ type = 'message_start', message = { id = 'y', role = 'assistant' } })
    local lines = {}
    for i = 1, 60 do lines[i] = 'Reopen ' .. i end
    ev({ type = 'content_block_start', index = 0, content_block = { type = 'text', text = '' } })
    ev({ type = 'content_block_delta', index = 0,
      delta = { type = 'text_delta', text = table.concat(lines, '\n') } })
    ev({ type = 'content_block_stop', index = 0 })
    ev({ type = 'message_stop' })
    router:dispatch({ type = 'result', subtype = 'success', total_cost_usd = 0.01,
      usage = { input_tokens = 1, output_tokens = 1 } })
    _G._target = inst.output:last_message_lnum()

    _G._frames = {}
    local ns = vim.api.nvim_create_namespace('test.jump_frames')
    vim.api.nvim_set_decoration_provider(ns, {
      on_win = function(_, winid, bufnr, toprow)
        if bufnr == _G._test_bufnr then
          table.insert(_G._frames, { top = toprow + 1, cursor = vim.api.nvim_win_get_cursor(winid)[1] })
        end
        return false
      end,
    })
  ]==])
  -- Typed, like a user switching buffers, so the main loop gets its normal
  -- chance to redraw after the command and before scheduled callbacks.
  _G.child.type_keys('<Esc>', ':buffer ' .. _G.child.lua_get('_G._test_bufnr') .. '<CR>')
  _G.child.lua('vim.wait(100)')
  _G.child.lua("vim.cmd('redraw')")
  local target = _G.child.lua_get('_G._target')
  local frames = _G.child.lua_get('_G._frames')
  eq(type(target), 'number')
  eq(vim.trim(_G.child.lua_get('vim.api.nvim_buf_get_lines(_G._test_bufnr, ' .. (target - 1) .. ', ' .. target .. ', false)[1]')), 'Reopen 1')
  eq(#frames > 0, true)
  for i, f in ipairs(frames) do
    if f.top ~= target or f.cursor ~= target then
      error(string.format('frame %d shows top=%d cursor=%d, want %d: %s',
        i, f.top, f.cursor, target, vim.inspect(frames)))
    end
  end
end

T['codex turn end jumps to the final agent message'] = function()
  _G.child.lua([==[
    require('cc.config').setup({ provider = 'codex' })
    local Session = require('cc.session')
    local Output = require('cc.output')
    local session = Session.new()
    local output = Output.new(session, 'cc-test-output')
    local bufnr = output:ensure_buffer()
    vim.api.nvim_set_current_buf(bufnr)
    vim.cmd('resize 10')
    output:set_window(vim.api.nvim_get_current_win())
    local inst = { session = session, output = output }
    local provider = require('cc.providers.codex').attach({
      instance = inst, session = session, output = output, on_session_id = function() end,
    })
    provider.alive = true
    provider._write_line = function() end
    provider.turn_id = 'turn-1'
    provider.thread_id = 'thread-1'
    session.turn_active = true
    local function feed(method, params)
      params.threadId = provider.thread_id
      provider:_on_message({ method = method, params = params })
    end
    local function message(id, text)
      feed('item/started', { turnId = 'turn-1', item = { type = 'agentMessage', id = id, text = '' } })
      feed('item/completed', { turnId = 'turn-1', item = { type = 'agentMessage', id = id, text = text } })
    end
    message('m1', 'Let me look.')
    feed('item/started', { turnId = 'turn-1', item = { type = 'commandExecution', id = 'c1',
      command = 'ls', cwd = '/tmp', status = 'inProgress' } })
    feed('item/completed', { turnId = 'turn-1', item = { type = 'commandExecution', id = 'c1',
      command = 'ls', cwd = '/tmp', status = 'completed', aggregatedOutput = 'x', exitCode = 0 } })
    local lines = {}
    for i = 1, 30 do lines[i] = 'Codex final ' .. i end
    message('m2', table.concat(lines, '\n'))
    feed('turn/completed', { turn = { id = 'turn-1', items = {}, status = 'completed', durationMs = 10 } })
    _G._test_bufnr = bufnr
    _G._find = function(text)
      for i, l in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
        if vim.trim(l) == text then return i end
      end
    end
    _G._view = function()
      local v = vim.fn.winsaveview()
      return { lnum = v.lnum, topline = v.topline, last = vim.api.nvim_buf_line_count(bufnr) }
    end
  ]==])
  local target = find('Codex final 1')
  eq(type(target), 'number')
  eq(view().lnum, target)
  eq(view().topline, target)
end

T['command works on a resumed transcript'] = function()
  local bufnr = helpers.render_fixture(_G.child, 'simple_text')
  _G.child.lua([[
    _G._test_output:set_window(vim.api.nvim_get_current_win())
    _G._test_output:finalize_history_replay()
    _G._target = _G._test_output:last_message_lnum()
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    _G._test_output:jump_to_last_message()
  ]])
  local target = _G.child.lua_get('_G._target')
  eq(type(target), 'number')
  -- The target is the first text line of the (only) agent turn.
  local lines = _G.child.lua_get('vim.api.nvim_buf_get_lines(...)', { bufnr, 0, -1, false })
  local first_text
  for i, l in ipairs(lines) do
    if l == 'Agent:' then
      for j = i + 1, #lines do
        if vim.trim(lines[j]) ~= '' then first_text = j break end
      end
    end
  end
  eq(target, first_text)
  eq(_G.child.lua_get('vim.fn.line(".")'), target)
end

-- :CcJumpToNextMessage / :CcJumpToPrevMessage step through every finished
-- turn's last message. _G._notes collects their notices.

local function setup_steps()
  setup('{ jump_to_last_message_on_turn_end = false }')
  _G.child.lua([[
    _G._notes = {}
    vim.notify = function(msg, level) table.insert(_G._notes, { msg, level }) end
  ]])
end

local function step(cmd)
  _G.child.lua("vim.cmd('" .. cmd .. "')")
  return view().lnum
end

local function notes() return _G.child.lua_get('_G._notes') end

T['next and prev step through every turn'] = function()
  setup_steps()
  _G.child.lua('_G._turn(1) _G._turn(2) _G._turn(3)')
  local f1, f2, f3 = find('Final 1.1'), find('Final 2.1'), find('Final 3.1')
  _G.child.lua('vim.api.nvim_win_set_cursor(0, { 1, 0 })')
  eq(step('CcJumpToNextMessage'), f1)
  eq(view().topline, f1)
  eq(step('CcJumpToNextMessage'), f2)
  eq(step('CcJumpToNextMessage'), f3)
  eq(view().topline, f3)
  eq(step('CcJumpToPrevMessage'), f2)
  eq(step('CcJumpToPrevMessage'), f1)
  eq(view().topline, f1)
  eq(notes(), {})
end

T['next and prev search from the cursor line'] = function()
  setup_steps()
  _G.child.lua('_G._turn(1) _G._turn(2) _G._turn(3)')
  _G.child.lua('vim.api.nvim_win_set_cursor(0, { _G._find("Final 2.5"), 0 })')
  eq(step('CcJumpToNextMessage'), find('Final 3.1'))
  _G.child.lua('vim.api.nvim_win_set_cursor(0, { _G._find("Final 2.5"), 0 })')
  eq(step('CcJumpToPrevMessage'), find('Final 2.1'))
end

T['both ends keep the cursor and notify'] = function()
  setup_steps()
  _G.child.lua('_G._turn(1) _G._turn(2)')
  _G.child.lua('vim.cmd("CcJumpToLastMessage")')
  local last = view()
  eq(step('CcJumpToNextMessage'), last.lnum)
  eq(view(), last)
  eq(notes(), { { 'cc.nvim: no newer reply', vim.log.levels.INFO } })
  _G.child.lua('_G._notes = {}')
  local f1 = find('Final 1.1')
  eq(step('CcJumpToPrevMessage'), f1)
  local first = view()
  eq(step('CcJumpToPrevMessage'), f1)
  eq(view(), first)
  eq(notes(), { { 'cc.nvim: no older reply', vim.log.levels.INFO } })
end

T['a turn with no text gets no mark'] = function()
  setup_steps()
  _G.child.lua('_G._turn(1) _G._turn(2, { no_final = true }) _G._turn(3)')
  eq(#_G.child.lua_get('_G._test_output:message_lnums()'), 2)
  _G.child.lua('vim.api.nvim_win_set_cursor(0, { 1, 0 })')
  eq(step('CcJumpToNextMessage'), find('Final 1.1'))
  eq(step('CcJumpToNextMessage'), find('Final 3.1'))
  eq(step('CcJumpToPrevMessage'), find('Final 1.1'))
end

T['a closed fold does not trap the cursor'] = function()
  setup_steps()
  _G.child.lua('_G._turn(1) _G._turn(2) _G._turn(3)')
  local fold = _G.child.lua_get([[(function()
    vim.api.nvim_win_set_cursor(0, { _G._find('Final 2.1'), 0 })
    vim.cmd('normal! zc')
    return { vim.fn.foldclosed('.'), vim.fn.foldclosedend('.') }
  end)()]])
  eq(fold[1] > find('Final 1.1'), true)
  eq(fold[2] < find('Final 3.1'), true)
  eq(step('CcJumpToNextMessage'), find('Final 3.1'))
  -- Prev lands on the closed fold holding turn 2's message, then leaves it.
  eq(step('CcJumpToPrevMessage'), fold[1])
  eq(_G.child.lua_get('vim.fn.foldclosed(".")'), fold[1])
  eq(step('CcJumpToPrevMessage'), find('Final 1.1'))
  eq(step('CcJumpToNextMessage'), fold[1])
  eq(step('CcJumpToNextMessage'), find('Final 3.1'))
end

T['commands act on the output window from the prompt buffer'] = function()
  setup_steps()
  _G.child.lua([[
    _G._turn(1) _G._turn(2)
    _G._out_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    local prompt = vim.api.nvim_create_buf(false, true)
    _G._test_inst.prompt = { bufnr = prompt }
    vim.cmd('split')
    vim.api.nvim_set_current_buf(prompt)
    vim.cmd('CcJumpToNextMessage')
    vim.cmd('CcJumpToNextMessage')
    _G._out_lnum = vim.api.nvim_win_get_cursor(_G._out_win)[1]
  ]])
  eq(_G.child.lua_get('_G._out_lnum'), find('Final 2.1'))
  eq(notes(), {})
end

T['a replayed transcript has a mark for every turn with a reply'] = function()
  _G.child.lua([==[
    require('cc.config').setup({ jump_to_last_message_on_turn_end = false })
    local function user(text) return { type = 'user', message = { role = 'user', content = text } } end
    local function assistant(blocks) return { type = 'assistant', message = { role = 'assistant', content = blocks } } end
    local function result(id) return { type = 'user', message = { role = 'user', content = {
      { type = 'tool_result', tool_use_id = id, content = 'out', is_error = false } } } } end
    local function bash(id) return { type = 'tool_use', id = id, name = 'Bash', input = { command = 'ls' } } end
    local function text(t) return { type = 'text', text = t } end
    local records = {
      user('one'), assistant({ text('Reply one') }),
      user('two'), assistant({ text('Looking two'), bash('t2') }), result('t2'),
      user('three'), assistant({ text('Looking three'), bash('t3') }), result('t3'),
      assistant({ text('Reply three') }),
      user('four'), assistant({ text('Reply four') }),
    }
    local path = vim.fn.tempname() .. '.jsonl'
    vim.fn.writefile(vim.tbl_map(vim.json.encode, records), path)

    local output = require('cc.output').new(require('cc.session').new(), 'cc-test-output')
    local bufnr = output:ensure_buffer()
    vim.api.nvim_set_current_buf(bufnr)
    vim.cmd('resize 10')
    output:set_window(vim.api.nvim_get_current_win())
    for _, rec in ipairs(require('cc.history').read_transcript(path)) do
      output:render_historical_record(rec)
    end
    output:finalize_history_replay()
    require('cc')._register_test_instance(bufnr, { output = output })
    _G._test_output = output
    _G._find = function(t)
      for i, l in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
        if vim.trim(l) == t then return i end
      end
    end
    _G._view = function()
      local v = vim.fn.winsaveview()
      return { lnum = v.lnum, topline = v.topline, last = vim.api.nvim_buf_line_count(bufnr) }
    end
  ]==])
  local want = { find('Reply one'), find('Reply three'), find('Reply four') }
  eq(_G.child.lua_get('_G._test_output:message_lnums()'), want)
  eq(_G.child.lua_get('_G._test_output:last_message_lnum()'), want[3])
  _G.child.lua('vim.api.nvim_win_set_cursor(0, { 1, 0 })')
  eq(step('CcJumpToNextMessage'), want[1])
  eq(step('CcJumpToNextMessage'), want[2])
  eq(step('CcJumpToNextMessage'), want[3])
  eq(step('CcJumpToPrevMessage'), want[2])
end

return T
