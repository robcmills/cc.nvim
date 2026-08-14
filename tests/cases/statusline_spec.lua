-- Tests for cc.statusline: build_state, render, default format, user format
-- error handling, attach/refresh wiring.
local helpers = dofile('tests/helpers.lua')
local MiniTest = require('mini.test')
local eq = MiniTest.expect.equality

local T = MiniTest.new_set({
  hooks = helpers.shared_child_hooks(),
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

T['config']['provider model highlights use provider colors'] = function()
  _G.child.lua([[
    require('cc.config').setup({})
    _G._claude_fg = vim.api.nvim_get_hl(
      0, { name = 'CcStlModelClaude', link = false }
    ).fg
    _G._codex_fg = vim.api.nvim_get_hl(
      0, { name = 'CcStlModelCodex', link = false }
    ).fg
  ]])
  eq(_G.child.lua_get('_G._claude_fg'), 0xE4A853)
  eq(_G.child.lua_get('_G._codex_fg'), 0xFFFFFF)
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

T['build_state']['includes the output window width'] = function()
  _G.child.lua([[
    local Session = require('cc.session')
    vim.cmd('vnew')
    local winid = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_width(winid, 47)
    _G._state = require('cc.statusline').build_state({ session = Session.new() }, winid)
  ]])
  eq(_G.child.lua_get('_G._state.window_width'), 47)
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

T['default_format']['shows permission, tokens, branch+pr, session name, remote'] = function()
  _G.child.lua([[
    _G._out = require('cc.statusline')._default_format({
      is_thinking = true,
      context_tokens = 1500,
      mode = 'auto',
      branch = 'main',
      pr = '#42',
      session_name = 'refactor-auth',
      remote_control = true,
    })
  ]])
  local out = _G.child.lua_get('_G._out')
  eq(out:find('auto', 1, true) ~= nil, true)
  eq(out:find('auto mode', 1, true) == nil, true)
  eq(out:find('1.5k', 1, true) ~= nil, true)
  eq(out:find('main', 1, true) ~= nil, true)
  eq(out:find('#42', 1, true) ~= nil, true)
  eq(out:find(' ── ', 1, true) ~= nil, true)
  eq(out:find('refactor-auth', 1, true) ~= nil, true)
  eq(out:find('⚡', 1, true) ~= nil, true)
  -- Right-aligned via %=
  eq(out:find('%=', 1, true) ~= nil, true)
end

T['default_format']['omits mode suffix for codex approval and sandbox'] = function()
  _G.child.lua([[
    _G._out = require('cc.statusline')._default_format({
      provider = 'codex',
      mode = 'never/dangerFullAccess',
    })
  ]])
  local out = _G.child.lua_get('_G._out')
  eq(out:find('never/dangerFullAccess', 1, true) ~= nil, true)
  eq(out:find('never/dangerFullAccess mode', 1, true) == nil, true)
end

T['default_format']['shows provider icon and model between mode and effort'] = function()
  _G.child.lua([[
    require('cc.config').setup({
      statusline = { model_icons = { use_nerdfont = false } },
      tool_icons = { use_nerdfont = false },
    })
    _G._out = require('cc.statusline')._default_format({
      provider = 'claude',
      mode = 'plan',
      model = 'claude-opus-4-7',
      effort = 'high',
    })
  ]])
  local out = _G.child.lua_get('_G._out')
  local mode_at = assert(out:find('plan', 1, true))
  local model_at = assert(out:find('⁕ claude-opus-4-7', 1, true))
  local effort_at = assert(out:find('◑ high', 1, true))
  eq(mode_at < model_at and model_at < effort_at, true)
  eq(out:find('%#CcStlModelClaude#', 1, true) ~= nil, true)
end

T['default_format']['shows Codex icon for Codex provider'] = function()
  _G.child.lua([[
    require('cc.config').setup({
      statusline = { model_icons = { use_nerdfont = false } },
    })
    _G._out = require('cc.statusline')._default_format({
      provider = 'codex',
      model = 'gpt-5.6-sol',
    })
  ]])
  local out = _G.child.lua_get('_G._out')
  eq(out:find('› gpt-5.6-sol', 1, true) ~= nil, true)
  eq(out:find('%#CcStlModelCodex#', 1, true) ~= nil, true)
end

T['default_format']['model icon can be disabled without hiding model'] = function()
  _G.child.lua([[
    require('cc.config').setup({
      statusline = { model_icons = { claude = '' } },
    })
    _G._out = require('cc.statusline')._default_format({
      provider = 'claude',
      model = 'claude-sonnet-5',
    })
  ]])
  local out = _G.child.lua_get('_G._out')
  eq(out:find('claude-sonnet-5', 1, true) ~= nil, true)
  eq(out:find('⁕', 1, true) == nil, true)
  eq(out:find('✻', 1, true) == nil, true)
end

T['default_format']['shows pending_session_name when no persisted name'] = function()
  _G.child.lua([[
    _G._out = require('cc.statusline')._default_format({
      pending_session_name = 'fresh-name',
    })
  ]])
  local out = _G.child.lua_get('_G._out')
  eq(out:find('fresh-name', 1, true) ~= nil, true)
end

T['default_format']['session_name takes precedence over pending'] = function()
  _G.child.lua([[
    _G._out = require('cc.statusline')._default_format({
      session_name = 'persisted',
      pending_session_name = 'queued',
    })
  ]])
  local out = _G.child.lua_get('_G._out')
  eq(out:find('persisted', 1, true) ~= nil, true)
  eq(out:find('queued', 1, true) == nil, true)
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

T['default_format']['wide windows preserve every component and visual order'] = function()
  _G.child.lua([[
    require('cc.config').setup({
      statusline = { model_icons = { claude = '' }, tokens_icon = '' },
    })
    _G._out = require('cc.statusline')._default_format({
      provider = 'claude',
      is_thinking = true,
      spinner_frame = 'ACTIVE',
      context_tokens = 10,
      mode = 'MODE',
      model = 'MODEL',
      effort = 'high',
      branch = 'BRANCH',
      pr = '#12',
      session_name = 'SESSION',
      remote_control = true,
      window_width = 1000,
    })
  ]])
  local out = _G.child.lua_get('_G._out')
  local activity_at = assert(out:find('ACTIVE', 1, true))
  local tokens_at = assert(out:find('10', 1, true))
  local mode_at = assert(out:find('MODE', 1, true))
  local model_at = assert(out:find('MODEL', 1, true))
  local effort_at = assert(out:find('high', 1, true))
  local git_at = assert(out:find('BRANCH', 1, true))
  local session_at = assert(out:find('SESSION', 1, true))
  local remote_at = assert(out:find('⚡', 1, true))
  eq(
    activity_at < tokens_at
      and tokens_at < mode_at
      and mode_at < model_at
      and model_at < effort_at
      and effort_at < git_at
      and git_at < session_at
      and session_at < remote_at,
    true
  )
end

T['default_format']['narrow windows retain the highest-priority component'] = function()
  _G.child.lua([[
    require('cc.config').setup({
      statusline = { model_icons = { claude = '' }, tokens_icon = '' },
    })
    _G._out = require('cc.statusline')._default_format({
      provider = 'claude',
      is_thinking = true,
      spinner_frame = 'ACTIVE',
      context_tokens = 10,
      mode = 'MODE',
      model = 'MODEL',
      effort = 'high',
      branch = 'BRANCH',
      session_name = 'SESSION',
      remote_control = true,
      window_width = 1,
    })
  ]])
  local out = _G.child.lua_get('_G._out')
  eq(out:find('10', 1, true) ~= nil, true)
  eq(out:find('ACTIVE', 1, true) == nil, true)
  eq(out:find('MODE', 1, true) == nil, true)
  eq(out:find('MODEL', 1, true) == nil, true)
  eq(out:find('high', 1, true) == nil, true)
  eq(out:find('BRANCH', 1, true) == nil, true)
  eq(out:find('SESSION', 1, true) == nil, true)
  eq(out:find('⚡', 1, true) == nil, true)
end

T['default_format']['custom priorities change which component survives'] = function()
  _G.child.lua([[
    require('cc.config').setup({
      statusline = {
        priorities = {
          'remote_control',
          'session_name',
          'git',
          'mode',
          'activity',
          'effort',
          'model',
          'tokens',
        },
        model_icons = { claude = '' },
        tokens_icon = '',
      },
    })
    _G._out = require('cc.statusline')._default_format({
      provider = 'claude',
      is_thinking = true,
      spinner_frame = 'ACTIVE',
      context_tokens = 10,
      mode = 'MODE',
      model = 'MODEL',
      effort = 'high',
      branch = 'BRANCH',
      session_name = 'SESSION',
      remote_control = true,
      window_width = 1,
    })
  ]])
  local out = _G.child.lua_get('_G._out')
  eq(out:find('⚡', 1, true) ~= nil, true)
  eq(out:find('10', 1, true) == nil, true)
  eq(out:find('SESSION', 1, true) == nil, true)
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
-- model_context_window
-- ---------------------------------------------------------------------------
T['model_context_window'] = MiniTest.new_set()

T['model_context_window']['nil model returns nil'] = function()
  _G.child.lua([[_G._v = require('cc.statusline')._model_context_window(nil)]])
  eq(_G.child.lua_get('_G._v == nil'), true)
end

T['model_context_window']['empty model returns nil'] = function()
  _G.child.lua([[_G._v = require('cc.statusline')._model_context_window('')]])
  eq(_G.child.lua_get('_G._v == nil'), true)
end

T['model_context_window']['[1m] suffix returns 1M'] = function()
  _G.child.lua([[_G._v = require('cc.statusline')._model_context_window('claude-sonnet-4-5[1m]')]])
  eq(_G.child.lua_get('_G._v'), 1000000)
end

T['model_context_window']['known 1M models'] = function()
  _G.child.lua([[
    local f = require('cc.statusline')._model_context_window
    _G._opus5 = f('claude-opus-5')
    _G._opus48 = f('claude-opus-4-8')
    _G._opus47 = f('claude-opus-4-7')
    _G._opus46 = f('claude-opus-4-6')
    _G._sonnet5 = f('claude-sonnet-5')
    _G._sonnet46 = f('claude-sonnet-4-6')
    _G._fable5 = f('claude-fable-5')
    -- Dated variants must resolve too — substring match against the canonical
    -- root, not the full id.
    _G._opus5_dated = f('claude-opus-5-20260723')
    _G._opus47_dated = f('claude-opus-4-7-20260101')
    _G._mythos = f('claude-mythos-preview')
  ]])
  eq(_G.child.lua_get('_G._opus5'), 1000000)
  eq(_G.child.lua_get('_G._opus48'), 1000000)
  eq(_G.child.lua_get('_G._opus47'), 1000000)
  eq(_G.child.lua_get('_G._opus46'), 1000000)
  eq(_G.child.lua_get('_G._sonnet5'), 1000000)
  eq(_G.child.lua_get('_G._sonnet46'), 1000000)
  eq(_G.child.lua_get('_G._fable5'), 1000000)
  eq(_G.child.lua_get('_G._opus5_dated'), 1000000)
  eq(_G.child.lua_get('_G._opus47_dated'), 1000000)
  eq(_G.child.lua_get('_G._mythos'), 1000000)
end

T['model_context_window']['known 200K models'] = function()
  _G.child.lua([[
    local f = require('cc.statusline')._model_context_window
    _G._sonnet45 = f('claude-sonnet-4-5')
    _G._opus45 = f('claude-opus-4-5')
    _G._opus41 = f('claude-opus-4-1')
    _G._haiku45 = f('claude-haiku-4-5')
    _G._haiku_dated = f('claude-haiku-4-5-20251001')
  ]])
  eq(_G.child.lua_get('_G._sonnet45'), 200000)
  eq(_G.child.lua_get('_G._opus45'), 200000)
  eq(_G.child.lua_get('_G._opus41'), 200000)
  eq(_G.child.lua_get('_G._haiku45'), 200000)
  eq(_G.child.lua_get('_G._haiku_dated'), 200000)
end

T['model_context_window']['unknown Claude-ish model defaults to 200K'] = function()
  -- Forward-compat: when a model we haven't seen yet appears (e.g. Sonnet
  -- 4.7 ships before we update the table), fall through to the documented
  -- 200K default rather than nil. The CLI's modelUsage will correct us as
  -- soon as the first turn completes.
  _G.child.lua([[_G._v = require('cc.statusline')._model_context_window('claude-sonnet-4-7')]])
  eq(_G.child.lua_get('_G._v'), 200000)
end

-- ---------------------------------------------------------------------------
-- context fields in build_state
-- ---------------------------------------------------------------------------
T['build_state']['context_window derived from model'] = function()
  _G.child.lua([[
    local Session = require('cc.session')
    local s = Session.new()
    s.model = 'claude-opus-4-7[1m]'
    s.context_tokens = 10000
    _G._state = require('cc.statusline').build_state({ session = s })
  ]])
  eq(_G.child.lua_get('_G._state.context_window'), 1000000)
  eq(_G.child.lua_get('_G._state.context_tokens'), 10000)
  eq(_G.child.lua_get('string.format("%.1f", _G._state.context_percent)'), '1.0')
end

T['build_state']['config.context_window overrides model-derived value'] = function()
  _G.child.lua([[
    require('cc.config').setup({ statusline = { context_window = 50000 } })
    local Session = require('cc.session')
    local s = Session.new()
    s.model = 'claude-opus-4-7'
    s.context_tokens = 500
    _G._state = require('cc.statusline').build_state({ session = s })
  ]])
  eq(_G.child.lua_get('_G._state.context_window'), 50000)
  eq(_G.child.lua_get('string.format("%.1f", _G._state.context_percent)'), '1.0')
end

T['build_state']['session.context_window from CLI wins over model parse'] = function()
  -- Sonnet 4.5 is 200K by the table, but the user enabled the 1M-context
  -- beta header so the CLI reports 1M via modelUsage. The authoritative
  -- CLI value must override our fallback.
  _G.child.lua([[
    require('cc.config').setup({})
    local Session = require('cc.session')
    local s = Session.new()
    s.model = 'claude-sonnet-4-5'
    s.context_window = 1000000
    s.context_tokens = 10000
    _G._state = require('cc.statusline').build_state({ session = s })
  ]])
  eq(_G.child.lua_get('_G._state.context_window'), 1000000)
  eq(_G.child.lua_get('string.format("%.1f", _G._state.context_percent)'), '1.0')
end

T['build_state']['user config still wins over CLI-reported window'] = function()
  -- An explicit `statusline.context_window` is treated as a cap (e.g. the
  -- user wants the % to reflect auto-compact threshold rather than the raw
  -- model window). It must beat even the authoritative CLI value.
  _G.child.lua([[
    require('cc.config').setup({ statusline = { context_window = 50000 } })
    local Session = require('cc.session')
    local s = Session.new()
    s.model = 'claude-sonnet-4-6'
    s.context_window = 1000000
    s.context_tokens = 500
    _G._state = require('cc.statusline').build_state({ session = s })
  ]])
  eq(_G.child.lua_get('_G._state.context_window'), 50000)
end

-- ---------------------------------------------------------------------------
-- token segment rendering: icon prefix only (no context percent in default)
-- ---------------------------------------------------------------------------
T['default_format']['token segment uses tau icon by default'] = function()
  _G.child.lua([[
    require('cc.config').setup({})
    _G._out = require('cc.statusline')._default_format({ context_tokens = 1500 })
  ]])
  local out = _G.child.lua_get('_G._out')
  eq(out:find('τ 1.5k', 1, true) ~= nil, true)
  -- "tokens" word no longer appended.
  eq(out:find(' tokens', 1, true) == nil, true)
end

T['default_format']['default omits context percent even when window is known'] = function()
  -- With a 1M-token budget the count and the percent encode the same number
  -- (just shifted by a decimal), so the default layout drops the percent.
  -- Custom format functions still get state.context_percent.
  _G.child.lua([[
    require('cc.config').setup({})
    _G._out = require('cc.statusline')._default_format({
      context_tokens = 13200,
      context_window = 1200000,
    })
  ]])
  local out = _G.child.lua_get('_G._out')
  eq(out:find('τ 13.2k', 1, true) ~= nil, true)
  -- No percent in the rendered statusline.
  eq(out:find('%%', 1, true) == nil, true)
  eq(out:find('1.1', 1, true) == nil, true)
end

T['default_format']['tokens_icon override applies'] = function()
  _G.child.lua([[
    require('cc.config').setup({ statusline = { tokens_icon = 'X' } })
    _G._out = require('cc.statusline')._default_format({ context_tokens = 500 })
  ]])
  local out = _G.child.lua_get('_G._out')
  eq(out:find('X 500', 1, true) ~= nil, true)
end

T['default_format']['empty tokens_icon drops the prefix entirely'] = function()
  _G.child.lua([[
    require('cc.config').setup({ statusline = { tokens_icon = '' } })
    _G._out = require('cc.statusline')._default_format({ context_tokens = 500 })
  ]])
  local out = _G.child.lua_get('_G._out')
  eq(out:find('τ', 1, true) == nil, true)
  eq(out:find('500', 1, true) ~= nil, true)
end

T['default_format']['falls back to total_tokens when context_tokens not yet seen'] = function()
  -- Mid-turn before the first result message lands, context_tokens is 0
  -- but total_tokens may carry over from a prior turn (or be the running
  -- count). Don't drop the token segment just because the snapshot is
  -- empty.
  _G.child.lua([[
    require('cc.config').setup({})
    _G._out = require('cc.statusline')._default_format({
      total_tokens = 800,
      context_tokens = 0,
    })
  ]])
  local out = _G.child.lua_get('_G._out')
  eq(out:find('τ 800', 1, true) ~= nil, true)
  -- No percent when we don't know the live context size.
  eq(out:find('%%', 1, true) == nil, true)
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

T['render']['user format receives width and is not automatically shortened'] = function()
  _G.child.lua([[
    local Session = require('cc.session')
    require('cc.config').setup({
      statusline = {
        format = function(state)
          return 'width=' .. tostring(state.window_width) .. ' custom-content'
        end,
      },
    })
    local inst = { session = Session.new() }
    vim.cmd('vnew')
    local winid = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_width(winid, 23)
    require('cc.statusline').attach(inst, winid)
    _G._out = require('cc.statusline').render_for(winid)
  ]])
  eq(_G.child.lua_get('_G._out'), 'width=23 custom-content')
end

T['render']['default format drops components using the attached window width'] = function()
  _G.child.lua([[
    local Session = require('cc.session')
    require('cc.config').setup({
      statusline = { model_icons = { claude = '' }, tokens_icon = '' },
    })
    local session = Session.new()
    session.context_tokens = 10
    session.model = 'MODEL'
    session.permission_mode = 'MODE'
    local inst = { session = session }
    vim.cmd('vnew')
    local winid = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_width(winid, 15)
    require('cc.statusline').attach(inst, winid)
    _G._out = require('cc.statusline').render_for(winid)
  ]])
  local out = _G.child.lua_get('_G._out')
  eq(out:find('10', 1, true) ~= nil, true)
  eq(out:find('MODEL', 1, true) ~= nil, true)
  eq(out:find('%#CcStlMode#', 1, true) == nil, true)
  eq(out:find('med', 1, true) == nil, true)
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
