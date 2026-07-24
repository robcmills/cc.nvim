-- Tests for the stream-json control_request interrupt protocol.
-- Verifies the client-side wire format and the router's handling of
-- control_response messages.
local helpers = dofile('tests/helpers.lua')
local MiniTest = require('mini.test')
local eq = MiniTest.expect.equality

local T = MiniTest.new_set({
  hooks = helpers.shared_child_hooks(),
})

--- Set up a Process with stubbed stdin/alive and a recording write sink.
--- Returns nothing; state is in _G._test_* in the child.
local function setup_fake_process(child)
  child.lua([==[
    local Process = require('cc.process')
    local Router = require('cc.router')
    local Output = require('cc.output')
    local Session = require('cc.session')
    require('cc.config').setup({})

    local session = Session.new()
    local output = Output.new(session, 'cc-test-output')
    local bufnr = output:ensure_buffer()
    vim.api.nvim_set_current_buf(bufnr)

    local sent = {}
    local process = Process.new({
      cmd = 'unused',
      on_message = function() end,
    })
    -- Stub out the fields :write() checks, redirect to capture.
    process.alive = true
    process.stdin = {}
    process.write = function(self, msg) table.insert(sent, msg) end

    local router = Router.new({ session = session, output = output, process = process })

    _G._test_bufnr = bufnr
    _G._test_session = session
    _G._test_output = output
    _G._test_process = process
    _G._test_router = router
    _G._test_sent = sent
  ]==])
end

T['send_control_interrupt writes correct JSON shape'] = function()
  setup_fake_process(_G.child)
  _G.child.lua([[
    _G._test_request_id = _G._test_process:send_control_interrupt()
  ]])
  local request_id = _G.child.lua_get('_G._test_request_id')
  local sent = _G.child.lua_get('_G._test_sent')

  eq(type(request_id), 'string')
  eq(#sent, 1)
  eq(sent[1].type, 'control_request')
  eq(sent[1].request_id, request_id)
  eq(sent[1].request.subtype, 'interrupt')
end

T['send_control_interrupt tracks pending by request_id'] = function()
  setup_fake_process(_G.child)
  _G.child.lua([[
    _G._test_request_id = _G._test_process:send_control_interrupt()
    _G._test_subtype = _G._test_process:consume_pending_control(_G._test_request_id)
    _G._test_subtype2 = _G._test_process:consume_pending_control(_G._test_request_id)
  ]])
  eq(_G.child.lua_get('_G._test_subtype'), 'interrupt')
  -- Second consume returns nil (already removed).
  eq(_G.child.lua_get('_G._test_subtype2'), vim.NIL)
end

T['send_control_interrupt returns nil when process not alive'] = function()
  setup_fake_process(_G.child)
  _G.child.lua([[
    _G._test_process.alive = false
    _G._test_request_id = _G._test_process:send_control_interrupt()
  ]])
  eq(_G.child.lua_get('_G._test_request_id'), vim.NIL)
end

T['successful interrupt renders timing only and absorbs trailing result'] = function()
  setup_fake_process(_G.child)
  _G.child.lua([[
    _G._test_session.is_streaming = true
    _G._test_session.turn_active = true
    _G._test_session.turn_started_at = (vim.uv or vim.loop).now() - 5000
    _G._test_session.interrupt_pending = true
    local rid = _G._test_process:send_control_interrupt()
    _G._test_router:dispatch({
      type = 'control_response',
      response = { subtype = 'success', request_id = rid },
    })
    _G._test_router:dispatch({
      type = 'result',
      total_cost_usd = 9.99,
      usage = {
        input_tokens = 7,
        output_tokens = 8,
        cache_read_input_tokens = 9,
        cache_creation_input_tokens = 10,
      },
    })
  ]])
  local lines = helpers.get_buffer_lines(_G.child)
  local text = table.concat(lines, '\n')
  local notice = text:find('── Interrupted ──', 1, true)
  local stamp = text:find('── 20%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ │ 5s ──')
  assert(notice, 'expected "Interrupted" in output, got:\n' .. text)
  assert(stamp, 'expected timestamp and duration in output, got:\n' .. text)
  eq(notice < stamp, true)
  eq(text:find('$', 1, true), nil)
  eq(text:find('7 in', 1, true), nil)
  eq(text:find('8 out', 1, true), nil)
  eq(text:find('9 cache read', 1, true), nil)
  eq(text:find('10 cache write', 1, true), nil)
  -- The trailing result still updates cumulative session state.
  eq(_G.child.lua_get('_G._test_session.cost_usd'), 9.99)
  eq(_G.child.lua_get('_G._test_session.input_tokens'), 7)
  eq(_G.child.lua_get('_G._test_session.is_streaming'), false)
  eq(_G.child.lua_get('_G._test_session.interrupt_pending'), false)
end

T['router handles error control_response for interrupt'] = function()
  setup_fake_process(_G.child)
  _G.child.lua([[
    _G._test_session.is_streaming = true
    _G._test_session.interrupt_pending = true
    local rid = _G._test_process:send_control_interrupt()
    _G._test_router:dispatch({
      type = 'control_response',
      response = { subtype = 'error', request_id = rid, error = 'nope' },
    })
  ]])
  local lines = helpers.get_buffer_lines(_G.child)
  local text = table.concat(lines, '\n')
  if not text:find('Interrupt failed') then
    error('expected "Interrupt failed" in output, got:\n' .. text)
  end
end

-- A long-running tool aborted by an interrupt never gets a tool_result, so
-- its 1Hz elapsed-time timer used to tick forever. A successful interrupt must
-- stop every in-flight tool timer.
T['successful interrupt stops in-flight tool timers'] = function()
  setup_fake_process(_G.child)
  _G.child.lua([[
    _G._test_output:on_content_block_start({ type = 'tool_use', id = 'tool-1', name = 'Bash' })
    _G._test_output:start_tool_timer('tool-1')
    _G._test_had_timer = _G._test_output._tool_timers['tool-1'] ~= nil

    _G._test_session.is_streaming = true
    _G._test_session.interrupt_pending = true
    local rid = _G._test_process:send_control_interrupt()
    _G._test_router:dispatch({
      type = 'control_response',
      response = { subtype = 'success', request_id = rid },
    })
  ]])
  eq(_G.child.lua_get('_G._test_had_timer'), true)
  eq(_G.child.lua_get('_G._test_output._tool_timers["tool-1"]'), vim.NIL)
end

-- A failed interrupt means the turn is still live, so the tool is still
-- running — its timer must keep ticking, not be stopped prematurely.
T['failed interrupt leaves in-flight tool timers running'] = function()
  setup_fake_process(_G.child)
  _G.child.lua([[
    _G._test_output:on_content_block_start({ type = 'tool_use', id = 'tool-1', name = 'Bash' })
    _G._test_output:start_tool_timer('tool-1')
    _G._test_session.is_streaming = true
    _G._test_session.interrupt_pending = true
    local rid = _G._test_process:send_control_interrupt()
    _G._test_router:dispatch({
      type = 'control_response',
      response = { subtype = 'error', request_id = rid, error = 'nope' },
    })
    _G._test_still_running = _G._test_output._tool_timers['tool-1'] ~= nil
    _G._test_output:stop_tool_timer('tool-1') -- clean up the libuv handle
  ]])
  eq(_G.child.lua_get('_G._test_still_running'), true)
end

-- The terminal `result` message is the catch-all: any tool whose result never
-- arrived (e.g. a turn that errored mid-tool) is orphaned and must be stopped.
T['result message stops orphaned tool timers'] = function()
  setup_fake_process(_G.child)
  _G.child.lua([[
    _G._test_output:on_content_block_start({ type = 'tool_use', id = 'tool-1', name = 'Bash' })
    _G._test_output:start_tool_timer('tool-1')
    _G._test_had_timer = _G._test_output._tool_timers['tool-1'] ~= nil
    _G._test_router:dispatch({ type = 'result', subtype = 'success', total_cost_usd = 0.01 })
  ]])
  eq(_G.child.lua_get('_G._test_had_timer'), true)
  eq(_G.child.lua_get('_G._test_output._tool_timers["tool-1"]'), vim.NIL)
end

T['router ignores control_response with unknown request_id'] = function()
  setup_fake_process(_G.child)
  _G.child.lua([[
    _G._test_session.is_streaming = true
    _G._test_router:dispatch({
      type = 'control_response',
      response = { subtype = 'success', request_id = 'never-sent' },
    })
  ]])
  -- Streaming should NOT have been cleared by a stray response.
  eq(_G.child.lua_get('_G._test_session.is_streaming'), true)
  local lines = helpers.get_buffer_lines(_G.child)
  local text = table.concat(lines, '\n')
  if text:find('Interrupted') then
    error('did not expect "Interrupted" for unknown request_id, got:\n' .. text)
  end
end

T['session clears interrupt_pending on result'] = function()
  setup_fake_process(_G.child)
  _G.child.lua([[
    _G._test_session.interrupt_pending = true
    _G._test_session:on_result({ total_cost_usd = 0.01 })
  ]])
  eq(_G.child.lua_get('_G._test_session.interrupt_pending'), false)
end

T['session clears interrupt_pending on new user turn'] = function()
  setup_fake_process(_G.child)
  _G.child.lua([[
    _G._test_session.interrupt_pending = true
    _G._test_session:add_user_turn('hello')
  ]])
  eq(_G.child.lua_get('_G._test_session.interrupt_pending'), false)
end

return T
