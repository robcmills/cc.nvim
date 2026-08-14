local helpers = dofile('tests/helpers.lua')
local MiniTest = require('mini.test')
local eq = MiniTest.expect.equality

local T = MiniTest.new_set({
  hooks = helpers.shared_child_hooks(),
})

T['streaming config'] = MiniTest.new_set()

T['streaming config']['uses conservative defaults'] = function()
  _G.child.lua([[
    require('cc.config').setup({})
    _G._streaming = require('cc.config').options.streaming
  ]])
  eq(_G.child.lua_get('_G._streaming'), {
    render_interval_ms = 33,
    markdown_hz = 5,
  })
end

T['streaming config']['accepts valid render and markdown rates'] = function()
  _G.child.lua([[
    require('cc.config').setup({
      streaming = {
        render_interval_ms = 16.6,
        markdown_hz = -1,
      },
    })
    _G._streaming = require('cc.config').options.streaming
  ]])
  eq(_G.child.lua_get('_G._streaming'), {
    render_interval_ms = 17,
    markdown_hz = -1,
  })
end

T['streaming config']['invalid values warn and fall back independently'] = function()
  _G.child.lua([[
    local notices = {}
    local original_notify = vim.notify
    vim.notify = function(msg, level)
      notices[#notices + 1] = { msg = msg, level = level }
    end
    require('cc.config').setup({
      streaming = {
        render_interval_ms = 2,
        markdown_hz = 0,
      },
    })
    vim.notify = original_notify
    _G._streaming = require('cc.config').options.streaming
    _G._notices = notices
  ]])

  eq(_G.child.lua_get('_G._streaming'), {
    render_interval_ms = 33,
    markdown_hz = 5,
  })
  local notices = _G.child.lua_get('_G._notices')
  eq(#notices, 2)
  eq(notices[1].level, vim.log.levels.WARN)
  eq(notices[1].msg:find('streaming.render_interval_ms', 1, true) ~= nil, true)
  eq(notices[2].msg:find('streaming.markdown_hz', 1, true) ~= nil, true)
end

T['streaming config']['non-table value warns and restores all defaults'] = function()
  _G.child.lua([[
    local notices = {}
    local original_notify = vim.notify
    vim.notify = function(msg) notices[#notices + 1] = msg end
    require('cc.config').setup({ streaming = 'fast' })
    vim.notify = original_notify
    _G._streaming = require('cc.config').options.streaming
    _G._notices = notices
  ]])

  eq(_G.child.lua_get('_G._streaming'), {
    render_interval_ms = 33,
    markdown_hz = 5,
  })
  local notices = _G.child.lua_get('_G._notices')
  eq(#notices, 1)
  eq(notices[1]:find('invalid streaming=', 1, true) ~= nil, true)
end

T['statusline config'] = MiniTest.new_set()

T['statusline config']['uses the default component priorities'] = function()
  _G.child.lua([[
    require('cc.config').setup({})
    _G._priorities = require('cc.config').options.statusline.priorities
  ]])
  eq(_G.child.lua_get('_G._priorities'), {
    'tokens',
    'model',
    'effort',
    'activity',
    'mode',
    'git',
    'session_name',
    'remote_control',
  })
end

T['statusline config']['accepts a complete custom priority order'] = function()
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
      },
    })
    _G._priorities = require('cc.config').options.statusline.priorities
  ]])
  eq(_G.child.lua_get('_G._priorities'), {
    'remote_control',
    'session_name',
    'git',
    'mode',
    'activity',
    'effort',
    'model',
    'tokens',
  })
end

T['statusline config']['invalid priorities warn and restore the default'] = function()
  _G.child.lua([[
    local notices = {}
    local original_notify = vim.notify
    vim.notify = function(msg, level)
      notices[#notices + 1] = { msg = msg, level = level }
    end
    require('cc.config').setup({
      statusline = {
        priorities = {
          'tokens',
          'tokens',
          'effort',
          'activity',
          'mode',
          'git',
          'session_name',
          'unknown',
        },
      },
    })
    vim.notify = original_notify
    _G._priorities = require('cc.config').options.statusline.priorities
    _G._notices = notices
  ]])

  eq(_G.child.lua_get('_G._priorities'), {
    'tokens',
    'model',
    'effort',
    'activity',
    'mode',
    'git',
    'session_name',
    'remote_control',
  })
  local notices = _G.child.lua_get('_G._notices')
  eq(#notices, 1)
  eq(notices[1].level, vim.log.levels.WARN)
  eq(notices[1].msg:find('statusline.priorities', 1, true) ~= nil, true)
end

return T
