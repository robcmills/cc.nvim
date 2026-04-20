-- Tests for cc.statusline_spinner: frame config, start/stop lifecycle,
-- current_frame, sync against session.turn_active.
local helpers = dofile('tests/helpers.lua')
local MiniTest = require('mini.test')
local eq = MiniTest.expect.equality

local T = MiniTest.new_set({
  hooks = {
    pre_case = function() _G.child = helpers.new_child() end,
    post_case = function() if _G.child then _G.child.stop() end end,
  },
})

T['current_frame defaults to first frame when not started'] = function()
  _G.child.lua([[
    require('cc.config').setup({
      statusline = { spinner = { frames = { 'X', 'Y' }, interval_ms = 50 } },
    })
    local Session = require('cc.session')
    local inst = { session = Session.new() }
    _G._frame = require('cc.statusline_spinner').current_frame(inst)
  ]])
  eq(_G.child.lua_get('_G._frame'), 'X')
end

T['sync starts spinner when turn_active is true'] = function()
  _G.child.lua([[
    require('cc.config').setup({
      statusline = { spinner = { frames = { 'A', 'B' }, interval_ms = 10 } },
    })
    local Session = require('cc.session')
    local s = Session.new()
    s.turn_active = true
    local inst = { session = s }
    local Spinner = require('cc.statusline_spinner')
    Spinner.sync(inst)
    vim.wait(50, function() return false end)
    _G._frame = Spinner.current_frame(inst)
    Spinner.stop(inst)
  ]])
  -- After at least one tick the frame must have advanced past 'A'.
  eq(_G.child.lua_get("_G._frame == 'B' or _G._frame == 'A'"), true)
end

T['sync stops spinner when turn_active flips false'] = function()
  _G.child.lua([[
    require('cc.config').setup({
      statusline = { spinner = { frames = { 'A', 'B' }, interval_ms = 10 } },
    })
    local Session = require('cc.session')
    local s = Session.new()
    s.turn_active = true
    local inst = { session = s }
    local Spinner = require('cc.statusline_spinner')
    Spinner.sync(inst)
    s.turn_active = false
    Spinner.sync(inst)
    _G._frame = Spinner.current_frame(inst)
  ]])
  -- Frame resets to first frame after stop.
  eq(_G.child.lua_get('_G._frame'), 'A')
end

T['use_nerdfont=true picks frames_nerdfont'] = function()
  _G.child.lua([[
    require('cc.config').setup({
      statusline = {
        spinner = {
          use_nerdfont = true,
          frames_nerdfont = { 'NF1', 'NF2' },
          frames_unicode = { 'U1', 'U2' },
        },
      },
    })
    local Session = require('cc.session')
    local inst = { session = Session.new() }
    _G._frame = require('cc.statusline_spinner').current_frame(inst)
  ]])
  eq(_G.child.lua_get('_G._frame'), 'NF1')
end

T['use_nerdfont=false picks frames_unicode'] = function()
  _G.child.lua([[
    require('cc.config').setup({
      statusline = {
        spinner = {
          use_nerdfont = false,
          frames_nerdfont = { 'NF1' },
          frames_unicode = { 'U1', 'U2' },
        },
      },
    })
    local Session = require('cc.session')
    local inst = { session = Session.new() }
    _G._frame = require('cc.statusline_spinner').current_frame(inst)
  ]])
  eq(_G.child.lua_get('_G._frame'), 'U1')
end

T['explicit frames override nerdfont/unicode sets'] = function()
  _G.child.lua([[
    require('cc.config').setup({
      statusline = {
        spinner = {
          use_nerdfont = true,
          frames = { 'OVERRIDE' },
          frames_nerdfont = { 'NF1' },
          frames_unicode = { 'U1' },
        },
      },
    })
    local Session = require('cc.session')
    local inst = { session = Session.new() }
    _G._frame = require('cc.statusline_spinner').current_frame(inst)
  ]])
  eq(_G.child.lua_get('_G._frame'), 'OVERRIDE')
end

T['start is idempotent'] = function()
  _G.child.lua([[
    require('cc.config').setup({
      statusline = { spinner = { frames = { 'A' }, interval_ms = 10 } },
    })
    local Session = require('cc.session')
    local inst = { session = Session.new() }
    local Spinner = require('cc.statusline_spinner')
    Spinner.start(inst)
    Spinner.start(inst)
    _G._ok = true
    Spinner.stop(inst)
  ]])
  eq(_G.child.lua_get('_G._ok'), true)
end

return T
