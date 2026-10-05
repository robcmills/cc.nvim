local helpers = dofile('tests/helpers.lua')
local MiniTest = require('mini.test')
local eq = MiniTest.expect.equality

local T = MiniTest.new_set({ hooks = helpers.shared_child_hooks() })

local function setup(child)
  child.lua([[
    _G._events = {}
    vim.api.nvim_create_autocmd('User', {
      group = vim.api.nvim_create_augroup('state_events_spec', { clear = true }),
      pattern = 'CcStateChanged',
      callback = function(ev) table.insert(_G._events, ev.data) end,
    })
    local output_bufnr = vim.api.nvim_create_buf(false, true)
    local prompt_bufnr = vim.api.nvim_create_buf(false, true)
    local session = require('cc.session').new()
    session.id = 'sid'
    _G._inst = {
      session = session,
      process = { is_alive = function() return true end },
      output = { bufnr = output_bufnr },
      prompt = { bufnr = prompt_bufnr },
    }
    _G._output_bufnr = output_bufnr
  ]])
end

T['CcStateChanged'] = MiniTest.new_set()

T['CcStateChanged']['fires once per transition through statusline.refresh'] = function()
  setup(_G.child)
  _G.child.lua([[
    local Statusline = require('cc.statusline')
    Statusline.refresh(_G._inst)
    Statusline.refresh(_G._inst)
    _G._inst.session.turn_active = true
    Statusline.refresh(_G._inst)
    Statusline.refresh(_G._inst)
  ]])
  local events = _G.child.lua_get('_G._events')
  eq(#events, 2)
  eq(events[1].state, 'ready')
  eq(events[1].previous, nil)
  eq(events[1].bufnr, _G.child.lua_get('_G._output_bufnr'))
  eq(events[2].state, 'working')
  eq(events[2].previous, 'ready')
end

T['CcStateChanged']['fires when viewing clears unread'] = function()
  setup(_G.child)
  _G.child.lua([[
    local Statusline = require('cc.statusline')
    _G._inst.session.turn_finished_at = math.huge
    Statusline.refresh(_G._inst)
    _G._inst.session.turn_finished_at = 1
    require('cc.seen').mark_seen(_G._inst)
  ]])
  local events = _G.child.lua_get('_G._events')
  eq(#events, 2)
  eq(events[1].state, 'unread')
  eq(events[2].state, 'ready')
  eq(events[2].previous, 'unread')
end

T['mark_unread'] = MiniTest.new_set()

T['mark_unread']['flags unread by prompt bufnr until next viewed'] = function()
  setup(_G.child)
  _G.child.lua([[
    local cc = require('cc')
    cc._register_test_instance(_G._output_bufnr, _G._inst)
    require('cc.statusline').refresh(_G._inst)
    _G._marked = cc.mark_unread(_G._inst.prompt.bufnr)
    _G._not_cc = cc.mark_unread(vim.api.nvim_create_buf(false, true))
    require('cc.seen').mark_seen(_G._inst)
  ]])
  eq(_G.child.lua_get('_G._marked'), true)
  eq(_G.child.lua_get('_G._not_cc'), false)
  local events = _G.child.lua_get('_G._events')
  eq(#events, 3)
  eq(events[1].state, 'ready')
  eq(events[2].state, 'unread')
  eq(events[3].state, 'ready')
end

T['mark_unread']['yields to working, then shows once the turn ends'] = function()
  setup(_G.child)
  _G.child.lua([[
    _G._inst.session.turn_active = true
    require('cc.seen').mark_unread(_G._inst)
    _G._inst.session.turn_active = false
    require('cc.statusline').refresh(_G._inst)
  ]])
  local events = _G.child.lua_get('_G._events')
  eq(#events, 2)
  eq(events[1].state, 'working')
  eq(events[2].state, 'unread')
end

return T
