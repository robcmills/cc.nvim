-- Auto-mode classifier denials (system/permission_denied): the permission
-- prompt flow (float, hooks, timeout stages) for a call the CLI already
-- denied. Approve submits an authorizing user message; everything else
-- sends nothing.
local helpers = dofile('tests/helpers.lua')
local MiniTest = require('mini.test')
local eq = MiniTest.expect.equality
local T = MiniTest.new_set({ hooks = helpers.shared_child_hooks() })

local function setup(options)
  _G.child.lua(([==[
    package.loaded['cc.permission_prompt'] = nil
    local config = require('cc.config')
    _G.events, _G.resolved, _G.writes = {}, {}, {}
    local opts = %s
    opts.statusline = { enabled = false }
    opts.on_permission_prompt = opts.on_permission_prompt or function(e)
      events[#events + 1] = e
    end
    opts.on_permission_resolved = opts.on_permission_resolved or function(e)
      resolved[#resolved + 1] = e
    end
    config.setup(opts)
    local session = require('cc.session').new()
    local output = require('cc.output').new(session, 'cc-test-denials-' .. vim.uv.hrtime())
    output:ensure_buffer()
    local process = {
      is_alive = function() return true end,
      write = function(_, msg) writes[#writes + 1] = msg end,
      close = function() end,
      consume_pending_control = function() end,
    }
    _G.inst = {
      session = session, session_name = 'denial-session', output = output,
      prompt = { bufnr = vim.api.nvim_create_buf(false, true) }, process = process,
    }
    require('cc')._register_test_instance(output.bufnr, inst)
    _G.router = require('cc.router').new({ session = session, output = output,
      process = process, instance = inst })
    _G.stream_tool = function(id, input)
      output:begin_assistant_turn()
      output:on_content_block_start({ type = 'tool_use', id = id, name = 'Bash' })
      output:on_content_block_stop({ type = 'tool_use', id = id, name = 'Bash', input = input })
    end
    _G.deny = function(id, extra)
      local msg = { type = 'system', subtype = 'permission_denied', tool_name = 'Bash',
        tool_use_id = id, decision_reason_type = 'classifier',
        decision_reason = 'Pushing to a remote was not requested.',
        message = 'Permission for this action has been denied.', uuid = 'u-' .. id,
        session_id = 's1' }
      for k, v in pairs(extra or {}) do msg[k] = v end
      router:dispatch(msg)
    end
    _G.lines = function()
      return table.concat(vim.api.nvim_buf_get_lines(output.bufnr, 0, -1, false), '\n')
    end
    _G.wait_resolved = function(n)
      assert(vim.wait(1500, function() return #resolved == (n or 1) end, 5))
    end
  ]==]):format(options or '{}'))
end

T['classifier denial waits with a denial event, card, and input'] = function()
  setup()
  _G.child.lua([[stream_tool('t1', { command = 'git push origin main' }); deny('t1')]])
  eq(_G.child.lua_get('require("cc.instance_state").get(inst)'), 'waiting')
  eq(_G.child.lua_get('events[1].kind'), 'denial')
  eq(_G.child.lua_get('events[1].reason'), 'Pushing to a remote was not requested.')
  eq(_G.child.lua_get('events[1].tool_use_id'), 't1')
  eq(_G.child.lua_get('events[1].input.command'), 'git push origin main')
  eq(_G.child.lua_get('events[1].request_id'), 'denial:t1')
  eq(_G.child.lua_get('inst.permission_winid ~= nil'), true)
  eq(_G.child.lua_get([[lines():find('⛔ Blocked by auto mode: Bash', 1, true) ~= nil]]), true)
  eq(_G.child.lua_get([[lines():find('Pushing to a remote was not requested.', 1, true) ~= nil]]), true)
  eq(_G.child.lua_get('#writes'), 0)
end

T['non-classifier denials are ignored'] = function()
  setup()
  _G.child.lua([[deny('t1', { decision_reason_type = 'rule' }); deny('t2', { decision_reason_type = 'mode' })]])
  eq(_G.child.lua_get('#events'), 0)
  eq(_G.child.lua_get('inst.awaiting_input == true'), false)
end

T['approve submits the exact call and clears waiting'] = function()
  setup()
  _G.child.lua([[stream_tool('t1', { command = 'git push origin main' }); deny('t1')]])
  _G.child.type_keys('a')
  _G.child.lua([[wait_resolved(); assert(vim.wait(1000, function() return #writes == 1 end, 5))]])
  eq(_G.child.lua_get('writes[1].type'), 'user')
  local text = _G.child.lua_get('writes[1].message.content')
  eq(text:find('Auto mode blocked this Bash call. I approve it', 1, true) ~= nil, true)
  eq(text:find('{"command":"git push origin main"}', 1, true) ~= nil, true)
  eq(_G.child.lua_get('resolved[1].kind'), 'denial')
  eq(_G.child.lua_get('resolved[1].behavior'), 'allow')
  eq(_G.child.lua_get('resolved[1].source'), 'local')
  eq(_G.child.lua_get('inst.awaiting_input'), false)
  eq(_G.child.lua_get([[lines():find('✓ Approved: Bash', 1, true) ~= nil]]), true)
end

T['approve mid-turn waits for the turn to end'] = function()
  setup()
  _G.child.lua([[
    stream_tool('t1', { command = 'git push' })
    inst.session.turn_active = true
    deny('t1')
    events[1].resolve('allow')
    vim.wait(50)
  ]])
  eq(_G.child.lua_get('#writes'), 0)
  eq(_G.child.lua_get('#inst.queued_prompts'), 1)
  _G.child.lua([[
    router:dispatch({ type = 'result', subtype = 'success', duration_ms = 1, usage = {} })
    assert(vim.wait(1000, function() return #writes == 1 end, 5))
  ]])
  eq(_G.child.lua_get('writes[1].type'), 'user')
  eq(_G.child.lua_get('inst.queued_prompts == nil'), true)
end

T['dismiss clears waiting and sends nothing'] = function()
  setup()
  _G.child.lua([[stream_tool('t1', { command = 'git push' }); deny('t1')]])
  _G.child.type_keys('d')
  _G.child.lua([[wait_resolved(); vim.wait(50)]])
  eq(_G.child.lua_get('#writes'), 0)
  eq(_G.child.lua_get('resolved[1].behavior'), 'deny')
  eq(_G.child.lua_get('inst.awaiting_input'), false)
  eq(_G.child.lua_get('next(router.open_prompts) == nil'), true)
  eq(_G.child.lua_get([[lines():find('✗ Dismissed: Bash', 1, true) ~= nil]]), true)
end

T['timeout stages run and a timeout deny sends nothing'] = function()
  setup([[{ permission_timeouts = {
    { after = 0.03, callback = function(e) _G.stage1 = { stage = e.stage, kind = e.kind } end },
    { after = 0.03, callback = function(e) e.resolve('deny', 'Approval timeout.') end },
  } }]])
  _G.child.lua([[stream_tool('t1', { command = 'git push' }); deny('t1'); wait_resolved(); vim.wait(50)]])
  eq(_G.child.lua_get('stage1'), { stage = 1, kind = 'denial' })
  eq(_G.child.lua_get('resolved[1].source'), 'api')
  eq(_G.child.lua_get('resolved[1].behavior'), 'deny')
  eq(_G.child.lua_get('#writes'), 0)
  eq(_G.child.lua_get('inst.awaiting_input'), false)
  eq(_G.child.lua_get('inst.permission_winid == nil'), true)
end

T['subagent denial surfaces on the parent and names the subagent'] = function()
  setup()
  _G.child.lua([[
    deny('sub-t1', { agent_id = 'agent-42' })
    events[1].resolve('allow')
    assert(vim.wait(1000, function() return #writes == 1 end, 5))
  ]])
  eq(_G.child.lua_get('events[1].agent_id'), 'agent-42')
  local text = _G.child.lua_get('writes[1].message.content')
  eq(text:find('Bash call inside subagent agent-42', 1, true) ~= nil, true)
end

T['teardown resolves as closed without sending'] = function()
  setup()
  _G.child.lua([[
    deny('t1')
    require('cc.permission_prompt').close_pending(inst)
    vim.wait(50)
  ]])
  eq(_G.child.lua_get('resolved[1].source'), 'closed')
  eq(_G.child.lua_get('#writes'), 0)
  eq(_G.child.lua_get('inst.awaiting_input'), false)
end

T['duplicate denial for the same call opens one prompt'] = function()
  setup()
  _G.child.lua([[deny('t1'); deny('t1')]])
  eq(_G.child.lua_get('#events'), 1)
end

T['every denial type fires CcPermissionDenied'] = function()
  setup()
  _G.child.lua([[
    _G.denied = {}
    vim.api.nvim_create_autocmd('User', { pattern = 'CcPermissionDenied',
      callback = function(a) denied[#denied + 1] = a.data end })
    stream_tool('t1', { command = 'echo denyrule' })
    deny('t1', { decision_reason_type = 'rule', decision_reason = vim.NIL })
    deny('t2')
  ]])
  eq(_G.child.lua_get('#denied'), 2)
  eq(_G.child.lua_get('denied[1].decision_reason_type'), 'rule')
  eq(_G.child.lua_get('denied[1].input.command'), 'echo denyrule')
  eq(_G.child.lua_get('denied[1].session_name'), 'denial-session')
  eq(_G.child.lua_get('denied[2].reason'), 'Pushing to a remote was not requested.')
  -- Only the classifier block opens a prompt.
  eq(_G.child.lua_get('#events'), 1)
end

T['a real prompt for the same call supersedes the denial float'] = function()
  setup()
  _G.child.lua([[
    stream_tool('t1', { command = 'git push origin main', description = 'Push' })
    deny('t1')
    router:dispatch({ type = 'control_request', request_id = 'r1', request = {
      subtype = 'can_use_tool', tool_name = 'Bash', tool_use_id = 't2',
      input = { command = 'git push origin main', description = 'Push (retry)' } } })
    vim.wait(50)
  ]])
  eq(_G.child.lua_get('resolved[1].source'), 'superseded')
  eq(_G.child.lua_get('resolved[1].kind'), 'denial')
  eq(_G.child.lua_get('router.open_prompts["denial:t1"] == nil'), true)
  eq(_G.child.lua_get('router.open_prompts["r1"] ~= nil'), true)
  eq(_G.child.lua_get('events[2].kind'), 'permission')
  eq(_G.child.lua_get('#writes'), 0)
  eq(_G.child.lua_get([[lines():find('replaced by a permission prompt', 1, true) ~= nil]]), true)
  eq(_G.child.lua_get([[lines():find('Dismissed', 1, true) == nil]]), true)
end

T['a prompt for a different call does not supersede the denial'] = function()
  setup()
  _G.child.lua([[
    stream_tool('t1', { command = 'git push origin main' })
    deny('t1')
    router:dispatch({ type = 'control_request', request_id = 'r1', request = {
      subtype = 'can_use_tool', tool_name = 'Bash', tool_use_id = 't2',
      input = { command = 'git push origin dev' } } })
    vim.wait(50)
  ]])
  -- A second float closes the first (existing behavior), but never as superseded.
  eq(_G.child.lua_get('resolved[1] == nil or resolved[1].source ~= "superseded"'), true)
  eq(_G.child.lua_get([[lines():find('replaced by a permission prompt', 1, true) == nil]]), true)
end

T['a real prompt denied by timeout leaves the agent waiting until the next user turn'] = function()
  setup([[{ permission_timeouts = {
    { after = 0.03, callback = function(e) e.resolve('deny', 'Approval timeout.') end },
  } }]])
  _G.child.lua([[
    inst.session.turn_active = true
    router:dispatch({ type = 'control_request', request_id = 'r1', request = {
      subtype = 'can_use_tool', tool_name = 'Bash', tool_use_id = 't1',
      input = { command = 'ask-rob "x: need prod; approve?"' } } })
    wait_resolved(); vim.wait(50)
  ]])
  eq(_G.child.lua_get('resolved[1].timed_out'), true)
  eq(_G.child.lua_get('writes[1].response.response.behavior'), 'deny')
  -- Mid-turn the agent is still working; once the turn ends it waits.
  eq(_G.child.lua_get('require("cc.instance_state").get(inst)'), 'working')
  _G.child.lua([[inst.session.turn_active = false]])
  eq(_G.child.lua_get('require("cc.instance_state").get(inst)'), 'waiting')
  eq(_G.child.lua_get('inst.blocked.tool_name'), 'Bash')
  eq(_G.child.lua_get('inst.blocked.kind'), 'permission')
  -- Rob replies from his phone: the replayed user message clears it.
  _G.child.lua([[router:dispatch({ type = 'user', isReplay = true, uuid = 'remote-1',
    message = { role = 'user', content = 'approved' } })]])
  eq(_G.child.lua_get('inst.blocked == nil'), true)
  eq(_G.child.lua_get('require("cc.instance_state").get(inst)'), 'working')
end

T['a local deny or a denial float timeout blocks nothing'] = function()
  setup([[{ permission_timeouts = {
    { after = 0.03, callback = function(e) e.resolve('deny', 'Approval timeout.') end },
  } }]])
  _G.child.lua([[deny('t1'); wait_resolved(); vim.wait(50)]])
  eq(_G.child.lua_get('resolved[1].timed_out'), true)
  eq(_G.child.lua_get('inst.blocked == nil'), true)
  _G.child.lua([[
    router:dispatch({ type = 'control_request', request_id = 'r2', request = {
      subtype = 'can_use_tool', tool_name = 'Bash', tool_use_id = 't2', input = { command = 'ls' } } })
    events[2].resolve('deny')
    vim.wait(50)
  ]])
  eq(_G.child.lua_get('resolved[2].timed_out == nil'), true)
  eq(_G.child.lua_get('inst.blocked == nil'), true)
end

T['enable_remote(bufnr) turns the bridge on once for that instance'] = function()
  setup()
  _G.child.lua([[
    _G.rc = {}
    inst.provider = { set_remote_control = function(_, enabled, name, cb)
      rc[#rc + 1] = { enabled, name }; _G.rc_cb = cb; return 'rc-1' end }
    _G.first = require('cc').enable_remote(inst.prompt.bufnr)
    _G.second = require('cc').enable_remote(inst.output.bufnr)
    rc_cb(true)
    inst.session.remote_control_state = 'connected'
    _G.third = require('cc').enable_remote(inst.output.bufnr)
  ]])
  eq(_G.child.lua_get('{ first, second, third }'), { true, false, false })
  eq(_G.child.lua_get('rc'), { { true, 'denial-session' } })
  eq(_G.child.lua_get('require("cc").enable_remote(99999)'), false)
end

return T
