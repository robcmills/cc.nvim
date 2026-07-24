-- Tests for cc.set_permission_mode / :CcPermissionMode:
--   * No-arg picker.
--   * Valid mode without an active session persists to Config.
--   * Valid mode with an active session sends a set_permission_mode
--     control_request over the existing stdin pipe.
--   * Invalid mode warns and changes nothing.
local helpers = dofile('tests/helpers.lua')
local MiniTest = require('mini.test')
local eq = MiniTest.expect.equality

local T = MiniTest.new_set({
  hooks = helpers.shared_child_hooks(),
})

T['no-arg opens a picker over all six modes'] = function()
  _G.child.lua([==[
    require('cc.config').setup({})
    _G._test_ui_select_args = nil
    _G._test_ui_select_called = false
    vim.ui.select = function(items, opts, _on_choice)
      _G._test_ui_select_called = true
      _G._test_ui_select_args = { items = items, prompt = opts and opts.prompt }
    end
    require('cc').set_permission_mode()
  ]==])
  eq(_G.child.lua_get('_G._test_ui_select_called'), true)
  eq(_G.child.lua_get('_G._test_ui_select_args.items'),
    { 'acceptEdits', 'auto', 'bypassPermissions', 'default', 'dontAsk', 'plan' })
end

T['empty-string arg also opens the picker'] = function()
  _G.child.lua([==[
    require('cc.config').setup({})
    _G._test_ui_select_called = false
    vim.ui.select = function() _G._test_ui_select_called = true end
    require('cc').set_permission_mode('')
  ]==])
  eq(_G.child.lua_get('_G._test_ui_select_called'), true)
end

T['valid arg with no active session writes providers.claude.permission_mode'] = function()
  _G.child.lua([==[
    require('cc.config').setup({})
    _G._test_notices = {}
    vim.notify = function(msg) table.insert(_G._test_notices, msg) end
    require('cc').set_permission_mode('plan')
  ]==])
  eq(_G.child.lua_get(
    [[require('cc.config').options.providers.claude.permission_mode]]), 'plan')
  local notices = _G.child.lua_get('_G._test_notices')
  -- First notice should be the "set to plan" message.
  local found = false
  for _, n in ipairs(notices) do
    if type(n) == 'string' and n:find('set to plan', 1, true) then
      found = true
      break
    end
  end
  eq(found, true)
end

T['valid arg with active session sends set_permission_mode control_request'] = function()
  _G.child.lua([==[
    require('cc.config').setup({})
    local Process = require('cc.process')

    -- Build a real Process and stub the stdin/alive checks so :write() records
    -- the outgoing payload without touching libuv. send_control_set_permission_mode
    -- consults self.alive and self.stdin before generating the request_id.
    local sent = {}
    local process = Process.new({ cmd = 'unused', on_message = function() end })
    process.alive = true
    process.stdin = {}
    process.write = function(_self, msg) table.insert(sent, msg) end

    -- Register a fake instance keyed by the current buffer so
    -- get_current_instance() returns it.
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(bufnr)
    local fake = { process = process, session = { permission_mode = nil } }
    require('cc')._register_test_instance(bufnr, fake)

    -- Capture notifications so the test stays quiet.
    vim.notify = function() end

    require('cc').set_permission_mode('acceptEdits')

    _G._test_sent = sent
    _G._test_config_mode = require('cc.config').options.providers.claude.permission_mode
  ]==])

  local sent = _G.child.lua_get('_G._test_sent')
  eq(#sent, 1)
  eq(sent[1].type, 'control_request')
  eq(sent[1].request.subtype, 'set_permission_mode')
  eq(sent[1].request.mode, 'acceptEdits')
  eq(type(sent[1].request_id), 'string')
  -- Active session => do not mutate Config.
  eq(_G.child.lua_get('_G._test_config_mode'), vim.NIL)
end

T['active-session pending control is tracked by request_id'] = function()
  _G.child.lua([==[
    require('cc.config').setup({})
    local Process = require('cc.process')

    local sent = {}
    local process = Process.new({ cmd = 'unused', on_message = function() end })
    process.alive = true
    process.stdin = {}
    process.write = function(_self, msg) table.insert(sent, msg) end

    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(bufnr)
    require('cc')._register_test_instance(bufnr, { process = process, session = {} })
    vim.notify = function() end

    require('cc').set_permission_mode('plan')
    _G._test_request_id = sent[1].request_id
    _G._test_subtype = process:consume_pending_control(_G._test_request_id)
  ]==])
  eq(_G.child.lua_get('_G._test_subtype'), 'set_permission_mode')
end

T['cycle without session walks default → acceptEdits → plan → default via Config'] = function()
  _G.child.lua([==[
    require('cc.config').setup({})
    vim.notify = function() end
    local cc = require('cc')
    -- Starting from nil → treated as 'default'; first cycle picks acceptEdits.
    cc.cycle_permission_mode()
    _G._test_mode_1 = require('cc.config').options.providers.claude.permission_mode
    cc.cycle_permission_mode()
    _G._test_mode_2 = require('cc.config').options.providers.claude.permission_mode
    cc.cycle_permission_mode()
    _G._test_mode_3 = require('cc.config').options.providers.claude.permission_mode
  ]==])
  eq(_G.child.lua_get('_G._test_mode_1'), 'acceptEdits')
  eq(_G.child.lua_get('_G._test_mode_2'), 'plan')
  eq(_G.child.lua_get('_G._test_mode_3'), 'default')
end

T['cycle skips bypassPermissions and dontAsk (drops back to default)'] = function()
  _G.child.lua([==[
    require('cc.config').setup({})
    vim.notify = function() end
    local cc = require('cc')
    require('cc.config').options.providers.claude.permission_mode = 'bypassPermissions'
    cc.cycle_permission_mode()
    _G._test_after_bypass = require('cc.config').options.providers.claude.permission_mode
    require('cc.config').options.providers.claude.permission_mode = 'dontAsk'
    cc.cycle_permission_mode()
    _G._test_after_dontask = require('cc.config').options.providers.claude.permission_mode
  ]==])
  eq(_G.child.lua_get('_G._test_after_bypass'), 'default')
  eq(_G.child.lua_get('_G._test_after_dontask'), 'default')
end

T['cycle with active session reads session.permission_mode and sends control_request'] = function()
  _G.child.lua([==[
    require('cc.config').setup({})
    local Process = require('cc.process')

    local sent = {}
    local process = Process.new({ cmd = 'unused', on_message = function() end })
    process.alive = true
    process.stdin = {}
    process.write = function(_self, msg) table.insert(sent, msg) end

    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(bufnr)
    -- Session is in 'acceptEdits' → cycle should pick 'plan' and send it.
    require('cc')._register_test_instance(bufnr, {
      process = process,
      session = { permission_mode = 'acceptEdits' },
    })
    vim.notify = function() end

    require('cc').cycle_permission_mode()
    _G._test_sent = sent
    -- Config must NOT be touched when a session handles the change.
    _G._test_config_mode = require('cc.config').options.providers.claude.permission_mode
  ]==])
  local sent = _G.child.lua_get('_G._test_sent')
  eq(#sent, 1)
  eq(sent[1].request.subtype, 'set_permission_mode')
  eq(sent[1].request.mode, 'plan')
  eq(_G.child.lua_get('_G._test_config_mode'), vim.NIL)
end

T['M.open seeds session.permission_mode from opts before init arrives'] = function()
  _G.child.lua([==[
    require('cc.config').setup({})
    -- Stub spawn so M.open doesn't fork a real claude. Anything past the
    -- session.permission_mode assignment we don't care about for this test.
    require('cc.process').spawn = function() end

    require('cc').open({ permission_mode = 'plan' })

    local inst = require('cc')._get_instance()
    _G._test_mode = inst and inst.session and inst.session.permission_mode or nil
  ]==])
  eq(_G.child.lua_get('_G._test_mode'), 'plan')
end

T['M.open seeds session.permission_mode from Config when opts omits it'] = function()
  _G.child.lua([==[
    require('cc.config').setup({})
    require('cc.config').options.providers.claude.permission_mode = 'acceptEdits'
    require('cc.process').spawn = function() end

    require('cc').open()

    local inst = require('cc')._get_instance()
    _G._test_mode = inst and inst.session and inst.session.permission_mode or nil
  ]==])
  eq(_G.child.lua_get('_G._test_mode'), 'acceptEdits')
end

T['M.open leaves session.permission_mode nil when nothing is configured'] = function()
  -- When neither opts nor Config sets a mode, we don't pass --permission-mode
  -- to the CLI, so the CLI's own default takes over and we can't predict it
  -- synchronously. M.open fires a get_settings control_request to discover
  -- the resolved mode; the response handler fills in session.permission_mode.
  -- Before that response lands, the field stays nil.
  _G.child.lua([==[
    require('cc.config').setup({})
    require('cc.config').options.providers.claude.permission_mode = nil
    require('cc.process').spawn = function() end
    -- Stub send_control_get_settings so M.open doesn't try to write to a
    -- non-existent stdin pipe; we just want to assert the seeded state.
    require('cc.process').send_control_get_settings = function() end

    require('cc').open()

    local inst = require('cc')._get_instance()
    _G._test_mode = inst and inst.session and inst.session.permission_mode or nil
  ]==])
  eq(_G.child.lua_get('_G._test_mode'), vim.NIL)
end

T['M.open fires get_settings control_request when no explicit mode is set'] = function()
  -- M.open() only calls send_control_get_settings if the underlying spawn
  -- succeeds (pcall returns ok=true). Process methods live on a local
  -- metatable, so M.spawn = function() end on the require result doesn't
  -- replace the real spawn. Wrap Process.new instead to inject a fake
  -- process whose spawn is a no-op and whose send_control_get_settings
  -- bumps a counter. Restore Process.new after the test so the shared
  -- child neovim's later cases aren't polluted.
  _G.child.lua([==[
    require('cc.config').setup({})
    require('cc.config').options.providers.claude.permission_mode = nil
    _G._test_get_settings_calls = 0
    local Process = require('cc.process')
    _G._test_orig_process_new = Process.new
    Process.new = function(opts)
      local p = _G._test_orig_process_new(opts)
      p.spawn = function(self) self.alive = true; return true end
      p.send_control_get_settings = function()
        _G._test_get_settings_calls = _G._test_get_settings_calls + 1
        return 'fake-request-id'
      end
      p.send_control_set_effort = function(_, _, cb)
        cb(true, { subtype = 'success' })
        return 'fake-effort-request-id'
      end
      return p
    end

    local ok, err = pcall(function() require('cc').open() end)
    Process.new = _G._test_orig_process_new
    if not ok then error(err) end
  ]==])
  eq(_G.child.lua_get('_G._test_get_settings_calls'), 1)
end

T['M.open still gets model and effort settings when an explicit mode is set'] = function()
  _G.child.lua([==[
    require('cc.config').setup({})
    require('cc.config').options.providers.claude.permission_mode = nil
    _G._test_get_settings_calls = 0
    local Process = require('cc.process')
    _G._test_orig_process_new = Process.new
    Process.new = function(opts)
      local p = _G._test_orig_process_new(opts)
      p.spawn = function(self) self.alive = true; return true end
      p.send_control_get_settings = function()
        _G._test_get_settings_calls = _G._test_get_settings_calls + 1
        return 'fake-request-id'
      end
      p.send_control_set_effort = function(_, _, cb)
        cb(true, { subtype = 'success' })
        return 'fake-effort-request-id'
      end
      return p
    end

    local ok, err = pcall(function() require('cc').open({ permission_mode = 'plan' }) end)
    Process.new = _G._test_orig_process_new
    if not ok then error(err) end
  ]==])
  eq(_G.child.lua_get('_G._test_get_settings_calls'), 1)
end

T['get_settings control_response seeds session.permission_mode from effective.permissions.defaultMode'] = function()
  _G.child.lua([==[
    require('cc.config').setup({})
    local Process = require('cc.process')
    local Router = require('cc.router')
    local Output = require('cc.output')
    local Session = require('cc.session')

    local session = Session.new()
    local output = Output.new(session, 'cc-test-output-getset')
    local bufnr = output:ensure_buffer()
    vim.api.nvim_set_current_buf(bufnr)

    local process = Process.new({ cmd = 'unused', on_message = function() end })
    process.alive = true
    process.stdin = {}
    process.write = function() end

    local router = Router.new({ session = session, output = output, process = process })

    -- Simulate sending a get_settings control_request, then receiving its
    -- response from the CLI.
    local request_id = process:send_control_get_settings()
    router:dispatch({
      type = 'control_response',
      response = {
        subtype = 'success',
        request_id = request_id,
        response = {
          effective = { permissions = { defaultMode = 'auto' } },
          sources = {},
        },
      },
    })

    _G._test_mode = session.permission_mode
  ]==])
  eq(_G.child.lua_get('_G._test_mode'), 'auto')
end

T['get_settings response falls back to "default" when permissions.defaultMode is absent'] = function()
  _G.child.lua([==[
    require('cc.config').setup({})
    local Process = require('cc.process')
    local Router = require('cc.router')
    local Output = require('cc.output')
    local Session = require('cc.session')

    local session = Session.new()
    local output = Output.new(session, 'cc-test-output-getset2')
    local bufnr = output:ensure_buffer()
    vim.api.nvim_set_current_buf(bufnr)

    local process = Process.new({ cmd = 'unused', on_message = function() end })
    process.alive = true
    process.stdin = {}
    process.write = function() end

    local router = Router.new({ session = session, output = output, process = process })

    local request_id = process:send_control_get_settings()
    router:dispatch({
      type = 'control_response',
      response = {
        subtype = 'success',
        request_id = request_id,
        response = { effective = {}, sources = {} },
      },
    })

    _G._test_mode = session.permission_mode
  ]==])
  eq(_G.child.lua_get('_G._test_mode'), 'default')
end

T['get_settings response does not overwrite a permission_mode already set by init'] = function()
  _G.child.lua([==[
    require('cc.config').setup({})
    local Process = require('cc.process')
    local Router = require('cc.router')
    local Output = require('cc.output')
    local Session = require('cc.session')

    local session = Session.new()
    session.permission_mode = 'plan'  -- as if init or set_permission_mode raced us
    local output = Output.new(session, 'cc-test-output-getset3')
    local bufnr = output:ensure_buffer()
    vim.api.nvim_set_current_buf(bufnr)

    local process = Process.new({ cmd = 'unused', on_message = function() end })
    process.alive = true
    process.stdin = {}
    process.write = function() end

    local router = Router.new({ session = session, output = output, process = process })

    local request_id = process:send_control_get_settings()
    router:dispatch({
      type = 'control_response',
      response = {
        subtype = 'success',
        request_id = request_id,
        response = { effective = { permissions = { defaultMode = 'auto' } } },
      },
    })

    _G._test_mode = session.permission_mode
  ]==])
  eq(_G.child.lua_get('_G._test_mode'), 'plan')
end

T['system/status with permissionMode updates session.permission_mode'] = function()
  _G.child.lua([==[
    require('cc.config').setup({})
    local Router = require('cc.router')
    local Output = require('cc.output')
    local Session = require('cc.session')

    local session = Session.new()
    session.permission_mode = 'default'
    local output = Output.new(session, 'cc-test-output-pm')
    local bufnr = output:ensure_buffer()
    vim.api.nvim_set_current_buf(bufnr)

    local router = Router.new({ session = session, output = output })
    router:dispatch({
      type = 'system',
      subtype = 'status',
      status = nil,
      permissionMode = 'acceptEdits',
    })

    _G._test_session = session
  ]==])
  eq(_G.child.lua_get('_G._test_session.permission_mode'), 'acceptEdits')
end

T['invalid arg warns and changes nothing'] = function()
  _G.child.lua([==[
    require('cc.config').setup({})
    require('cc.config').options.providers.claude.permission_mode = nil

    _G._test_notices = {}
    vim.notify = function(msg, level)
      table.insert(_G._test_notices, { msg = msg, level = level })
    end

    -- An active session would normally send a control_request — register one
    -- so we can prove the invalid arg short-circuits before that point.
    local Process = require('cc.process')
    local sent = {}
    local process = Process.new({ cmd = 'unused', on_message = function() end })
    process.alive = true
    process.stdin = {}
    process.write = function(_self, msg) table.insert(sent, msg) end

    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(bufnr)
    require('cc')._register_test_instance(bufnr, { process = process, session = {} })

    require('cc').set_permission_mode('garbage')

    _G._test_sent_len = #sent
    _G._test_config_mode = require('cc.config').options.providers.claude.permission_mode
  ]==])
  eq(_G.child.lua_get('_G._test_sent_len'), 0)
  eq(_G.child.lua_get('_G._test_config_mode'), vim.NIL)
  local notices = _G.child.lua_get('_G._test_notices')
  local has_warn = false
  for _, n in ipairs(notices) do
    if type(n.msg) == 'string' and n.msg:find('invalid permission mode', 1, true) then
      has_warn = true
    end
  end
  eq(has_warn, true)
end

return T
