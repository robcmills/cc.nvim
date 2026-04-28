-- Tests for cc.statusline: build_state, render, default format, user format
-- error handling, attach/refresh wiring.
local helpers = dofile('tests/helpers.lua')
local MiniTest = require('mini.test')
local eq = MiniTest.expect.equality

local T = MiniTest.new_set({
  hooks = {
    pre_case = function() _G.child = helpers.new_child() end,
    post_case = function() if _G.child then _G.child.stop() end end,
  },
})

-- ---------------------------------------------------------------------------
-- Config defaults
-- ---------------------------------------------------------------------------
T['config'] = MiniTest.new_set()

T['config']['enabled by default'] = function()
  _G.child.lua([[
    require('cc.config').setup({})
    _G._enabled = require('cc.config').options.statusline.enabled
    _G._format = require('cc.config').options.statusline.format
  ]])
  eq(_G.child.lua_get('_G._enabled'), true)
  eq(_G.child.lua_get('_G._format == nil'), true)
end

T['config']['user override disables'] = function()
  _G.child.lua([[
    require('cc.config').setup({ statusline = { enabled = false } })
    _G._enabled = require('cc.config').options.statusline.enabled
  ]])
  eq(_G.child.lua_get('_G._enabled'), false)
end

-- ---------------------------------------------------------------------------
-- build_state
-- ---------------------------------------------------------------------------
T['build_state'] = MiniTest.new_set()

T['build_state']['reads session + instance fields'] = function()
  _G.child.lua([[
    local Session = require('cc.session')
    local session = Session.new()
    session.model = 'claude-opus-4-7'
    session.permission_mode = 'plan'
    session.turn_active = true
    session.input_tokens = 1000
    session.output_tokens = 250
    session.cost_usd = 0.42
    local inst = {
      session = session,
      last_session_id = 'abc123',
      session_name = 'refactor',
      remote_control_active = true,
    }
    _G._state = require('cc.statusline').build_state(inst)
  ]])
  eq(_G.child.lua_get('_G._state.is_thinking'), true)
  eq(_G.child.lua_get('_G._state.total_tokens'), 1250)
  eq(_G.child.lua_get('_G._state.input_tokens'), 1000)
  eq(_G.child.lua_get('_G._state.output_tokens'), 250)
  eq(_G.child.lua_get('_G._state.cost_usd'), 0.42)
  eq(_G.child.lua_get('_G._state.mode'), 'plan')
  eq(_G.child.lua_get('_G._state.model'), 'claude-opus-4-7')
  eq(_G.child.lua_get('_G._state.session_id'), 'abc123')
  eq(_G.child.lua_get('_G._state.session_name'), 'refactor')
  eq(_G.child.lua_get('_G._state.remote_control'), true)
end

T['build_state']['empty session defaults'] = function()
  _G.child.lua([[
    local Session = require('cc.session')
    _G._state = require('cc.statusline').build_state({ session = Session.new() })
  ]])
  eq(_G.child.lua_get('_G._state.is_thinking'), false)
  eq(_G.child.lua_get('_G._state.total_tokens'), 0)
  eq(_G.child.lua_get('_G._state.remote_control'), false)
  eq(_G.child.lua_get('_G._state.mode == nil'), true)
end

T['build_state']['is_streaming alone does not set is_thinking'] = function()
  _G.child.lua([[
    local Session = require('cc.session')
    local s = Session.new()
    s.is_streaming = true
    s.turn_active = false
    _G._state = require('cc.statusline').build_state({ session = s })
  ]])
  eq(_G.child.lua_get('_G._state.is_thinking'), false)
end

T['build_state']['turn_elapsed_ms is nil when turn inactive'] = function()
  _G.child.lua([[
    local Session = require('cc.session')
    local s = Session.new()
    _G._state = require('cc.statusline').build_state({ session = s })
  ]])
  eq(_G.child.lua_get('_G._state.turn_elapsed_ms == nil'), true)
end

T['build_state']['turn_elapsed_ms grows while turn is active'] = function()
  _G.child.lua([[
    local Session = require('cc.session')
    local s = Session.new()
    s:add_user_turn('hi')
    vim.wait(20, function() return false end)
    _G._state = require('cc.statusline').build_state({ session = s })
  ]])
  local elapsed = _G.child.lua_get('_G._state.turn_elapsed_ms')
  eq(type(elapsed) == 'number' and elapsed >= 15, true)
end

T['build_state']['includes spinner_frame from statusline_spinner module'] = function()
  _G.child.lua([[
    require('cc.config').setup({
      statusline = { spinner = { frames = { 'A', 'B' }, interval_ms = 100 } },
    })
    local Session = require('cc.session')
    local s = Session.new()
    s.turn_active = true
    local inst = { session = s }
    require('cc.statusline_spinner').start(inst)
    _G._state = require('cc.statusline').build_state(inst)
    require('cc.statusline_spinner').stop(inst)
  ]])
  -- Before the timer ticks, frame is 1 => 'A'.
  eq(_G.child.lua_get('_G._state.spinner_frame'), 'A')
end

-- ---------------------------------------------------------------------------
-- Default format
-- ---------------------------------------------------------------------------
T['default_format'] = MiniTest.new_set()

T['default_format']['empty state yields rule char at right edge'] = function()
  _G.child.lua([[
    _G._out = require('cc.statusline')._default_format({
      is_thinking = false,
      total_tokens = 0,
    })
  ]])
  local out = _G.child.lua_get('_G._out')
  -- %= pushes the ─ to the right; rest fills from fillchar
  eq(out:find('%=', 1, true) ~= nil, true)
  eq(out:find('─', 1, true) ~= nil, true)
end

T['default_format']['shows provided spinner_frame while turn is active'] = function()
  _G.child.lua([[
    _G._out = require('cc.statusline')._default_format({
      is_thinking = true,
      spinner_frame = 'SPIN',
      total_tokens = 0,
    })
  ]])
  eq(_G.child.lua_get("_G._out:find('SPIN', 1, true) ~= nil"), true)
end

T['default_format']['appends elapsed time next to spinner'] = function()
  _G.child.lua([[
    _G._out = require('cc.statusline')._default_format({
      is_thinking = true,
      spinner_frame = 'SPIN',
      turn_elapsed_ms = 5000,
      total_tokens = 0,
    })
  ]])
  eq(_G.child.lua_get("_G._out:find('SPIN 5s', 1, true) ~= nil"), true)
end

T['default_format']['omits elapsed when turn_elapsed_ms missing'] = function()
  _G.child.lua([[
    _G._out = require('cc.statusline')._default_format({
      is_thinking = true,
      spinner_frame = 'SPIN',
      total_tokens = 0,
    })
  ]])
  -- No "0s" or stray digits right after spinner glyph
  eq(_G.child.lua_get("_G._out:find('SPIN %d', 1, false) == nil"), true)
end

T['default_format']['hides elapsed during interrupting state'] = function()
  _G.child.lua([[
    _G._out = require('cc.statusline')._default_format({
      interrupt_pending = true,
      is_thinking = true,
      spinner_frame = 'SPIN',
      turn_elapsed_ms = 5000,
      total_tokens = 0,
    })
  ]])
  local out = _G.child.lua_get('_G._out')
  eq(out:find('interrupting', 1, true) ~= nil, true)
  eq(out:find('5s', 1, true) == nil, true)
end

T['default_format']['falls back to hourglass when no spinner_frame'] = function()
  _G.child.lua([[
    _G._out = require('cc.statusline')._default_format({
      is_thinking = true,
      total_tokens = 0,
    })
  ]])
  -- ⏳ (U+23F3) renders in any terminal; used when spinner_frame missing.
  eq(_G.child.lua_get("_G._out:find('⏳', 1, true) ~= nil"), true)
end

T['default_format']['shows mode, tokens, branch+pr, session name, remote'] = function()
  _G.child.lua([[
    _G._out = require('cc.statusline')._default_format({
      is_thinking = true,
      total_tokens = 1500,
      mode = 'auto',
      branch = 'main',
      pr = '#42',
      session_name = 'refactor-auth',
      remote_control = true,
    })
  ]])
  local out = _G.child.lua_get('_G._out')
  eq(out:find('auto mode', 1, true) ~= nil, true)
  eq(out:find('1.5k', 1, true) ~= nil, true)
  eq(out:find('main', 1, true) ~= nil, true)
  eq(out:find('#42', 1, true) ~= nil, true)
  eq(out:find(' ── ', 1, true) ~= nil, true)
  eq(out:find('refactor-auth', 1, true) ~= nil, true)
  eq(out:find('⚡', 1, true) ~= nil, true)
  -- Right-aligned via %=
  eq(out:find('%=', 1, true) ~= nil, true)
end

T['default_format']['branch alone (no PR) renders without PR number'] = function()
  _G.child.lua([[
    _G._out = require('cc.statusline')._default_format({ branch = 'main', pr = nil })
  ]])
  local out = _G.child.lua_get('_G._out')
  eq(out:find('main', 1, true) ~= nil, true)
  -- No PR number like "#42" — the raw '#' is allowed in %# highlight codes.
  eq(out:find('#%d', 1, false) == nil, true)
end

-- ---------------------------------------------------------------------------
-- fmt_tokens
-- ---------------------------------------------------------------------------
T['fmt_tokens'] = MiniTest.new_set()

T['fmt_tokens']['zero returns empty'] = function()
  _G.child.lua([[_G._v = require('cc.statusline')._fmt_tokens(0)]])
  eq(_G.child.lua_get('_G._v'), '')
end

T['fmt_tokens']['under 1000 plain number'] = function()
  _G.child.lua([[_G._v = require('cc.statusline')._fmt_tokens(42)]])
  eq(_G.child.lua_get('_G._v'), '42')
end

T['fmt_tokens']['over 1000 uses k'] = function()
  _G.child.lua([[_G._v = require('cc.statusline')._fmt_tokens(1500)]])
  eq(_G.child.lua_get('_G._v'), '1.5k')
end

T['fmt_tokens']['exactly 2000'] = function()
  _G.child.lua([[_G._v = require('cc.statusline')._fmt_tokens(2000)]])
  eq(_G.child.lua_get('_G._v'), '2k')
end

-- ---------------------------------------------------------------------------
-- fmt_elapsed
-- ---------------------------------------------------------------------------
T['fmt_elapsed'] = MiniTest.new_set()

T['fmt_elapsed']['nil returns empty'] = function()
  _G.child.lua([[_G._v = require('cc.statusline')._fmt_elapsed(nil)]])
  eq(_G.child.lua_get('_G._v'), '')
end

T['fmt_elapsed']['under 60 seconds shows seconds'] = function()
  _G.child.lua([[_G._v = require('cc.statusline')._fmt_elapsed(5000)]])
  eq(_G.child.lua_get('_G._v'), '5s')
end

T['fmt_elapsed']['between 1m and 1h shows minutes and seconds'] = function()
  _G.child.lua([[_G._v = require('cc.statusline')._fmt_elapsed(62 * 1000)]])
  eq(_G.child.lua_get('_G._v'), '1m 2s')
end

T['fmt_elapsed']['hour or more shows hours and minutes'] = function()
  _G.child.lua([[_G._v = require('cc.statusline')._fmt_elapsed((3600 + 5 * 60) * 1000)]])
  eq(_G.child.lua_get('_G._v'), '1h 5m')
end

-- ---------------------------------------------------------------------------
-- render: user format override + error handling
-- ---------------------------------------------------------------------------
T['render'] = MiniTest.new_set()

T['render']['user format receives state and returns string'] = function()
  _G.child.lua([[
    local Session = require('cc.session')
    require('cc.config').setup({
      statusline = {
        format = function(state)
          return 'mode=' .. tostring(state.mode)
        end,
      },
    })
    local s = Session.new()
    s.permission_mode = 'plan'
    _G._out = require('cc.statusline').render({ session = s })
  ]])
  eq(_G.child.lua_get('_G._out'), 'mode=plan')
end

T['render']['errors fall back to default format'] = function()
  _G.child.lua([[
    local Session = require('cc.session')
    require('cc.config').setup({
      statusline = {
        format = function() error('boom') end,
      },
    })
    local s = Session.new()
    s.permission_mode = 'auto'
    _G._out = require('cc.statusline').render({ session = s })
  ]])
  local out = _G.child.lua_get('_G._out')
  eq(out:find('auto', 1, true) ~= nil, true)
end

T['render']['non-string return falls back to default'] = function()
  _G.child.lua([[
    local Session = require('cc.session')
    require('cc.config').setup({
      statusline = {
        format = function() return 42 end,
      },
    })
    local s = Session.new()
    s.permission_mode = 'plan'
    _G._out = require('cc.statusline').render({ session = s })
  ]])
  local out = _G.child.lua_get('_G._out')
  eq(out:find('plan', 1, true) ~= nil, true)
end

-- ---------------------------------------------------------------------------
-- attach / refresh
-- ---------------------------------------------------------------------------
T['attach'] = MiniTest.new_set()

T['attach']['sets window statusline when enabled'] = function()
  _G.child.lua([[
    require('cc.config').setup({})
    local Session = require('cc.session')
    local inst = { session = Session.new() }
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(buf)
    local winid = vim.api.nvim_get_current_win()
    inst.output_winid = winid
    require('cc.statusline').attach(inst, winid)
    _G._stl = vim.wo[winid].statusline
  ]])
  local stl = _G.child.lua_get('_G._stl')
  eq(stl:find("cc.statusline", 1, true) ~= nil, true)
end

T['attach']['is a no-op when disabled'] = function()
  _G.child.lua([[
    require('cc.config').setup({ statusline = { enabled = false } })
    local Session = require('cc.session')
    local inst = { session = Session.new() }
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(buf)
    local winid = vim.api.nvim_get_current_win()
    vim.wo[winid].statusline = 'untouched'
    require('cc.statusline').attach(inst, winid)
    _G._stl = vim.wo[winid].statusline
  ]])
  eq(_G.child.lua_get('_G._stl'), 'untouched')
end

T['attach']['render_for resolves attached instance'] = function()
  _G.child.lua([[
    require('cc.config').setup({
      statusline = {
        format = function(state)
          return 'model=' .. tostring(state.model)
        end,
      },
    })
    local Session = require('cc.session')
    local s = Session.new()
    s.model = 'sonnet'
    local inst = { session = s }
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(buf)
    local winid = vim.api.nvim_get_current_win()
    inst.output_winid = winid
    require('cc.statusline').attach(inst, winid)
    _G._out = require('cc.statusline').render_for(winid)
  ]])
  eq(_G.child.lua_get('_G._out'), 'model=sonnet')
end

T['attach']['render_for on unknown winid returns empty'] = function()
  _G.child.lua([[
    _G._out = require('cc.statusline').render_for(99999)
  ]])
  eq(_G.child.lua_get('_G._out'), '')
end

return T
