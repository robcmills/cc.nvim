-- Tests for showing the CLI-resolved effort level in the statusline.
-- The effort *setting* defaults to 'auto' (no env var sent → the CLI/model
-- picks the default, e.g. 'high' on Opus). The CLI reports that resolved level
-- in the get_settings control_response's `applied.effort`; the router stashes
-- it on session.resolved_effort and the statusline shows it in place of 'auto'.
local helpers = dofile('tests/helpers.lua')
local MiniTest = require('mini.test')
local eq = MiniTest.expect.equality

local T = MiniTest.new_set({
  hooks = helpers.shared_child_hooks(),
})

-- ---------------------------------------------------------------------------
-- Provider configuration and spawn environment
-- ---------------------------------------------------------------------------
T['provider_config'] = MiniTest.new_set()

T['provider_config']['Claude effort is provider-scoped without an environment pin'] = function()
  local out = _G.child.lua_get([[(function()
    require('cc.config').setup({
      providers = { claude = { effort = 'high' } },
    })
    local Effort = require('cc.effort')
    Effort.set('low')
    local provider = require('cc.providers.claude')
    local effective = Effort.get_effective(nil)
    vim.env.CLAUDE_CODE_EFFORT_LEVEL = 'external-pin'
    local env = Effort.runtime_env()
    local value
    for _, entry in ipairs(env) do
      value = entry:match('^CLAUDE_CODE_EFFORT_LEVEL=(.*)$') or value
    end
    Effort._reset()
    return { effective = effective, env = value }
  end)()]])
  eq(out.effective, 'high')
  eq(out.env, nil)
end

T['provider_config']['runtime environment preserves unrelated variables'] = function()
  local present = _G.child.lua_get([[(function()
    local Effort = require('cc.effort')
    vim.env.CC_NVIM_EFFORT_TEST = 'present'
    local env = Effort.runtime_env()
    for _, entry in ipairs(env) do
      if entry == 'CC_NVIM_EFFORT_TEST=present' then return true end
    end
    return false
  end)()]])
  eq(present, true)
end

-- ---------------------------------------------------------------------------
-- Router: capture applied.effort from get_settings
-- ---------------------------------------------------------------------------
T['router'] = MiniTest.new_set()

T['router']['get_settings response stores applied.effort on session.resolved_effort'] = function()
  _G.child.lua([==[
    require('cc.config').setup({})
    local Process = require('cc.process')
    local Router = require('cc.router')
    local Output = require('cc.output')
    local Session = require('cc.session')

    local session = Session.new()
    local output = Output.new(session, 'cc-test-output-effort1')
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
        response = {
          applied = { effort = 'high' },
          effective = { permissions = { defaultMode = 'auto' } },
          sources = {},
        },
      },
    })

    _G._test_effort = session.resolved_effort
    _G._test_mode = session.permission_mode
  ]==])
  eq(_G.child.lua_get('_G._test_effort'), 'high')
  -- permission_mode seeding still works alongside the effort capture.
  eq(_G.child.lua_get('_G._test_mode'), 'auto')
end

T['router']['captures applied.effort even when permission_mode was already set'] = function()
  -- An init message can race the get_settings response and set permission_mode
  -- first. The effort capture must not be skipped by that early-out.
  _G.child.lua([==[
    require('cc.config').setup({})
    local Process = require('cc.process')
    local Router = require('cc.router')
    local Output = require('cc.output')
    local Session = require('cc.session')

    local session = Session.new()
    session.permission_mode = 'plan' -- pretend init already set it
    local output = Output.new(session, 'cc-test-output-effort2')
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
        response = {
          applied = { effort = 'xhigh' },
          effective = { permissions = { defaultMode = 'auto' } },
          sources = {},
        },
      },
    })

    _G._test_effort = session.resolved_effort
    _G._test_mode = session.permission_mode
  ]==])
  eq(_G.child.lua_get('_G._test_effort'), 'xhigh')
  -- permission_mode untouched (init's value wins).
  eq(_G.child.lua_get('_G._test_mode'), 'plan')
end

T['router']['get_settings stores applied model and clears stale context window'] = function()
  _G.child.lua([==[
    require('cc.config').setup({})
    local Process = require('cc.process')
    local Router = require('cc.router')
    local Output = require('cc.output')
    local Session = require('cc.session')

    local session = Session.new()
    session.model = 'old-model'
    session.context_window = 200000
    local output = Output.new(session, 'cc-test-output-model-settings')
    output:ensure_buffer()
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
        response = {
          applied = { model = 'new-model', effort = 'high' },
          effective = {},
        },
      },
    })
    _G._test_model = session.model
    _G._test_context = session.context_window
  ]==])
  eq(_G.child.lua_get('_G._test_model'), 'new-model')
  eq(_G.child.lua_get('_G._test_context'), vim.NIL)
end

-- ---------------------------------------------------------------------------
-- Statusline: display the resolved level when the setting is 'auto'
-- ---------------------------------------------------------------------------
T['statusline'] = MiniTest.new_set()

T['statusline']['auto setting shows resolved level once known'] = function()
  _G.child.lua([[
    require('cc.config').setup({ providers = { claude = { effort = 'auto' } } })
    local Session = require('cc.session')
    local session = Session.new()
    session.resolved_effort = 'high'
    _G._state = require('cc.statusline').build_state({ session = session })
  ]])
  eq(_G.child.lua_get('_G._state.effort'), 'high')
  eq(_G.child.lua_get('_G._state.effort_setting'), 'auto')
  eq(_G.child.lua_get('_G._state.effort_resolved'), true)
end

T['statusline']['auto setting falls back to "auto" before the response lands'] = function()
  _G.child.lua([[
    require('cc.config').setup({ providers = { claude = { effort = 'auto' } } })
    local Session = require('cc.session')
    local session = Session.new()
    -- resolved_effort still nil: get_settings response not yet received.
    _G._state = require('cc.statusline').build_state({ session = session })
  ]])
  eq(_G.child.lua_get('_G._state.effort'), 'auto')
  eq(_G.child.lua_get('_G._state.effort_resolved'), false)
end

T['statusline']['explicit setting wins over resolved_effort'] = function()
  _G.child.lua([[
    require('cc.config').setup({ providers = { claude = { effort = 'low' } } })
    local Session = require('cc.session')
    local session = Session.new()
    session.resolved_effort = 'high' -- should be ignored: user pinned 'low'
    _G._state = require('cc.statusline').build_state({ session = session })
  ]])
  eq(_G.child.lua_get('_G._state.effort'), 'low')
  eq(_G.child.lua_get('_G._state.effort_resolved'), false)
end

T['statusline']['auto-resolved render uses the auto glyph with the resolved label'] = function()
  _G.child.lua([[
    require('cc.config').setup({ tool_icons = { use_nerdfont = false } })
    local Effort = require('cc.effort')
    local out = require('cc.statusline')._default_format({
      effort = 'high',
      effort_setting = 'auto',
      effort_resolved = true,
    })
    -- auto glyph (◎) precedes the resolved label ('high'); not the 'high' glyph.
    _G._has_auto_glyph = out:find(Effort.symbol('auto'), 1, true) ~= nil
    _G._has_high_label = out:find('high', 1, true) ~= nil
    _G._has_high_glyph = out:find(Effort._UNICODE.high, 1, true) ~= nil
  ]])
  eq(_G.child.lua_get('_G._has_auto_glyph'), true)
  eq(_G.child.lua_get('_G._has_high_label'), true)
  eq(_G.child.lua_get('_G._has_high_glyph'), false)
end

return T
