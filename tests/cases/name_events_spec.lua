local helpers = dofile('tests/helpers.lua')
local MiniTest = require('mini.test')
local eq = MiniTest.expect.equality

local T = MiniTest.new_set({ hooks = helpers.shared_child_hooks() })

local function setup(child)
  child.lua([[
    _G._events = {}
    vim.api.nvim_create_autocmd('User', {
      group = vim.api.nvim_create_augroup('name_events_spec', { clear = true }),
      pattern = 'CcRenamed',
      callback = function(ev) table.insert(_G._events, ev.data) end,
    })
    local output_bufnr = vim.api.nvim_create_buf(false, true)
    local prompt_bufnr = vim.api.nvim_create_buf(false, true)
    _G._inst = {
      session = require('cc.session').new(),
      process = { is_alive = function() return true end },
      output = { bufnr = output_bufnr },
      prompt = { bufnr = prompt_bufnr },
    }
    _G._output_bufnr = output_bufnr
  ]])
end

T['CcRenamed'] = MiniTest.new_set()

T['CcRenamed']['marks the placeholder transient, then fires once for the real name'] = function()
  setup(_G.child)
  _G.child.lua([[
    local cc = require('cc')
    local Statusline = require('cc.statusline')
    Statusline.refresh(_G._inst)
    cc._handle_rename(_G._inst, 'naming...', { silent = true, transient = true })
    Statusline.refresh(_G._inst)
    cc._handle_rename(_G._inst, 'real-name', { silent = true })
    Statusline.refresh(_G._inst)
  ]])
  local events = _G.child.lua_get('_G._events')
  eq(#events, 2)
  eq(events[1].name, 'naming...')
  eq(events[1].transient, true)
  eq(events[1].previous, nil)
  eq(events[1].bufnr, _G.child.lua_get('_G._output_bufnr'))
  eq(events[2].name, 'real-name')
  eq(events[2].transient, false)
  eq(events[2].previous, 'naming...')
end

T['CcRenamed']['fires with no name when the placeholder is cleared'] = function()
  setup(_G.child)
  _G.child.lua([[
    require('cc')._handle_rename(_G._inst, 'naming...', { silent = true, transient = true })
    _G._inst.transient_rename_active = nil
    _G._inst.pending_session_name = nil
    require('cc.statusline').refresh(_G._inst)
  ]])
  local events = _G.child.lua_get('_G._events')
  eq(#events, 2)
  eq(events[2].name, nil)
  eq(events[2].previous, 'naming...')
  eq(events[2].transient, false)
end

T['CcRenamed']['fires when a resume or provider sets the name directly'] = function()
  setup(_G.child)
  _G.child.lua([[
    _G._inst.session_name = 'resumed'
    require('cc')._apply_session_buf_names(_G._inst, 'resumed')
    require('cc.statusline').refresh(_G._inst)
  ]])
  local events = _G.child.lua_get('_G._events')
  eq(#events, 1)
  eq(events[1].name, 'resumed')
  eq(events[1].transient, false)
end

return T
