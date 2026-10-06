local helpers = dofile('tests/helpers.lua')
local MiniTest = require('mini.test')
local eq = MiniTest.expect.equality

local T = MiniTest.new_set({ hooks = helpers.shared_child_hooks() })

-- Fake instances with real buffers. `_G.mk(opts)` registers one;
-- `_G.set(inst, state)` drives its state through statusline.refresh, the path
-- every real transition takes. `_G.link(child, parent)` does what `agents`
-- does: registers the child with the parent, then installs a stand-in for
-- its forwarder (an autocmd on CcStateChanged calling receive with a
-- sequence number) and pushes the current state once. The real forwarder
-- lives in the agents CLI and is tested there.
local SETUP = [==[
  local cc = require('cc')
  local D = require('cc.delegation')
  _G.events = {}
  _G.seq = 0
  vim.api.nvim_create_autocmd('User', {
    group = vim.api.nvim_create_augroup('delegation_spec', { clear = true }),
    pattern = 'CcStateChanged',
    callback = function(ev) table.insert(_G.events, ev.data) end,
  })
  function _G.mk(opts)
    opts = opts or {}
    local output_bufnr = opts.bufnr or vim.api.nvim_create_buf(false, true)
    local prompt_bufnr = vim.api.nvim_create_buf(false, true)
    local session = require('cc.session').new()
    session.id = opts.session_id or ('sid-' .. output_bufnr)
    local alive = true
    local inst = {
      session = session,
      provider = { name = 'claude', send = function() end },
      process = {
        pid = 4242,
        is_alive = function() return alive end,
        close = function() alive = false end,
      },
      output = {
        bufnr = output_bufnr,
        follow_tail = function() end,
        render_user_turn = function() end,
      },
      prompt = { bufnr = prompt_bufnr },
      cwd = '/tmp',
    }
    inst._kill = function() alive = false end
    cc._register_test_instance(output_bufnr, inst)
    require('cc.statusline').refresh(inst)
    return inst
  end
  function _G.set(inst, state)
    inst.awaiting_input = state == 'waiting'
    inst.session.turn_active = state == 'working'
    require('cc.statusline').refresh(inst)
  end
  function _G.state(inst) return require('cc.instance_state').get(inst) end
  function _G.push(child, parent, state)
    _G.seq = _G.seq + 1
    return D.receive({ parent_bufnr = parent.output.bufnr, parent_session_id = parent.session.id,
      key = D.key(child), state = state, seq = _G.seq })
  end
  function _G.link(child, parent)
    local ok, err = D.register_bufnr(parent.output.bufnr, {
      key = D.key(child), socket = vim.v.servername, nvim_pid = vim.fn.getpid(),
      bufnr = child.output.bufnr, session_id = child.session.id, state = 'starting',
    })
    if not ok then return ok, err end
    vim.api.nvim_create_autocmd('User', {
      group = vim.api.nvim_create_augroup('fwd_' .. child.output.bufnr, { clear = true }),
      pattern = 'CcStateChanged',
      callback = function(ev)
        if ev.data.bufnr == child.output.bufnr then _G.push(child, parent, ev.data.state) end
      end,
    })
    _G.push(child, parent, _G.state(child))
    return true
  end
]==]

local function setup() _G.child.lua(SETUP) end
local function lua(code, args) return _G.child.lua(code, args) end
local function get(expr) return _G.child.lua_get(expr) end

T['state'] = MiniTest.new_set()

T['state']['two children finishing in either order'] = function()
  setup()
  for _, order in ipairs({ { 'a', 'b' }, { 'b', 'a' } }) do
    lua([[
      _G.p = _G.mk(); _G.a = _G.mk(); _G.b = _G.mk()
      _G.link(_G.a, _G.p); _G.link(_G.b, _G.p)
      _G.set(_G.a, 'working'); _G.set(_G.b, 'working')
    ]])
    eq(get('_G.state(_G.p)'), 'delegating')
    eq(get('require("cc.delegation").busy_count(_G.p)'), 2)
    lua('_G.set(_G.' .. order[1] .. ', "ready")')
    eq(get('_G.state(_G.p)'), 'delegating')
    lua('_G.set(_G.' .. order[2] .. ', "ready")')
    eq(get('_G.state(_G.p)'), 'ready')
  end
end

T['state']['a registered child counts as starting until its first push; the link outlives idle turns'] = function()
  setup()
  lua([[
    local D = require('cc.delegation')
    _G.p = _G.mk(); _G.c = _G.mk()
    D.register_bufnr(_G.p.output.bufnr, { key = D.key(_G.c) })
    _G.before_push = _G.state(_G.p)
    _G.link(_G.c, _G.p)
  ]])
  eq(get('_G.before_push'), 'delegating')
  eq(get('_G.state(_G.p)'), 'ready')
  -- Re-engaged later (SendMessage, agents send, or Rob typing): busy again.
  lua([[_G.set(_G.c, 'waiting')]])
  eq(get('_G.state(_G.p)'), 'delegating')
end

T['state']['precedence: working wins, delegating beats monitoring and unread'] = function()
  setup()
  lua([[
    _G.p = _G.mk(); _G.c = _G.mk()
    _G.link(_G.c, _G.p); _G.set(_G.c, 'working')
    _G.set(_G.p, 'working')
  ]])
  eq(get('_G.state(_G.p)'), 'working')
  eq(get('require("cc").list_instances()[1].delegateCount'), 1)
  lua([[
    _G.set(_G.p, 'ready')
    _G.p.session.background_task_count = function() return 1 end
    require('cc.seen').mark_unread(_G.p)
  ]])
  eq(get('_G.state(_G.p)'), 'delegating')
  lua([[_G.set(_G.c, 'ready')]])
  eq(get('_G.state(_G.p)'), 'monitoring')
end

T['state']['fires CcStateChanged on the parent'] = function()
  setup()
  lua([[
    _G.p = _G.mk(); _G.c = _G.mk(); _G.link(_G.c, _G.p)
    _G.events = {}
    _G.set(_G.c, 'working'); _G.set(_G.c, 'ready')
    _G.parent_events = vim.tbl_map(function(e) return e.state end,
      vim.tbl_filter(function(e) return e.bufnr == _G.p.output.bufnr end, _G.events))
  ]])
  eq(get('_G.parent_events'), { 'delegating', 'ready' })
end

T['state']['nested: a delegating child keeps its parent delegating'] = function()
  setup()
  lua([[
    _G.top = _G.mk(); _G.mid = _G.mk(); _G.leaf = _G.mk()
    _G.link(_G.mid, _G.top); _G.link(_G.leaf, _G.mid)
    _G.set(_G.mid, 'working'); _G.set(_G.leaf, 'working')
    _G.set(_G.mid, 'ready')
  ]])
  eq(get('_G.state(_G.mid)'), 'delegating')
  eq(get('_G.state(_G.top)'), 'delegating')
  lua([[_G.set(_G.leaf, 'ready')]])
  eq(get('_G.state(_G.mid)'), 'ready')
  eq(get('_G.state(_G.top)'), 'ready')
end

T['receive'] = MiniTest.new_set()

T['receive']['ignores duplicate and out-of-order pushes'] = function()
  setup()
  lua([[
    local D = require('cc.delegation')
    _G.p = _G.mk(); _G.c = _G.mk(); _G.link(_G.c, _G.p)
    local function snap(state, seq)
      return { parent_bufnr = _G.p.output.bufnr, key = D.key(_G.c), state = state, seq = seq }
    end
    _G.r1 = D.receive(snap('working', 100))
    _G.r2 = D.receive(snap('ready', 99))   -- arrives late: older
    _G.r3 = D.receive(snap('working', 100)) -- duplicate
  ]])
  eq(get('{ _G.r1, _G.r2, _G.r3 }'), { true, false, false })
  eq(get('_G.state(_G.p)'), 'delegating')
end

T['receive']['ignores unregistered children and a parent buffer holding another session'] = function()
  setup()
  lua([[
    local D = require('cc.delegation')
    _G.p = _G.mk(); _G.c = _G.mk()
    _G.unregistered = { D.receive({ parent_bufnr = _G.p.output.bufnr, key = D.key(_G.c), state = 'working', seq = 1 }) }
    _G.link(_G.c, _G.p)
    _G.other = { D.receive({ parent_bufnr = _G.p.output.bufnr, parent_session_id = 'someone-else',
      key = D.key(_G.c), state = 'working', seq = 50 }) }
  ]])
  eq(get('_G.unregistered'), { false, 'not registered' })
  eq(get('_G.other'), { false, 'parent buffer now holds another session' })
  eq(get('_G.state(_G.p)'), 'ready')
end

T['receive']['register refuses a self-link; unregister drops the child'] = function()
  setup()
  lua([[
    local D = require('cc.delegation')
    _G.p = _G.mk(); _G.c = _G.mk(); _G.link(_G.c, _G.p); _G.set(_G.c, 'working')
    _G.self = { D.register_bufnr(_G.p.output.bufnr, { key = D.key(_G.p) }) }
    _G.un = { D.unregister_bufnr(_G.p.output.bufnr, D.key(_G.c)) }
    -- A late push after detach cannot recreate the link.
    _G.late = _G.push(_G.c, _G.p, 'working')
  ]])
  eq(get('_G.self'), { false, 'an agent cannot delegate to itself' })
  eq(get('_G.un'), { true })
  eq(get('_G.late'), false)
  eq(get('_G.state(_G.p)'), 'ready')
end

T['receive']['a re-registered child at a reused key starts a fresh sequence'] = function()
  setup()
  lua([[
    local D = require('cc.delegation')
    _G.p = _G.mk()
    local key = '424242:5'
    D.register_bufnr(_G.p.output.bufnr, { key = key, nvim_pid = 1 })
    D.receive({ parent_bufnr = _G.p.output.bufnr, key = key, state = 'ready', seq = 900 })
    -- A Neovim restarted under the same pid registers a child at the same
    -- key; its forwarder counts from 1.
    D.register_bufnr(_G.p.output.bufnr, { key = key, nvim_pid = 1, session_id = 'new' })
    _G.fresh = D.receive({ parent_bufnr = _G.p.output.bufnr, key = key, state = 'working', seq = 1 })
  ]])
  eq(get('_G.fresh'), true)
  eq(get('_G.state(_G.p)'), 'delegating')
  eq(get('_G.p.delegates["424242:5"].session_id'), 'new')
end

T['clear'] = MiniTest.new_set()

T['clear']['closing a busy child fires a closed event that clears the parent'] = function()
  setup()
  lua([[
    _G.p = _G.mk(); _G.c = _G.mk(); _G.link(_G.c, _G.p); _G.set(_G.c, 'working')
    _G.before = _G.state(_G.p)
    _G.events = {}
    require('cc').close(_G.c.output.bufnr)
    _G.closed = vim.tbl_filter(function(e) return e.closed end, _G.events)
  ]])
  eq(get('_G.before'), 'delegating')
  eq(get('#_G.closed'), 1)
  eq(get('_G.closed[1].state'), 'exited')
  eq(get('_G.closed[1].previous'), 'working')
  eq(get('_G.state(_G.p)'), 'ready')
  eq(get('vim.tbl_count(_G.p.delegates)'), 0)
end

T['clear']['process exit clears the parent'] = function()
  setup()
  lua([[
    _G.p = _G.mk(); _G.c = _G.mk(); _G.link(_G.c, _G.p); _G.set(_G.c, 'working')
    _G.c._kill()
    _G.c.session.turn_active = false
    require('cc.statusline').refresh(_G.c)
  ]])
  eq(get('_G.state(_G.c)'), 'exited')
  eq(get('_G.state(_G.p)'), 'ready')
end

T['reconcile'] = MiniTest.new_set()

T['reconcile']['list_instances prunes a child whose Neovim pid is dead, keeps an EPERM one'] = function()
  setup()
  lua([[
    local D = require('cc.delegation')
    _G.p = _G.mk()
    -- Beyond any real pid: kill(pid, 0) fails with ESRCH. pid 1 fails with EPERM.
    for _, pid in ipairs({ 99999999, 1 }) do
      D.register_bufnr(_G.p.output.bufnr, { key = pid .. ':5', nvim_pid = pid, state = 'working' })
    end
    _G.before = D.busy_count(_G.p)
    _G.listed = require('cc').list_instances()[1].delegateCount
  ]])
  eq(get('_G.before'), 2)
  eq(get('_G.listed'), 1)
  eq(get('vim.tbl_keys(_G.p.delegates)'), { '1:5' })
  lua('vim.wait(0)')
  eq(get('_G.state(_G.p)'), 'delegating')
end

T['reconcile']['instance_state.get never probes liveness'] = function()
  setup()
  lua([[
    local D = require('cc.delegation')
    _G.p = _G.mk()
    D.register_bufnr(_G.p.output.bufnr, { key = '99999999:5', nvim_pid = 99999999, state = 'working' })
    for _ = 1, 3 do require('cc.statusline').refresh(_G.p) end
  ]])
  eq(get('_G.state(_G.p)'), 'delegating')
  eq(get('vim.tbl_count(_G.p.delegates)'), 1)
end

T['reconcile']['a child in this Neovim that vanished without an event is pruned on render'] = function()
  setup()
  lua([[
    _G.p = _G.mk(); _G.c = _G.mk(); _G.link(_G.c, _G.p); _G.set(_G.c, 'working')
    require('cc')._reset_instances()
    require('cc')._register_test_instance(_G.p.output.bufnr, _G.p)
    require('cc').list_instances()
  ]])
  eq(get('vim.tbl_count(_G.p.delegates)'), 0)
end

T['reconcile']['the parent turn boundary asks forwarders to push again'] = function()
  setup()
  lua([[
    _G.p = _G.mk(); _G.c = _G.mk(); _G.link(_G.c, _G.p); _G.set(_G.c, 'working')
    -- The child's `ready` push is lost.
    vim.api.nvim_del_augroup_by_name('fwd_' .. _G.c.output.bufnr)
    _G.set(_G.c, 'ready')
    _G.stuck = _G.state(_G.p)
    -- The forwarder's global, as src/forwarder.lua defines it in agents.
    _G.asked = {}
    function _G.cc_delegation_repush(parent_key)
      table.insert(_G.asked, parent_key)
      _G.push(_G.c, _G.p, _G.state(_G.c))
    end
    _G.set(_G.p, 'working')
    _G.set(_G.p, 'ready')
    _G.cc_delegation_repush = nil
  ]])
  eq(get('_G.stuck'), 'delegating')
  eq(get('_G.state(_G.p)'), 'ready')
  eq(get('#_G.asked'), 2)
  eq(get('_G.asked[1] == require("cc.delegation").key(_G.p)'), true)
end

T['list_instances'] = MiniTest.new_set()

T['list_instances']['exposes delegateCount and children, nothing on the child'] = function()
  setup()
  lua([[
    _G.p = _G.mk(); _G.c = _G.mk(); _G.link(_G.c, _G.p); _G.set(_G.c, 'working')
    local by = {}
    for _, s in ipairs(require('cc').list_instances()) do by[s.outputBufnr] = s end
    _G.ps, _G.cs = by[_G.p.output.bufnr], by[_G.c.output.bufnr]
  ]])
  eq(get('_G.ps.state'), 'delegating')
  eq(get('_G.ps.delegateCount'), 1)
  eq(get('_G.ps.children[1].state'), 'working')
  eq(get('_G.ps.children[1].key == require("cc.delegation").key(_G.c)'), true)
  eq(get('_G.cs.delegateCount'), 0)
  eq(get('_G.cs.delegator'), vim.NIL)
end

-- Two real Neovims: pushes arrive by rpcnotify, and the turn-boundary ping
-- reaches the child's Neovim the same way.
T['cross-neovim'] = MiniTest.new_set()

T['cross-neovim']['rpcnotify pushes reach the parent; its turn boundary pings the child Neovim'] = function()
  setup()
  local other = helpers.new_child()
  local ok, err = pcall(function()
    other.lua(SETUP)
    other.lua([[
      local D = require('cc.delegation')
      _G.p = _G.mk()
      D.register_bufnr(_G.p.output.bufnr, { key = '777:5', nvim_pid = 1, socket = ..., bufnr = 5, state = 'starting' })
    ]], { _G.child.lua_get('vim.v.servername') })
    local parent = other.lua_get('{ socket = vim.v.servername, bufnr = _G.p.output.bufnr }')
    lua([[
      _G.parent = ...
      _G.chan = vim.fn.sockconnect('pipe', _G.parent.socket, { rpc = true })
      function _G.remote_push(state, seq)
        vim.rpcnotify(_G.chan, 'nvim_exec_lua', "require('cc.delegation')._remote('receive', ...)",
          { { parent_bufnr = _G.parent.bufnr, key = '777:5', state = state, seq = seq } })
      end
      _G.remote_push('working', 1)
    ]], { parent })
    other.lua([[vim.wait(2000, function() return _G.state(_G.p) == 'delegating' end, 10)]])
    eq(other.lua_get('_G.state(_G.p)'), 'delegating')
    lua([[
      _G.pinged = {}
      function _G.cc_delegation_repush(key) table.insert(_G.pinged, key); _G.remote_push('ready', 2) end
    ]])
    other.lua([[_G.set(_G.p, 'working'); _G.set(_G.p, 'ready')]])
    other.lua([[vim.wait(2000, function() return _G.state(_G.p) == 'ready' end, 10)]])
    eq(other.lua_get('_G.state(_G.p)'), 'ready')
    lua([[vim.wait(1000, function() return #_G.pinged >= 1 end, 10)]])
    eq(get('#_G.pinged') >= 1, true)
  end)
  other.stop()
  if not ok then error(err, 0) end
end

return T
