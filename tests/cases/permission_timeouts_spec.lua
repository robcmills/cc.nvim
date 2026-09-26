-- Request lifecycle tests: real uv timers and provider-neutral handles, with
-- a real float unless concurrent prompts or synchronous choices need a fake.
local helpers = dofile('tests/helpers.lua')
local MiniTest = require('mini.test')
local eq = MiniTest.expect.equality
local T = MiniTest.new_set({ hooks = helpers.shared_child_hooks() })

local function setup(options, fake)
  _G.child.lua(([==[
    package.loaded['cc.permission_prompt'] = nil
    local config = require('cc.config')
    _G.events, _G.resolved, _G.writes, _G.outcomes, _G.remote = {}, {}, {}, {}, {}
    local opts = %s
    opts.statusline = { enabled = false }
    opts.on_permission_prompt = opts.on_permission_prompt or function(e) events[e.request_id] = e end
    opts.on_permission_resolved = opts.on_permission_resolved or function(e)
      resolved[#resolved + 1] = e
    end
    config.setup(opts)
    local session = require('cc.session').new()
    local output = require('cc.output').new(session, 'cc-test-timeouts')
    output:ensure_buffer()
    output.render_permission_request = function() end
    output.render_permission_outcome = function(_, behavior, tool)
      outcomes[#outcomes + 1] = { behavior, tool }
    end
    local process = {
      is_alive = function() return true end,
      write = function(_, msg) writes[#writes + 1] = msg end,
      close = function() end,
      consume_pending_control = function() end,
    }
    _G.inst = {
      session = session, session_name = 'permission-session', output = output,
      prompt = { bufnr = vim.api.nvim_create_buf(false, true) }, process = process,
      provider = {
        name = 'claude', set_remote_control = function(_, enabled, name, cb)
          remote[#remote + 1] = { enabled = enabled, name = name }
          _G.remote_cb = cb
          return 'remote-' .. #remote
        end,
      },
    }
    require('cc')._register_test_instance(output.bufnr, inst)
    _G.router = require('cc.router').new({ session = session, output = output,
      process = process, instance = inst })
    _G.choices = {}
    if %s then
      require('cc.permission_prompt').ask = function(_, _, on_choice, context)
        choices[context.request_id] = on_choice
        config.options.on_permission_prompt({ request_id = context.request_id,
          resolve = context.resolve, enable_remote = context.enable_remote,
          disable_remote = context.disable_remote })
        return { dismiss = function() end }
      end
    end
    _G.open_request = function(id)
      router:dispatch({ type = 'control_request', request_id = id, request = {
        subtype = 'can_use_tool', tool_name = 'Bash', tool_use_id = 'tool-' .. id,
        input = { command = 'pwd' }, permission_suggestions = {
          { type = 'addRules', rules = { { toolName = 'Bash' } } },
        },
      } })
    end
    _G.wait_resolved = function(n)
      assert(vim.wait(1500, function() return #resolved == (n or 1) end, 5))
    end
  ]==]):format(options or '{}', tostring(fake or false)))
end

T['stages fire in order relative to actual preceding firing'] = function()
  setup([[{ permission_timeouts = {
    { after = 0.05, callback = function(e)
      _G.first = { stage = e.stage, elapsed = e.elapsed, at = vim.uv.hrtime() }
      -- Model a delayed callback; the next delay starts at firing, not completion.
      vim.wait(30)
    end },
    { after = 0.10, callback = function(e)
      _G.second = { stage = e.stage, elapsed = e.elapsed, at = vim.uv.hrtime() }
      e.resolve('deny')
    end },
  } }]])
  _G.child.lua([[open_request('timing'); vim.uv.sleep(100); wait_resolved()]])
  eq(_G.child.lua_get('first.stage'), 1)
  eq(_G.child.lua_get('second.stage'), 2)
  eq(_G.child.lua_get('first.elapsed >= 0.045'), true)
  eq(_G.child.lua_get('(second.at - first.at) / 1e9 >= 0.095'), true)
  eq(_G.child.lua_get('second.elapsed >= 0.14'), true)
  eq(_G.child.lua_get('resolved[1].stage == nil'), true)
  eq(_G.child.lua_get('events.timing.opened_at <= os.time()'), true)
  eq(_G.child.lua_get('events.timing.request_id'), 'timing')
end

T['local answer stops and closes the timer before its deadline'] = function()
  setup([[{ permission_timeouts = {
    { after = 0.05, callback = function() _G.fired = true end },
  } }]])
  _G.child.lua([[
    _G.fired = false
    local new_timer = vim.uv.new_timer
    vim.uv.new_timer = function() _G.timer = new_timer(); return timer end
    open_request('local')
    vim.uv.new_timer = new_timer
  ]])
  _G.child.type_keys('a')
  _G.child.lua([[wait_resolved(); vim.wait(100)]])
  eq(_G.child.lua_get('fired'), false)
  eq(_G.child.lua_get('timer:is_closing()'), true)
  eq(_G.child.lua_get('resolved[1].source'), 'local')
  eq(_G.child.lua_get('resolved[1].behavior'), 'allow')
  eq(_G.child.lua_get('inst.awaiting_permission'), false)
  eq(_G.child.lua_get('next(router.open_prompts) == nil'), true)
end

T['remote cancellation stops timers and reports remote without writing an answer'] = function()
  setup([[{ permission_timeouts = {
    { after = 0.05, callback = function() _G.fired = true end },
  } }]])
  _G.child.lua([[
    _G.fired = false
    open_request('remote')
    router:_handle_control_cancel({ request_id = 'remote' })
    vim.wait(100)
  ]])
  eq(_G.child.lua_get('fired'), false)
  eq(_G.child.lua_get('#writes'), 0)
  eq(_G.child.lua_get('resolved[1].source'), 'remote')
  eq(_G.child.lua_get('resolved[1].behavior == nil'), true)
  eq(_G.child.lua_get('outcomes'), { { 'remote', 'Bash' } })
  eq(_G.child.lua_get('inst.permission_winid == nil'), true)
  eq(_G.child.lua_get("events.remote.resolve('allow')"), false)
end

T['API deny uses custom message and resolves exactly once'] = function()
  setup()
  _G.child.lua([[
    open_request('deny')
    _G.first_result = events.deny.resolve('deny', 'Approval timeout. Work around safely.')
    _G.second_result = events.deny.resolve('allow')
    router:_handle_control_cancel({ request_id = 'deny' })
  ]])
  eq(_G.child.lua_get('first_result'), true)
  eq(_G.child.lua_get('second_result'), false)
  eq(_G.child.lua_get('#resolved'), 1)
  eq(_G.child.lua_get('#writes'), 1)
  eq(_G.child.lua_get('writes[1].response.response'), {
    behavior = 'deny', message = 'Approval timeout. Work around safely.',
    toolUseID = 'tool-deny', decisionClassification = 'user_reject',
  })
  eq(_G.child.lua_get('resolved[1].source'), 'api')
  eq(_G.child.lua_get('inst.permission_winid == nil'), true)
end

T['API allow never persists a rule and invalid behavior leaves request pending'] = function()
  setup()
  _G.child.lua([[
    open_request('allow')
    _G.invalid = events.allow.resolve('allow_always')
    _G.allowed = events.allow.resolve('allow')
  ]])
  eq(_G.child.lua_get('invalid'), false)
  eq(_G.child.lua_get('allowed'), true)
  eq(_G.child.lua_get('writes[1].response.response.updatedPermissions == nil'), true)
  eq(_G.child.lua_get('writes[1].response.response.decisionClassification'), 'user_temporary')
end

T['stage enables remote once with current name and resolved callback can disable it'] = function()
  setup([[{ permission_timeouts = {
    { after = 0.01, callback = function(e)
      _G.enabled = e.enable_remote()
      _G.again = e.enable_remote()
      e.resolve('deny')
    end },
  }, on_permission_resolved = function(e)
    resolved[#resolved + 1] = e
    if e.remote_enabled_by_stage then e.disable_remote() end
  end }]])
  _G.child.lua([[open_request('enable'); inst.session_name = 'renamed'; wait_resolved()]])
  eq(_G.child.lua_get('enabled'), true)
  eq(_G.child.lua_get('again'), false)
  eq(_G.child.lua_get('remote'), {
    { enabled = true, name = 'renamed' }, { enabled = false },
  })
  eq(_G.child.lua_get('resolved[1].remote_enabled_by_stage'), true)
end

for _, state in ipairs({ 'ready', 'connected', 'reconnecting' }) do
  T['enable_remote skips an already ' .. state .. ' bridge'] = function()
    setup()
    _G.child.lua(([[
      inst.session.remote_control_state = %q
      open_request('ready')
      _G.enabled = events.ready.enable_remote()
      events.ready.resolve('deny')
    ]]):format(state))
    eq(_G.child.lua_get('enabled'), false)
    eq(_G.child.lua_get('#remote'), 0)
    eq(_G.child.lua_get('resolved[1].remote_enabled_by_stage'), false)
  end
end

T['public resolve by ID and snapshots keep concurrent requests independent and JSON safe'] = function()
  setup([[{ permission_timeouts = {
    { after = 0.05, callback = function(e) _G.stage_id = e.request_id; e.resolve('deny') end },
  } }]], true)
  _G.child.lua([[
    open_request('one'); open_request('two')
    _G.snapshot = vim.json.decode(vim.json.encode(require('cc').list_instances()))[1]
    _G.answer = require('cc').resolve_permission('one', 'allow')
    _G.waiting_after_one = inst.awaiting_permission
    wait_resolved(2)
    _G.missing = require('cc').resolve_permission('missing', 'deny')
    _G.duplicate = require('cc').resolve_permission('one', 'deny')
    _G.empty = vim.json.decode(vim.json.encode(require('cc').list_instances()))[1]
  ]])
  eq(_G.child.lua_get('snapshot.awaiting_permission'), true)
  eq(_G.child.lua_get('#snapshot.pending_permissions'), 2)
  eq(_G.child.lua_get('snapshot.pending_permissions[1].request_id'), 'one')
  eq(_G.child.lua_get('snapshot.pending_permissions[1].tool_name'), 'Bash')
  eq(_G.child.lua_get('snapshot.pending_permissions[1].input'), { command = 'pwd' })
  eq(_G.child.lua_get('type(snapshot.pending_permissions[1].opened_at)'), 'number')
  eq(_G.child.lua_get('answer and waiting_after_one'), true)
  eq(_G.child.lua_get('stage_id'), 'two')
  eq(_G.child.lua_get('missing or duplicate'), false)
  eq(_G.child.lua_get('empty.awaiting_permission'), false)
  eq(_G.child.lua_get('empty.pending_permissions'), {})
end

T['callback errors are isolated and later stages still resolve'] = function()
  setup([[{
    on_permission_prompt = function() error('opening failed') end,
    permission_timeouts = {
      { after = 0.01, callback = function() error('stage failed') end },
      { after = 0.01, callback = function(e) e.resolve('deny', 'timeout') end },
    },
    on_permission_resolved = function(e)
      resolved[#resolved + 1] = e
      error('resolved failed')
    end,
  }]])
  _G.child.lua([[
    local notify = vim.notify
    _G.errors = {}
    vim.notify = function(msg, level) errors[#errors + 1] = { msg, level } end
    open_request('errors'); wait_resolved()
    vim.notify = notify
  ]])
  eq(_G.child.lua_get('#errors'), 3)
  eq(_G.child.lua_get("errors[1][1]:find('on_permission_prompt callback failed', 1, true) ~= nil"), true)
  eq(_G.child.lua_get("errors[2][1]:find('permission_timeouts[1] callback failed', 1, true) ~= nil"), true)
  eq(_G.child.lua_get("errors[3][1]:find('on_permission_resolved callback failed', 1, true) ~= nil"), true)
  eq(_G.child.lua_get('writes[1].response.response.message'), 'timeout')
  eq(_G.child.lua_get('inst.awaiting_permission'), false)
end

T['on_permission_prompt can resolve synchronously without leaving a float or timer'] = function()
  setup([[{ on_permission_prompt = function(e) e.resolve('allow') end,
    permission_timeouts = { { after = 0.01, callback = function() _G.fired = true end } },
  }]])
  _G.child.lua([[_G.fired = false; open_request('immediate'); vim.wait(50)]])
  eq(_G.child.lua_get('fired'), false)
  eq(_G.child.lua_get('#writes'), 1)
  eq(_G.child.lua_get('inst.permission_winid == nil'), true)
  eq(_G.child.lua_get('next(router.open_prompts) == nil'), true)
end

T['instance close dismisses all pending requests and closes their timers'] = function()
  setup([[{ permission_timeouts = {
    { after = 0.05, callback = function() _G.fired = true end },
  } }]], true)
  _G.child.lua([[
    _G.fired = false
    open_request('one'); open_request('two')
    assert(require('cc').close(inst.output.bufnr))
    vim.wait(100)
  ]])
  eq(_G.child.lua_get('fired'), false)
  eq(_G.child.lua_get('#resolved'), 2)
  eq(_G.child.lua_get('resolved[1].source'), 'closed')
  eq(_G.child.lua_get('resolved[2].source'), 'closed')
  eq(_G.child.lua_get('#writes'), 0)
  eq(_G.child.lua_get('inst.awaiting_permission'), false)
end

T['empty config creates no stage timer and preserves local choices'] = function()
  setup()
  _G.child.lua([[
    require('cc.config').setup({ statusline = { enabled = false } })
    local new_timer = vim.uv.new_timer
    _G.timer_count = 0
    vim.uv.new_timer = function() timer_count = timer_count + 1; return new_timer() end
    open_request('empty')
    vim.uv.new_timer = new_timer
  ]])
  _G.child.type_keys('A')
  _G.child.lua([[assert(vim.wait(500, function() return #writes == 1 end))]])
  eq(_G.child.lua_get('timer_count'), 0)
  eq(_G.child.lua_get('writes[1].response.response.decisionClassification'), 'user_permanent')
  eq(_G.child.lua_get('#resolved'), 0)
end

T['echoed remote decisions cancel later stages without duplicate answers'] = function()
  setup([[{ permission_timeouts = {
    { after = 0.05, callback = function() _G.fired = true end },
  } }]])
  _G.child.lua([[
    _G.fired = false
    open_request('echo')
    router:_handle_control_response({ response = { request_id = 'echo',
      response = { behavior = 'deny' } } })
    vim.wait(100)
  ]])
  eq(_G.child.lua_get('fired'), false)
  eq(_G.child.lua_get('resolved[1].behavior'), 'deny')
  eq(_G.child.lua_get('resolved[1].source'), 'remote')
  eq(_G.child.lua_get('#writes'), 0)
end

T['public resolve searches other instances and preserves remaining requests'] = function()
  setup('{}', true)
  _G.child.lua([[
    open_request('first-instance')
    local second = {
      output = { bufnr = vim.api.nvim_create_buf(false, true) },
      prompt = { bufnr = vim.api.nvim_create_buf(false, true) },
      session = require('cc.session').new(), provider = { name = 'claude' },
    }
    require('cc')._register_test_instance(second.output.bufnr, second)
    require('cc.permission_prompt').request('Read', {}, function() end,
      { request_id = 'second-instance', provider = 'claude', instance = second })
    assert(require('cc').resolve_permission('second-instance', 'deny'))
    _G.first_waiting = inst.awaiting_permission
    _G.second_waiting = second.awaiting_permission
    assert(require('cc').resolve_permission('first-instance', 'allow'))
  ]])
  eq(_G.child.lua_get('first_waiting'), true)
  eq(_G.child.lua_get('second_waiting'), false)
  eq(_G.child.lua_get('#resolved'), 2)
end

T['process exit resolves pending requests as closed and prevents later stages'] = function()
  setup([[{ permission_timeouts = {
    { after = 0.05, callback = function() _G.fired = true end },
  } }]])
  _G.child.lua([[
    _G.fired = false
    local P = require('cc.providers.claude')
    local attach = P.attach
    local process = inst.process
    P.attach = function(ctx)
      _G.exit_callback = ctx.on_exit
      _G.exit_inst = ctx.instance
      return { name = 'claude', spawn = function() end, process = process }
    end
    require('cc').open({ focus = false })
    P.attach = attach
    local r = require('cc.router').new({ instance = exit_inst, process = process,
      output = exit_inst.output, session = exit_inst.session })
    r:_handle_permission_request('exit', { tool_name = 'Bash', input = { command = 'pwd' } })
    exit_callback(0)
    vim.wait(100)
    _G.exit_waiting = exit_inst.awaiting_permission
  ]])
  eq(_G.child.lua_get('fired'), false)
  eq(_G.child.lua_get('#resolved'), 1)
  eq(_G.child.lua_get('resolved[1].source'), 'closed')
  eq(_G.child.lua_get('resolved[1].behavior'), 'deny')
  eq(_G.child.lua_get('#writes'), 0)
  eq(_G.child.lua_get('exit_waiting'), false)
end

return T
