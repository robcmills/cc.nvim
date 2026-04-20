-- Tests for the stream-json control_request interrupt protocol.
-- Verifies the client-side wire format and the router's handling of
-- control_response messages.
local helpers = dofile('tests/helpers.lua')
local MiniTest = require('mini.test')
local eq = MiniTest.expect.equality

local T = MiniTest.new_set({
  hooks = {
    pre_case = function() _G.child = helpers.new_child() end,
    post_case = function() if _G.child then _G.child.stop() end end,
  },
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
      claude_cmd = 'unused',
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

T['router handles successful control_response for interrupt'] = function()
  setup_fake_process(_G.child)
  _G.child.lua([[
    _G._test_session.is_streaming = true
    _G._test_session.interrupt_pending = true
    local rid = _G._test_process:send_control_interrupt()
    _G._test_router:dispatch({
      type = 'control_response',
      response = { subtype = 'success', request_id = rid },
    })
  ]])
  local lines = helpers.get_buffer_lines(_G.child)
  local text = table.concat(lines, '\n')
  if not text:find('Interrupted') then
    error('expected "Interrupted" in output, got:\n' .. text)
  end
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
