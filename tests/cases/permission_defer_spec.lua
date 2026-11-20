-- Deferral: a timeout stage answers the CLI so the agent moves on, but the
-- request stays queued; the user's later answer reaches the agent as a
-- message, and an approval lets the exact retry through once.
local helpers = dofile('tests/helpers.lua')
local MiniTest = require('mini.test')
local eq = MiniTest.expect.equality
local T = MiniTest.new_set({ hooks = helpers.shared_child_hooks() })

local function setup(opts)
  _G.child.lua(([==[
    if _G.inst then require('cc.permission_prompt').close_pending(_G.inst) end
    local config = require('cc.config')
    _G.resolved, _G.writes, _G.sent, _G.outcomes = {}, {}, {}, {}
    local opts = %s
    opts.statusline = { enabled = false }
    opts.on_permission_resolved = function(e) resolved[#resolved + 1] = e end
    opts.permission_timeouts = { { after = 0.3, callback = function(e) _G.deferred_ok = e.defer() end } }
    config.setup(opts)
    local session = require('cc.session').new()
    local output = require('cc.output').new(session, 'cc-test-defer')
    output:ensure_buffer()
    output.render_permission_request = function() end
    output.render_permission_outcome = function(_, behavior) outcomes[#outcomes + 1] = behavior end
    local process = {
      is_alive = function() return true end,
      write = function(_, msg) writes[#writes + 1] = msg end,
      close = function() end,
      consume_pending_control = function() end,
    }
    _G.inst = {
      session = session, session_name = 'defer-session', output = output,
      prompt = { bufnr = vim.api.nvim_create_buf(false, true) }, process = process,
      provider = { name = 'claude' },
    }
    require('cc')._register_test_instance(output.bufnr, inst)
    require('cc')._submit_when_idle = function(_, text) sent[#sent + 1] = text; return true end
    _G.router = require('cc.router').new({ session = session, output = output,
      process = process, instance = inst })
    _G.open_request = function(id, command)
      router:dispatch({ type = 'control_request', request_id = id, request = {
        subtype = 'can_use_tool', tool_name = 'Bash', tool_use_id = 'tool-' .. id,
        input = { command = command or 'ask-rob "x"' },
      } })
    end
    _G.entry = function(id) return inst.pending_permissions and inst.pending_permissions[id] end
    _G.defer = function(id, command)
      open_request(id, command)
      assert(vim.wait(2000, function() return #writes >= 1 and entry(id) and entry(id).deferred end, 5))
    end
  ]==]):format(opts or '{}'))
end

T['a deferral answers the CLI and keeps the request queued'] = function()
  setup()
  _G.child.lua([[defer('d1')]])
  eq(_G.child.lua_get('deferred_ok'), true)
  eq(_G.child.lua_get('writes[1].response.response.behavior'), 'deny')
  local message = _G.child.lua_get('writes[1].response.response.message')
  eq(message:find('Deferred, not denied', 1, true) ~= nil, true)
  eq(_G.child.lua_get('inst.awaiting_permission'), false)
  eq(_G.child.lua_get('outcomes[1]'), 'deferred')
  eq(_G.child.lua_get('resolved[1].source'), 'defer')
  eq(_G.child.lua_get('resolved[1].deferred'), true)
  local snap = _G.child.lua_get([[require('cc').list_instances()[1].pending_permissions[1] ]])
  eq(snap.deferred, true)
  eq(snap.request_id, 'd1')
end

T['approving a deferred request messages the agent and lets the exact retry through once'] = function()
  setup()
  _G.child.lua([[
    defer('d2')
    assert(require('cc').resolve_permission('d2', 'allow'))
  ]])
  eq(_G.child.lua_get('entry("d2")'), vim.NIL)
  eq(_G.child.lua_get('#sent'), 1)
  eq(_G.child.lua_get([[sent[1]:find('I approved your deferred Bash call', 1, true) ~= nil]]), true)
  eq(_G.child.lua_get([[sent[1]:find('ask-rob', 1, true) ~= nil]]), true)
  -- The retry: answered allow at once, no float, no new pending entry.
  _G.child.lua([[open_request('retry1')]])
  eq(_G.child.lua_get('#writes'), 2)
  eq(_G.child.lua_get('writes[2].response.request_id'), 'retry1')
  eq(_G.child.lua_get('writes[2].response.response.behavior'), 'allow')
  eq(_G.child.lua_get('entry("retry1")'), vim.NIL)
  eq(_G.child.lua_get('inst.awaiting_permission'), false)
  -- Only once: the next identical call prompts.
  _G.child.lua([[open_request('retry2')]])
  eq(_G.child.lua_get('#writes'), 2)
  eq(_G.child.lua_get('entry("retry2") ~= nil'), true)
end

T['the one-time allow matches only the exact call'] = function()
  setup()
  _G.child.lua([[
    defer('d3', 'ask-rob "one"')
    require('cc').resolve_permission('d3', 'allow')
    open_request('other', 'ask-rob "two"')
  ]])
  eq(_G.child.lua_get('#writes'), 1)
  eq(_G.child.lua_get('entry("other") ~= nil'), true)
end

T['an expired one-time allow prompts again'] = function()
  setup([[{ permission_deferrals = { preapproval_ttl = -1 } }]])
  _G.child.lua([[
    defer('d4')
    require('cc').resolve_permission('d4', 'allow')
    open_request('late')
  ]])
  eq(_G.child.lua_get('#writes'), 1)
  eq(_G.child.lua_get('entry("late") ~= nil'), true)
end

T['denying a deferred request tells the agent and arms nothing'] = function()
  setup()
  _G.child.lua([[
    defer('d5')
    require('cc').resolve_permission('d5', 'deny')
    open_request('again')
  ]])
  eq(_G.child.lua_get([[sent[1]:find('I declined your deferred Bash call', 1, true) ~= nil]]), true)
  eq(_G.child.lua_get('#writes'), 1)
  eq(_G.child.lua_get('entry("again") ~= nil'), true)
end

T['a live prompt for the same call replaces the deferred entry silently'] = function()
  setup()
  _G.child.lua([[
    defer('d6')
    open_request('live')
  ]])
  eq(_G.child.lua_get('entry("d6")'), vim.NIL)
  eq(_G.child.lua_get('entry("live") ~= nil'), true)
  eq(_G.child.lua_get('#sent'), 0)
end

T['teardown drops deferred entries and one-time allows without messages'] = function()
  setup()
  _G.child.lua([[
    defer('d7')
    defer('d8', 'ask-rob "y"')
    require('cc').resolve_permission('d8', 'allow')
    require('cc.permission_prompt').close_pending(inst)
  ]])
  eq(_G.child.lua_get('entry("d7")'), vim.NIL)
  eq(_G.child.lua_get('inst.preapproved'), vim.NIL)
  eq(_G.child.lua_get('#sent'), 1)
end

T['defer refuses a denial float and a second deferral'] = function()
  setup()
  _G.child.lua([[
    local pp = require('cc.permission_prompt')
    local ctx = { provider = 'claude', instance = inst, request_id = 'den', kind = 'denial',
      pending = router.open_prompts }
    pp.request('Bash', { command = 'x' }, function() end, ctx)
    _G.denial_defer = ctx.defer()
  ]])
  eq(_G.child.lua_get('denial_defer'), false)
end

return T
