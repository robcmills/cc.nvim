-- Runtime /model and /effort plus :CcNew startup arguments.
local helpers = dofile('tests/helpers.lua')
local MiniTest = require('mini.test')
local eq = MiniTest.expect.equality

local hooks = helpers.shared_child_hooks()
local base_pre_case = hooks.pre_case
hooks.pre_case = function()
  base_pre_case()
  -- Model completion candidates come from the models cache fixture.
  _G.child.lua(('require("cc.config").setup({ models_path = %q })')
    :format(helpers.models_fixture))
end

local T = MiniTest.new_set({ hooks = hooks })

T['CcNew'] = MiniTest.new_set()

T['CcNew']['forwards model and effort arguments'] = function()
  _G.child.lua([==[
    local cc = require('cc')
    local original = cc.open
    cc.open = function(opts) _G._opened_with = opts end
    vim.cmd('CcNew test-model xhigh')
    cc.open = original
  ]==])
  eq(_G.child.lua_get('_G._opened_with'), {
    model = 'test-model',
    effort = 'xhigh',
  })
end

T['CcNew']['zero arguments preserves default startup'] = function()
  _G.child.lua([==[
    local cc = require('cc')
    local original = cc.open
    cc.open = function(opts) _G._opened_with = opts end
    vim.cmd('CcNew')
    cc.open = original
  ]==])
  eq(_G.child.lua_get('_G._opened_with'), {})
end

T['CcNew']['invalid or excess arguments do not open'] = function()
  _G.child.lua([==[
    local cc = require('cc')
    local calls = 0
    local original_open = cc.open
    local original_notify = vim.notify
    cc.open = function() calls = calls + 1 end
    local notices = {}
    vim.notify = function(msg) table.insert(notices, msg) end
    vim.cmd('CcNew test-model impossible')
    vim.cmd('CcNew one two three')
    cc.open = original_open
    vim.notify = original_notify
    _G._open_calls = calls
    _G._notices = notices
  ]==])
  eq(_G.child.lua_get('_G._open_calls'), 0)
  eq(#_G.child.lua_get('_G._notices'), 2)
end

T['CcNew']['completes effort in the second position'] = function()
  local got = _G.child.lua_get(
    [[vim.fn.getcompletion('CcNew test-model h', 'cmdline')]])
  eq(got, { 'high' })
end

T['CcNew']['fuzzy model completion returns the canonical model'] = function()
  local got = _G.child.lua_get(
    [[vim.fn.getcompletion('CcNew sol', 'cmdline')]])
  eq(got[1], 'gpt-5.6-sol')
end

T['CcNew']['Opus completion returns the cached 1M alias'] = function()
  local all = _G.child.lua_get(
    [[vim.fn.getcompletion('CcNew ', 'cmdline')]])
  local partial = _G.child.lua_get(
    [[vim.fn.getcompletion('CcNew opus', 'cmdline')]])
  eq(vim.tbl_contains(all, 'opus[1m]'), true)
  eq(vim.tbl_contains(all, 'opus'), false)
  eq(partial[1], 'opus[1m]')
end

T['CcNew']['Opus shorthand is forwarded as the cached alias'] = function()
  local got = _G.child.lua_get([[(function()
    local cc = require('cc')
    local original = cc.open
    local opened = {}
    cc.open = function(opts)
      local model, provider = require('cc.model').resolve(opts.model)
      table.insert(opened, { model = model, provider = provider })
    end
    vim.cmd('CcNew opus')
    cc.open = original
    return opened
  end)()]])
  eq(got, {
    { model = 'opus[1m]', provider = 'claude' },
  })
end

T['CcNew']['inferred provider overrides configured provider for the new instance'] = function()
  _G.child.lua([==[
    require('cc.config').setup({ provider = 'claude' })
    local Providers = require('cc.providers')
    local original_get = Providers.get
    Providers.get = function(name)
      _G._attached_provider_name = name
      return {
        name = name,
        attach = function(ctx)
          return {
            name = name,
            capabilities = {},
            opts = { model = ctx.model, effort = ctx.effort },
            spawn = function() end,
            is_alive = function() return true end,
            close = function() end,
          }
        end,
      }
    end
    local ok, err = pcall(require('cc').open, {
      model = 'gpt-5.6-sol',
      effort = 'high',
    })
    Providers.get = original_get
    if not ok then error(err) end
    local inst = require('cc')._get_instance()
    _G._instance_provider_name = inst and inst.provider and inst.provider.name
    _G._instance_model = inst and inst.provider and inst.provider.opts.model
  ]==])
  eq(_G.child.lua_get('_G._attached_provider_name'), 'codex')
  eq(_G.child.lua_get('_G._instance_provider_name'), 'codex')
  eq(_G.child.lua_get('_G._instance_model'), 'gpt-5.6-sol')
end

T['commands'] = MiniTest.new_set()

T['commands']['CcModel and CcEffort call their public APIs'] = function()
  _G.child.lua([==[
    local cc = require('cc')
    cc.model = function(value) _G._command_model = value end
    cc.effort = function(value) _G._command_effort = value end
    vim.cmd('CcModel command-model')
    vim.cmd('CcEffort max')
  ]==])
  eq(_G.child.lua_get('_G._command_model'), 'command-model')
  eq(_G.child.lua_get('_G._command_effort'), 'max')
end

T['commands']['CcModel and CcEffort support no-argument reporting'] = function()
  _G.child.lua([==[
    local cc = require('cc')
    cc.model = function(value) _G._command_model = value end
    cc.effort = function(value) _G._command_effort = value end
    vim.cmd('CcModel')
    vim.cmd('CcEffort')
  ]==])
  eq(_G.child.lua_get('_G._command_model'), '')
  eq(_G.child.lua_get('_G._command_effort'), '')
end

T['slash'] = MiniTest.new_set()

T['slash']['model and effort are handled locally through provider setters'] = function()
  _G.child.lua([==[
    local cc = require('cc')
    local session = require('cc.session').new()
    local calls = {}
    local provider = {
      name = 'test',
      opts = { model = 'old-model', effort = 'medium' },
      set_model = function(self, value, cb)
        self.opts.model = value
        table.insert(calls, { kind = 'model', value = value })
        cb(true)
      end,
      set_effort = function(self, value, cb)
        self.opts.effort = value
        table.insert(calls, { kind = 'effort', value = value })
        cb(true)
      end,
    }
    local inst = {
      session = session,
      provider = provider,
      process = { is_alive = function() return true end },
    }
    _G._handled_model = cc._try_handle_client_command(inst, '/model new-model')
    _G._handled_effort = cc._try_handle_client_command(inst, '/effort high')
    _G._calls = calls
  ]==])
  eq(_G.child.lua_get('_G._handled_model'), true)
  eq(_G.child.lua_get('_G._handled_effort'), true)
  eq(_G.child.lua_get('_G._calls'), {
    { kind = 'model', value = 'new-model' },
    { kind = 'effort', value = 'high' },
  })
end

T['slash']['model shorthand is canonicalized before reaching the provider'] = function()
  _G.child.lua([==[
    local cc = require('cc')
    local selected
    local inst = {
      session = require('cc.session').new(),
      provider = {
        name = 'codex',
        opts = { model = 'gpt-5.6-sol' },
        set_model = function(_, model, cb) selected = model; cb(true) end,
      },
      process = { is_alive = function() return true end },
    }
    cc._try_handle_client_command(inst, '/model sol')
    _G._selected = selected
  ]==])
  eq(_G.child.lua_get('_G._selected'), 'gpt-5.6-sol')
end

T['slash']['cross-provider model change is rejected with CcNew guidance'] = function()
  _G.child.lua([==[
    local cc = require('cc')
    local set_calls = 0
    local notice
    local original_notify = vim.notify
    vim.notify = function(msg) notice = msg end
    local inst = {
      session = require('cc.session').new(),
      provider = {
        name = 'claude',
        opts = { model = 'sonnet' },
        set_model = function() set_calls = set_calls + 1 end,
      },
      process = { is_alive = function() return true end },
    }
    cc._try_handle_client_command(inst, '/model sol')
    vim.notify = original_notify
    _G._set_calls = set_calls
    _G._notice = notice
  ]==])
  eq(_G.child.lua_get('_G._set_calls'), 0)
  eq(_G.child.lua_get([[_G._notice:find(':CcNew gpt%-5%.6%-sol') ~= nil]]), true)
end

T['codex'] = MiniTest.new_set()

T['codex']['runtime setters change subsequent turn parameters'] = function()
  _G.child.lua([==[
    require('cc.config').setup({ provider = 'codex' })
    local Session = require('cc.session')
    local session = Session.new()
    session.context_window = 200000
    local provider = require('cc.providers.codex').attach({
      session = session,
      model = 'initial-model',
      effort = 'medium',
    })
    provider.alive = true
    provider.thread_id = 'thread-1'
    local sent
    provider.request = function(_, method, params)
      if method == 'turn/start' then sent = params end
    end
    provider:set_model('next-model')
    provider:set_effort('max')
    provider:send('hello')
    _G._sent = sent
    _G._session_model = session.model
    _G._context_window = session.context_window

    provider:set_effort('auto')
    provider:send('again')
    _G._auto_sent = sent
  ]==])
  local sent = _G.child.lua_get('_G._sent')
  eq(sent.model, 'next-model')
  eq(sent.effort, 'xhigh')
  eq(_G.child.lua_get('_G._session_model'), 'next-model')
  eq(_G.child.lua_get('_G._context_window'), vim.NIL)
  eq(_G.child.lua_get('_G._auto_sent.effort'), vim.NIL)
end

return T
