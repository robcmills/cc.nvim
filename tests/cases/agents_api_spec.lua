local helpers = dofile('tests/helpers.lua')
local MiniTest = require('mini.test')
local eq = MiniTest.expect.equality

local T = MiniTest.new_set({ hooks = helpers.shared_child_hooks() })

local function register(child, output_bufnr, state)
  child.lua(string.format([==[
    local cc = require('cc')
    local output_bufnr = %d
    local prompt_bufnr = vim.api.nvim_create_buf(false, true)
    local session = require('cc.session').new()
    session.id = %s
    session.model = 'gpt-5.6-sol'
    session.turn_active = %s
    session.interrupt_pending = %s
    if session.turn_active then
      session.turn_started_at = (vim.uv or vim.loop).now() - 25
    end
    cc._register_test_instance(output_bufnr, {
      session = session,
      provider = { name = 'codex' },
      process = {
        pid = 1234,
        is_alive = function() return %s end,
      },
      output = { bufnr = output_bufnr },
      prompt = { bufnr = prompt_bufnr },
      cwd = '/Users/me/src/project',
      session_name = 'demo',
      awaiting_input = %s,
    })
  ]==], output_bufnr, state.session_id and "'sid'" or 'nil',
    tostring(state.working or false), tostring(state.interrupting or false),
    tostring(state.alive ~= false), tostring(state.waiting or false)))
end

T['list_instances'] = MiniTest.new_set()

T['list_instances']['uses shared state precedence and returns JSON-safe snapshots'] = function()
  _G.child.lua([[
    _G._outs = {}
    for i = 1, 6 do _G._outs[i] = vim.api.nvim_create_buf(false, true) end
  ]])
  local outs = _G.child.lua_get('_G._outs')
  register(_G.child, outs[1], { alive = false, waiting = true, working = true, session_id = true })
  register(_G.child, outs[2], { waiting = true, interrupting = true, working = true, session_id = true })
  register(_G.child, outs[3], { interrupting = true, working = true, session_id = true })
  register(_G.child, outs[4], { working = true, session_id = true })
  register(_G.child, outs[5], {})
  register(_G.child, outs[6], { session_id = true })
  _G.child.lua([[
    _G._snapshots = require('cc').list_instances()
    _G._encoded = vim.json.encode(_G._snapshots)
  ]])
  local snapshots = _G.child.lua_get('_G._snapshots')
  eq(#snapshots, 6)
  eq(snapshots[1].state, 'exited')
  eq(snapshots[2].state, 'waiting')
  eq(snapshots[3].state, 'interrupting')
  eq(snapshots[4].state, 'working')
  eq(snapshots[5].state, 'starting')
  eq(snapshots[6].state, 'ready')
  eq(type(_G.child.lua_get('_G._encoded')), 'string')
  eq(type(snapshots[4].turnElapsedMs), 'number')
  eq(snapshots[4].backgroundTaskCount, 0)
  eq(type(snapshots[4].lastModifiedAt), 'number')
  eq(snapshots[6].provider, 'codex')
  eq(snapshots[6].cwd, '/Users/me/src/project')
end

T['list_instances']['tracks provider activity as last modified'] = function()
  _G.child.lua([[
    local session = require('cc.session').new()
    local before = session.last_modified_at
    vim.wait(5)
    local router = require('cc.router').new({
      session = session,
      output = {},
      process = {},
    })
    router:dispatch({ type = 'rate_limit' })
    _G._modified_before = before
    _G._modified_after = session.last_modified_at
  ]])
  local before = _G.child.lua_get('_G._modified_before')
  local after = _G.child.lua_get('_G._modified_after')
  eq(after > before, true)
end

T['list_instances']['tracks prompt submission as last modified'] = function()
  _G.child.lua([[
    local session = require('cc.session').new()
    local before = session.last_modified_at
    vim.wait(5)
    session:add_user_turn('hello')
    _G._submitted_before = before
    _G._submitted_after = session.last_modified_at
  ]])
  local before = _G.child.lua_get('_G._submitted_before')
  local after = _G.child.lua_get('_G._submitted_after')
  eq(after > before, true)
end

T['list_instances']['reports background tool lifecycle as monitoring'] = function()
  _G.child.lua([[
    local session = require('cc.session').new()
    local output = {
      render_tool_result = function() end,
      render_task = function() end,
    }
    local router = require('cc.router').new({ session = session, output = output })
    session:begin_tool_call('tool-1', 'Bash')
    session:finalize_tool_call('tool-1', {
      command = 'gh run watch 123',
      run_in_background = true,
    })
    router:dispatch({
      type = 'user',
      message = { role = 'user', content = {
        {
          type = 'tool_result',
          tool_use_id = 'tool-1',
          content = 'Command running in background with ID: task-1. You will be notified.',
        },
      } },
      toolUseResult = { backgroundTaskId = 'task-1' },
    })
    local inst = {
      session = session,
      process = { is_alive = function() return true end },
    }
    _G._background_state = require('cc.instance_state').get(inst)
    _G._background_count = session:background_task_count()
    router:dispatch({
      type = 'task_notification',
      task_id = 'task-1',
      status = 'completed',
      summary = 'workflow completed',
    })
    _G._completed_state = require('cc.instance_state').get(inst)
    _G._completed_count = session:background_task_count()
  ]])
  eq(_G.child.lua_get('_G._background_state'), 'monitoring')
  eq(_G.child.lua_get('_G._background_count'), 1)
  eq(_G.child.lua_get('_G._completed_state'), 'starting')
  eq(_G.child.lua_get('_G._completed_count'), 0)
end

T['list_instances']['Claude permission requests set and clear awaiting_input'] = function()
  _G.child.lua([[
    local original = package.loaded['cc.permission_prompt']
    package.loaded['cc.permission_prompt'] = {
      ask = function(_, _, callback) _G._claude_permission_choice = callback end,
    }
    local session = require('cc.session').new()
    local output = require('cc.output').new(session, 'cc-agent-api-claude')
    output:ensure_buffer()
    output.render_permission_request = function() end
    output.render_permission_outcome = function() end
    local instance = { session = session, output = output, awaiting_input = false }
    local process = { write = function() end, is_alive = function() return true end }
    local router = require('cc.router').new({
      session = session, output = output, process = process, instance = instance,
    })
    router:dispatch({
      type = 'control_request', request_id = 'permission-1',
      request = { subtype = 'can_use_tool', tool_name = 'Bash', input = {} },
    })
    _G._claude_waiting_before = instance.awaiting_input
    _G._claude_permission_choice('allow', 'allow_once')
    _G._claude_waiting_after = instance.awaiting_input
    package.loaded['cc.permission_prompt'] = original
  ]])
  eq(_G.child.lua_get('_G._claude_waiting_before'), true)
  eq(_G.child.lua_get('_G._claude_waiting_after'), false)
end

T['list_instances']['Codex approvals set and clear awaiting_input'] = function()
  _G.child.lua([[
    local original = package.loaded['cc.permission_prompt']
    package.loaded['cc.permission_prompt'] = {
      ask = function(_, _, callback) _G._codex_permission_choice = callback end,
    }
    local session = require('cc.session').new()
    local output = require('cc.output').new(session, 'cc-agent-api-codex')
    output:ensure_buffer()
    output.render_permission_request = function() end
    output.render_permission_outcome = function() end
    local instance = { session = session, output = output, awaiting_input = false }
    local provider = require('cc.providers.codex').attach({
      instance = instance, session = session, output = output,
    })
    provider.alive = true
    provider._write_line = function() end
    instance.provider = provider
    instance.process = provider
    provider:_on_server_request({
      id = 7, method = 'item/commandExecution/requestApproval',
      params = { command = 'true' },
    })
    _G._codex_waiting_before = instance.awaiting_input
    _G._codex_permission_choice('allow', 'allow_once')
    _G._codex_waiting_after = instance.awaiting_input
    package.loaded['cc.permission_prompt'] = original
  ]])
  eq(_G.child.lua_get('_G._codex_waiting_before'), true)
  eq(_G.child.lua_get('_G._codex_waiting_after'), false)
end

T['focus_instance'] = MiniTest.new_set()

T['focus_instance']['focuses the exact registered output buffer'] = function()
  _G.child.lua([[
    local cc = require('cc')
    local output = vim.api.nvim_create_buf(false, true)
    _G._registered_output = output
    local prompt = vim.api.nvim_create_buf(false, true)
    cc._register_test_instance(output, {
      output = { bufnr = output }, prompt = { bufnr = prompt },
    })
    vim.cmd('enew')
    _G._focus_ok = cc.focus_instance(output)
    _G._focused = vim.api.nvim_get_current_buf()
    _G._missing = cc.focus_instance(output + 10000)
    _G._fractional = cc.focus_instance(1.5)
  ]])
  eq(_G.child.lua_get('_G._focus_ok'), true)
  eq(_G.child.lua_get('_G._focused'), _G.child.lua_get('_G._registered_output'))
  eq(_G.child.lua_get('_G._missing'), false)
  eq(_G.child.lua_get('_G._fractional'), false)
end

T['focus_instance']['reopens a hidden fixture through companion-window restoration'] = function()
  _G.child.lua([[
    local cc = require('cc')
    cc.load_fixture('simple_text')
    local inst = cc._get_instance()
    _G._fixture_output = inst.output.bufnr
    _G._fixture_prompt = inst.prompt.bufnr
    vim.cmd('enew')
    vim.wait(50, function() return false end)
    _G._hidden_focus_ok = cc.focus_instance(_G._fixture_output)
    vim.wait(100, function()
      local out = vim.fn.bufwinid(_G._fixture_output)
      local prompt = vim.fn.bufwinid(_G._fixture_prompt)
      return out ~= -1 and prompt ~= -1
    end)
    _G._output_visible = vim.fn.bufwinid(_G._fixture_output) ~= -1
    _G._prompt_visible = vim.fn.bufwinid(_G._fixture_prompt) ~= -1
  ]])
  eq(_G.child.lua_get('_G._hidden_focus_ok'), true)
  eq(_G.child.lua_get('_G._output_visible'), true)
  eq(_G.child.lua_get('_G._prompt_visible'), true)
end

return T
