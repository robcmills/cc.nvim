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

T['valid arg with no active session writes Config.options.permission_mode'] = function()
  _G.child.lua([==[
    require('cc.config').setup({})
    _G._test_notices = {}
    vim.notify = function(msg) table.insert(_G._test_notices, msg) end
    require('cc').set_permission_mode('plan')
  ]==])
  eq(_G.child.lua_get([[require('cc.config').options.permission_mode]]), 'plan')
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
    local process = Process.new({ claude_cmd = 'unused', on_message = function() end })
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
    _G._test_config_mode = require('cc.config').options.permission_mode
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
    local process = Process.new({ claude_cmd = 'unused', on_message = function() end })
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
    _G._test_mode_1 = require('cc.config').options.permission_mode
    cc.cycle_permission_mode()
    _G._test_mode_2 = require('cc.config').options.permission_mode
    cc.cycle_permission_mode()
    _G._test_mode_3 = require('cc.config').options.permission_mode
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
    require('cc.config').options.permission_mode = 'bypassPermissions'
    cc.cycle_permission_mode()
    _G._test_after_bypass = require('cc.config').options.permission_mode
    require('cc.config').options.permission_mode = 'dontAsk'
    cc.cycle_permission_mode()
    _G._test_after_dontask = require('cc.config').options.permission_mode
  ]==])
  eq(_G.child.lua_get('_G._test_after_bypass'), 'default')
  eq(_G.child.lua_get('_G._test_after_dontask'), 'default')
end

T['cycle with active session reads session.permission_mode and sends control_request'] = function()
  _G.child.lua([==[
    require('cc.config').setup({})
    local Process = require('cc.process')

    local sent = {}
    local process = Process.new({ claude_cmd = 'unused', on_message = function() end })
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
    _G._test_config_mode = require('cc.config').options.permission_mode
  ]==])
  local sent = _G.child.lua_get('_G._test_sent')
  eq(#sent, 1)
  eq(sent[1].request.subtype, 'set_permission_mode')
  eq(sent[1].request.mode, 'plan')
  eq(_G.child.lua_get('_G._test_config_mode'), vim.NIL)
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
    require('cc.config').options.permission_mode = nil

    _G._test_notices = {}
    vim.notify = function(msg, level)
      table.insert(_G._test_notices, { msg = msg, level = level })
    end

    -- An active session would normally send a control_request — register one
    -- so we can prove the invalid arg short-circuits before that point.
    local Process = require('cc.process')
    local sent = {}
    local process = Process.new({ claude_cmd = 'unused', on_message = function() end })
    process.alive = true
    process.stdin = {}
    process.write = function(_self, msg) table.insert(sent, msg) end

    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(bufnr)
    require('cc')._register_test_instance(bufnr, { process = process, session = {} })

    require('cc').set_permission_mode('garbage')

    _G._test_sent_len = #sent
    _G._test_config_mode = require('cc.config').options.permission_mode
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
