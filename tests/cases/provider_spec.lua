-- Provider layer: registry resolution, option precedence, and the Claude
-- provider contract (send/interrupt/permission-mode delegation).
local helpers = dofile('tests/helpers.lua')
local MiniTest = require('mini.test')
local eq = MiniTest.expect.equality

local T = MiniTest.new_set({
  hooks = helpers.shared_child_hooks(),
})

T['registry'] = MiniTest.new_set()

T['registry']['defaults to claude'] = function()
  _G.child.lua([[require('cc.config').setup({})]])
  eq(_G.child.lua_get([[require('cc.providers').current_name()]]), 'claude')
  eq(_G.child.lua_get([[require('cc.providers').current().name]]), 'claude')
end

T['registry']['resolves codex when configured'] = function()
  _G.child.lua([[require('cc.config').setup({ provider = 'codex' })]])
  eq(_G.child.lua_get([[require('cc.providers').current_name()]]), 'codex')
  eq(_G.child.lua_get([[require('cc.providers').current().name]]), 'codex')
end

T['registry']['rejects unknown provider names'] = function()
  _G.child.lua([[
    local P, err = require('cc.providers').get('bogus')
    _G._test_nil = P == nil
    _G._test_err = err
  ]])
  eq(_G.child.lua_get('_G._test_nil'), true)
  eq(_G.child.lua_get([[_G._test_err:find('unknown provider') ~= nil]]), true)
end

T['registry']['capability flags differ by provider'] = function()
  _G.child.lua([[require('cc.config').setup({})]])
  eq(_G.child.lua_get([[require('cc.providers.claude').capabilities.permission_modes]]), true)
  eq(_G.child.lua_get([[require('cc.providers.codex').capabilities.permission_modes]]), false)
  eq(_G.child.lua_get([[require('cc.providers.claude').capabilities.auto_rename]]), true)
  eq(_G.child.lua_get([[require('cc.providers.codex').capabilities.auto_rename]]), false)
end

T['options'] = MiniTest.new_set()

T['options']['claude falls back to legacy top-level keys'] = function()
  _G.child.lua([[require('cc.config').setup({
    claude_cmd = 'claude-legacy',
    permission_mode = 'acceptEdits',
    model = 'opus',
    extra_args = { '--foo' },
  })]])
  local opts = _G.child.lua_get([[require('cc.providers.claude').options()]])
  eq(opts.cmd, 'claude-legacy')
  eq(opts.permission_mode, 'acceptEdits')
  eq(opts.model, 'opus')
  eq(opts.extra_args, { '--foo' })
end

T['options']['providers.claude overrides legacy keys'] = function()
  _G.child.lua([[require('cc.config').setup({
    claude_cmd = 'claude-legacy',
    providers = { claude = { cmd = 'claude-new', model = 'sonnet' } },
  })]])
  local opts = _G.child.lua_get([[require('cc.providers.claude').options()]])
  eq(opts.cmd, 'claude-new')
  eq(opts.model, 'sonnet')
end

T['options']['codex options resolve from providers.codex'] = function()
  _G.child.lua([[require('cc.config').setup({
    provider = 'codex',
    providers = { codex = {
      cmd = 'codex-dev',
      approval_policy = 'on-request',
      sandbox = 'workspace-write',
    } },
  })]])
  local opts = _G.child.lua_get([[require('cc.providers.codex').options()]])
  eq(opts.cmd, 'codex-dev')
  eq(opts.approval_policy, 'on-request')
  eq(opts.sandbox, 'workspace-write')
end

--- Attach a claude provider with a recording stub in place of the process.
local function setup_claude_provider(child)
  child.lua([==[
    require('cc.config').setup({})
    local Session = require('cc.session')
    local Output = require('cc.output')
    local session = Session.new()
    local output = Output.new(session, 'cc-test-output')
    output:ensure_buffer()

    local inst = { session = session, output = output, last_session_id = 'sess-1' }
    local provider = require('cc.providers.claude').attach({
      instance = inst,
      session = session,
      output = output,
    })
    local sent = {}
    provider.process.alive = true
    provider.process.stdin = {}
    provider.process.write = function(self, msg) table.insert(sent, msg) end
    inst.provider = provider
    inst.process = provider.process

    _G._test_provider = provider
    _G._test_sent = sent
  ]==])
end

T['claude'] = MiniTest.new_set()

T['claude']['send writes a stream-json user message'] = function()
  setup_claude_provider(_G.child)
  _G.child.lua([[_G._test_provider:send('hello world')]])
  local sent = _G.child.lua_get('_G._test_sent')
  eq(#sent, 1)
  eq(sent[1].type, 'user')
  eq(sent[1].session_id, 'sess-1')
  eq(sent[1].message.role, 'user')
  eq(sent[1].message.content, 'hello world')
end

T['claude']['interrupt sends a control_request'] = function()
  setup_claude_provider(_G.child)
  _G.child.lua([[_G._test_request_id = _G._test_provider:interrupt()]])
  eq(_G.child.lua_get('type(_G._test_request_id)'), 'string')
  local sent = _G.child.lua_get('_G._test_sent')
  eq(sent[1].type, 'control_request')
  eq(sent[1].request.subtype, 'interrupt')
end

T['claude']['set_permission_mode sends a control_request'] = function()
  setup_claude_provider(_G.child)
  _G.child.lua([[_G._test_provider:set_permission_mode('plan')]])
  local sent = _G.child.lua_get('_G._test_sent')
  eq(sent[1].request.subtype, 'set_permission_mode')
  eq(sent[1].request.mode, 'plan')
end

T['claude']['is_alive reflects the process'] = function()
  setup_claude_provider(_G.child)
  eq(_G.child.lua_get('_G._test_provider:is_alive()'), true)
  _G.child.lua([[_G._test_provider.process.alive = false]])
  eq(_G.child.lua_get('_G._test_provider:is_alive()'), false)
end

T['claude']['list_history returns entries synchronously'] = function()
  _G.child.lua([==[
    require('cc.config').setup({})
    local got
    require('cc.providers.claude').list_history({ all = false, cwd = '/nonexistent-cwd' },
      function(entries) got = entries end)
    _G._test_got_type = type(got)
  ]==])
  eq(_G.child.lua_get('_G._test_got_type'), 'table')
end

return T
