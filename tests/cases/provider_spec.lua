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

T['registry']['infers provider from recognized model families'] = function()
  local got = _G.child.lua_get([[(function()
    local infer = require('cc.providers').infer_from_model
    return {
      gpt = infer('gpt-5.6-sol'),
      o_model = infer('o4-mini'),
      openai = infer('openai/custom-model'),
      claude = infer('claude-opus-4-7'),
      alias = infer('sonnet'),
      alias_1m = infer('opus[1m]'),
      unknown = infer('company-model'),
    }
  end)()]])
  eq(got.gpt, 'codex')
  eq(got.o_model, 'codex')
  eq(got.openai, 'codex')
  eq(got.claude, 'claude')
  eq(got.alias, 'claude')
  eq(got.alias_1m, 'claude')
  eq(got.unknown, nil)
end

T['registry']['capability flags differ by provider'] = function()
  _G.child.lua([[require('cc.config').setup({})]])
  eq(_G.child.lua_get([[require('cc.providers.claude').capabilities.permission_modes]]), true)
  eq(_G.child.lua_get([[require('cc.providers.codex').capabilities.permission_modes]]), false)
  eq(_G.child.lua_get([[require('cc.providers.claude').capabilities.auto_rename]]), true)
  eq(_G.child.lua_get([[require('cc.providers.codex').capabilities.auto_rename]]), true)
end

T['options'] = MiniTest.new_set()

T['options']['claude options resolve only from providers.claude'] = function()
  _G.child.lua([[require('cc.config').setup({
    providers = { claude = {
      cmd = 'claude-new',
      permission_mode = 'acceptEdits',
      model = 'opus',
      effort = 'high',
      auto_rename_model = 'haiku-fast',
      extra_args = { '--foo' },
    } },
  })]])
  local opts = _G.child.lua_get([[require('cc.providers.claude').options()]])
  eq(opts.cmd, 'claude-new')
  eq(opts.permission_mode, 'acceptEdits')
  eq(opts.model, 'opus')
  eq(opts.effort, 'high')
  eq(opts.auto_rename_model, 'haiku-fast')
  eq(opts.extra_args, { '--foo' })
end

T['options']['codex auto-rename defaults to luna'] = function()
  _G.child.lua([[require('cc.config').setup({ provider = 'codex' })]])
  local opts = _G.child.lua_get([[require('cc.providers.codex').options()]])
  eq(opts.auto_rename_model, 'gpt-5.6-luna')
  eq(opts.effort, 'medium')
  eq(opts.model, 'gpt-5.6-sol')
end

T['options']['codex configured effort uses the shared effort mapping'] = function()
  _G.child.lua([==[
    require('cc.config').setup({
      provider = 'codex',
      providers = { codex = { effort = 'max' } },
    })
    local provider = require('cc.providers.codex').attach({ headless = true })
    _G._test_max_effort = provider:_effort()
    provider.opts.effort = 'auto'
    _G._test_auto_effort = provider:_effort()
  ]==])
  eq(_G.child.lua_get('_G._test_max_effort'), 'xhigh')
  eq(_G.child.lua_get('_G._test_auto_effort'), vim.NIL)
end

T['options']['per-session overrides replace provider defaults without mutating config'] = function()
  local got = _G.child.lua_get([[(function()
    require('cc.config').setup({
      providers = { claude = { model = 'configured-model', effort = 'medium' } },
    })
    local Session = require('cc.session')
    local Output = require('cc.output')
    local session = Session.new()
    local output = Output.new(session, 'cc-test-provider-overrides')
    output:ensure_buffer()
    local provider = require('cc.providers.claude').attach({
      session = session,
      output = output,
      model = 'session-model',
      effort = 'xhigh',
    })
    local configured = require('cc.providers.claude').options()
    return {
      model = provider.opts.model,
      effort = provider.opts.effort,
      configured_model = configured.model,
      configured_effort = configured.effort,
    }
  end)()]])
  eq(got.model, 'session-model')
  eq(got.effort, 'xhigh')
  eq(got.configured_model, 'configured-model')
  eq(got.configured_effort, 'medium')
end

T['options']['legacy top-level Claude keys are ignored'] = function()
  _G.child.lua([[require('cc.config').setup({
    claude_cmd = 'claude-legacy',
    permission_mode = 'bypassPermissions',
    model = 'legacy-model',
    extra_args = { '--legacy' },
  })]])
  local opts = _G.child.lua_get([[require('cc.providers.claude').options()]])
  local config = _G.child.lua_get([[(function()
    local o = require('cc.config').options
    return {
      claude_cmd = o.claude_cmd,
      permission_mode = o.permission_mode,
      model = o.model,
      extra_args = o.extra_args,
    }
  end)()]])
  eq(opts.cmd, 'claude')
  eq(opts.permission_mode, nil)
  eq(opts.effort, 'medium')
  eq(opts.extra_args, {})
  eq(opts.model, 'fable')
  eq(config, {})
end

T['options']['codex options resolve from providers.codex'] = function()
  _G.child.lua([[require('cc.config').setup({
    provider = 'codex',
    providers = { codex = {
      cmd = 'codex-dev',
      auto_rename_model = 'codex-fast',
      approval_policy = 'on-request',
      sandbox = 'workspace-write',
    } },
  })]])
  local opts = _G.child.lua_get([[require('cc.providers.codex').options()]])
  eq(opts.cmd, 'codex-dev')
  eq(opts.auto_rename_model, 'codex-fast')
  eq(opts.approval_policy, 'on-request')
  eq(opts.sandbox, 'workspace-write')
end

T['options']['auto_rename is configurable during setup'] = function()
  _G.child.lua([[require('cc.config').setup({
    auto_rename = {
      enabled = false,
      prompt = 'title: ${prompt}',
      timeout_ms = 1234,
      placeholder = false,
    },
  })]])
  local opts = _G.child.lua_get([[require('cc.config').options.auto_rename]])
  eq(opts.enabled, false)
  eq(opts.prompt, 'title: ${prompt}')
  eq(opts.timeout_ms, 1234)
  eq(opts.placeholder, false)
end

T['options']['codex auto-rename command is ephemeral and configurable'] = function()
  _G.child.lua([==[
    require('cc.config').setup({
      provider = 'codex',
      providers = { codex = {
        cmd = 'codex-dev',
        model = 'main-model',
        auto_rename_model = 'title-model',
      } },
    })
    local provider = require('cc.providers.codex').attach({ headless = true })
    local spec = provider:auto_rename_spec('name this prompt',
      require('cc.config').options.auto_rename)
    _G._test_auto_cmd = spec.cmd
    _G._test_auto_args = spec.args
    _G._test_auto_output_path = spec.output_path
    spec.cleanup()
  ]==])
  eq(_G.child.lua_get('_G._test_auto_cmd'), 'codex-dev')
  local args = _G.child.lua_get('_G._test_auto_args')
  eq(args[1], 'exec')
  eq(vim.tbl_contains(args, '--ephemeral'), true)
  eq(vim.tbl_contains(args, '--ignore-rules'), true)
  eq(vim.tbl_contains(args, '--output-last-message'), true)
  eq(args[#args - 1], 'title-model')
  eq(args[#args], 'name this prompt')
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

T['claude']['set_model commits after acknowledgement and refreshes settings'] = function()
  setup_claude_provider(_G.child)
  _G.child.lua([==[
    _G._test_provider.session.model = 'old-model'
    _G._test_provider.session.context_window = 200000
    _G._test_provider:set_model('sonnet', function(ok) _G._test_ok = ok end)
    local rid = _G._test_sent[1].request_id
    _G._test_provider.router:dispatch({
      type = 'control_response',
      response = { subtype = 'success', request_id = rid },
    })
  ]==])
  local sent = _G.child.lua_get('_G._test_sent')
  eq(sent[1].request.subtype, 'set_model')
  eq(sent[1].request.model, 'sonnet')
  eq(sent[2].request.subtype, 'get_settings')
  eq(_G.child.lua_get('_G._test_provider.opts.model'), 'sonnet')
  eq(_G.child.lua_get('_G._test_provider.session.model'), 'sonnet')
  eq(_G.child.lua_get('_G._test_provider.session.context_window'), vim.NIL)
  eq(_G.child.lua_get('_G._test_ok'), true)
end

T['claude']['set_effort sends flag settings and auto clears the override'] = function()
  setup_claude_provider(_G.child)
  _G.child.lua([==[
    _G._test_provider:set_effort('high')
    _G._test_provider:set_effort('auto')
  ]==])
  local sent = _G.child.lua_get('_G._test_sent')
  eq(sent[1].request.subtype, 'apply_flag_settings')
  eq(sent[1].request.settings.effort, 'high')
  eq(sent[2].request.subtype, 'apply_flag_settings')
  eq(sent[2].request.settings.effort, vim.NIL)
end

T['claude']['is_alive reflects the process'] = function()
  setup_claude_provider(_G.child)
  eq(_G.child.lua_get('_G._test_provider:is_alive()'), true)
  _G.child.lua([[_G._test_provider.process.alive = false]])
  eq(_G.child.lua_get('_G._test_provider:is_alive()'), false)
end

T['claude']['auto-rename uses provider command and configured model'] = function()
  setup_claude_provider(_G.child)
  _G.child.lua([==[
    _G._test_provider.opts.cmd = 'claude-dev'
    _G._test_provider.opts.auto_rename_model = 'fast-model'
    local spec = _G._test_provider:auto_rename_spec('name this', {})
    _G._test_auto_cmd = spec.cmd
    _G._test_auto_args = spec.args
    spec.cleanup()
  ]==])
  eq(_G.child.lua_get('_G._test_auto_cmd'), 'claude-dev')
  local args = _G.child.lua_get('_G._test_auto_args')
  eq(args[1], '-p')
  eq(args[2], 'name this')
  eq(args[4], 'fast-model')
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
