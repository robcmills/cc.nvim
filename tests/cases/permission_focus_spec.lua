-- Focus loss never answers a permission prompt. Regression for 2026-11-19:
-- a voice :FocusNext moved focus off a just-opened float, WinLeave denied it,
-- and the agent read "User denied via cc.nvim" for a prompt nobody saw.
local helpers = dofile('tests/helpers.lua')
local MiniTest = require('mini.test')
local eq = MiniTest.expect.equality
local T = MiniTest.new_set({ hooks = helpers.shared_child_hooks() })

local function setup()
  _G.child.lua([==[
    local config = require('cc.config')
    _G.prompts, _G.resolved, _G.writes = 0, {}, {}
    config.setup({
      statusline = { enabled = false },
      on_permission_prompt = function() _G.prompts = _G.prompts + 1 end,
      on_permission_resolved = function(e) resolved[#resolved + 1] = e end,
    })
    local session = require('cc.session').new()
    local output = require('cc.output').new(session, 'cc-test-focus')
    output:ensure_buffer()
    output.render_permission_request = function() end
    output.render_permission_outcome = function() end
    local process = {
      is_alive = function() return true end,
      write = function(_, msg) writes[#writes + 1] = msg end,
      close = function() end,
      consume_pending_control = function() end,
    }
    _G.inst = {
      session = session, session_name = 'focus-session', output = output,
      prompt = { bufnr = vim.api.nvim_create_buf(false, true) }, process = process,
    }
    require('cc')._register_test_instance(output.bufnr, inst)
    _G.router = require('cc.router').new({ session = session, output = output,
      process = process, instance = inst })
    vim.cmd('only')
    _G.main_win = vim.api.nvim_get_current_win()
    _G.other_buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_win_set_buf(main_win, other_buf)
    _G.open_request = function(id)
      router:dispatch({ type = 'control_request', request_id = id, request = {
        subtype = 'can_use_tool', tool_name = 'Bash', tool_use_id = 'tool-' .. id,
        input = { command = 'ask-rob "x"' },
      } })
    end
    _G.is_float = function()
      return vim.api.nvim_win_get_config(0).relative ~= ''
    end
    _G.entry = function(id) return inst.pending_permissions and inst.pending_permissions[id] end
  ]==])
end

T['moving focus off the float leaves the request pending'] = function()
  setup()
  _G.child.lua([[
    open_request('r1')
    assert(is_float())
    -- What :FocusNext does: set_current_win to a non-float window.
    vim.api.nvim_set_current_win(main_win)
    vim.wait(50)
  ]])
  eq(_G.child.lua_get('#writes'), 0)
  eq(_G.child.lua_get('#resolved'), 0)
  eq(_G.child.lua_get('entry("r1") ~= nil'), true)
  eq(_G.child.lua_get('entry("r1").hidden'), 'focus')
  eq(_G.child.lua_get('entry("r1").is_open()'), false)
end

T['a hidden request still answers when reopened, and notifies once'] = function()
  setup()
  _G.child.lua([[
    open_request('r2')
    vim.api.nvim_set_current_win(main_win)
    vim.wait(20)
    assert(require('cc.permission_prompt').show_pending(inst))
    assert(is_float())
  ]])
  _G.child.type_keys('a')
  _G.child.lua([[vim.wait(200, function() return #writes == 1 end)]])
  eq(_G.child.lua_get('writes[1].response.response.behavior'), 'allow')
  eq(_G.child.lua_get('prompts'), 1)
  eq(_G.child.lua_get('resolved[1].variant'), 'allow_once')
end

T['entering the agent reopens a focus-hidden prompt, not a q-hidden one'] = function()
  setup()
  _G.child.lua([[
    open_request('r3')
    vim.api.nvim_set_current_win(main_win)
    vim.wait(20)
    vim.api.nvim_win_set_buf(main_win, inst.output.bufnr)
    vim.wait(50)
  ]])
  eq(_G.child.lua_get('is_float()'), true)
  _G.child.type_keys('q')
  _G.child.lua([[
    vim.wait(20)
    vim.api.nvim_win_set_buf(main_win, other_buf)
    vim.api.nvim_win_set_buf(main_win, inst.output.bufnr)
    vim.wait(50)
  ]])
  eq(_G.child.lua_get('is_float()'), false)
  eq(_G.child.lua_get('entry("r3").hidden'), 'key')
  eq(_G.child.lua_get('#writes'), 0)
end

T['focus_instance reopens a prompt put off with q'] = function()
  setup()
  _G.child.lua([[
    vim.api.nvim_win_set_buf(main_win, inst.output.bufnr)
    open_request('r4')
  ]])
  _G.child.type_keys('q')
  _G.child.lua([[
    vim.wait(20)
    vim.api.nvim_win_set_buf(main_win, other_buf)
    require('cc').focus_instance(inst.output.bufnr)
  ]])
  eq(_G.child.lua_get('is_float()'), true)
  _G.child.type_keys('d')
  _G.child.lua([[vim.wait(200, function() return #writes == 1 end)]])
  eq(_G.child.lua_get('writes[1].response.response.behavior'), 'deny')
end

return T
